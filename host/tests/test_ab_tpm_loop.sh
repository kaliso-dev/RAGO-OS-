#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — jetons TPM des mises à jour A/B (M4) sur des disques VIRTUELS : loop
# devices sur des fichiers jetables, TPM 2.0 émulé (swtpm), vraies UKI (ukify)
# signées par une clé MOK de test, vrai systemd-cryptenroll / cryptsetup.
#
# SÉCURITÉ : jamais de vrai disque (loop devices du dossier de test seulement,
# vérifié avant chaque commande ; script M3 toujours avec --virtual-only).
#
# Vérifie, avec setup_secure_encryption.sh (M3) en mode A/B :
#   - un jeton par entrée de démarrage : PCR 0+7 pour l'entrée de M0, PCR 0+7+11
#     (valeur prédite) pour chaque UKI ; la politique calculée par Rago est celle
#     que systemd-cryptenroll écrit (contrôle après chaque enrôlement) ;
#   - racine A : entrées du slot A ; racine B : du slot B ; swap : toutes ;
#   - prune-tpm retire sans passphrase les jetons qui ne servent plus, et rien
#     tant qu'une entrée n'a pas le sien ; la passphrase n'est jamais retirée ;
#   - UKI non signée, UKI d'un slot sous le nom de l'autre : ignorées ;
#     UKI sans métadonnées Rago, UKI à profils, RAGO_AB_PCR11=0 : PCR 0+7
#     (dégradé, signalé) ; ESP sans entrée pour le slot en marche : refus,
#     rien n'est changé ; PCR jamais mesurés : refus ;
#   - tpm-check et verify en mode A/B.
# Le descellement réel par l'UKI au démarrage (PCR 11 mesuré par systemd-stub)
# est testé dans la VM : tests/vm/run_m4_vm_test.sh.
#
# Usage (root) : host/tests/test_ab_tpm_loop.sh [--keep]
# Dépendances : losetup, cryptsetup ≥ 2.4, systemd-cryptenroll ≥ 254, swtpm,
# tpm2-tools, ukify, systemd-stub (linuxx64.efi.stub), sbsign, sbverify,
# openssl, python3.
set -u

here=$(cd "$(dirname "$0")" && pwd)
S="$here/../setup_secure_encryption.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/rago_uki_lib.sh
. "$here/../lib/rago_uki_lib.sh"
keep=0
[ "${1:-}" = --keep ] && keep=1

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (loop devices)" >&2; exit 2; }
for t in losetup cryptsetup systemd-cryptenroll swtpm tpm2_pcrextend tpm2_pcrread ukify sbsign sbverify openssl python3 setsid; do
	command -v "$t" >/dev/null || { echo "outil manquant : $t" >&2; exit 2; }
done
STUB=""
for s in /usr/lib/systemd/boot/efi/linuxx64.efi.stub /lib/systemd/boot/efi/linuxx64.efi.stub; do [ -f "$s" ] && STUB=$s && break; done
[ -n "$STUB" ] || { echo "systemd-stub absent (linuxx64.efi.stub)" >&2; exit 2; }

T=$(mktemp -d /var/tmp/rago-m4-loop.XXXXXX)
LOOPS=""
cleanup() {
	local l
	for l in $LOOPS; do losetup -d "$l" 2>/dev/null || true; done
	[ -f "$T/swtpm.pid" ] && kill "$(cat "$T/swtpm.pid")" 2>/dev/null
	if [ "$keep" = 1 ]; then echo "dossier gardé : $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

pass=0
fail=0
check() {
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  attendu : %s\n  obtenu  : %s\n' "$1" "$2" "$3"
	fi
}
has() {
	if grep -Eq -- "$2" <<<"$3"; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  motif absent : %s\n' "$1" "$2"
		printf '%s\n' "$3" | tail -15 | sed 's/^/    | /'
	fi
}
hasnt() {
	if grep -Eq -- "$2" <<<"$3"; then
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  motif présent : %s\n' "$1" "$2"
		printf '%s\n' "$3" | grep -E -- "$2" | head -5 | sed 's/^/    | /'
	else
		pass=$((pass + 1))
	fi
}

new_loop() { # new_loop <variable> <nom> <taille>
	local f="$T/$2.img" l
	truncate -s "$3" "$f"
	l=$(losetup -f --show "$f") || { echo "losetup impossible" >&2; exit 2; }
	LOOPS="$LOOPS $l"
	printf -v "$1" '%s' "$l"
}
assert_ours() {
	local back
	case "$1" in /dev/loop[0-9]*) ;; *) echo "REFUS : $1 n'est pas un loop device" >&2; exit 3 ;; esac
	back=$(losetup -nO BACK-FILE "$1" 2>/dev/null | sed 's/[[:space:]]*$//')
	case "$back" in "$T"/*) ;; *) echo "REFUS : $1 n'est pas un disque de test ($back)" >&2; exit 3 ;; esac
}
R="$T/root"
ESP="$R/boot"
enc() {
	local a
	for a in "$@"; do case "$a" in /dev/*) [ "$a" = /dev/null ] || assert_ours "$a" ;; esac; done
	out=$(setsid -w bash "$S" --virtual-only --tpm2-device "$TPMDEV" "$@" < /dev/null 2>&1)
	rc=$?
	out=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
}
# Types d'emplacements d'un volume, triés (« password tpm2 tpm2 »).
types() { systemd-cryptenroll "$1" 2>/dev/null | awk 'NR > 1 { print $2 }' | sort | tr '\n' ' ' | sed 's/ $//'; }
ntpm() { systemd-cryptenroll "$1" 2>/dev/null | awk 'NR > 1 && $2 == "tpm2"' | wc -l; }
# PCR des jetons TPM d'un volume, triés (« 0+7 0+7+11 »).
tokpcrs() { cryptsetup luksDump "$1" | rago_luks_tpm2_tokens | awk '{ print $3 }' | sort | tr '\n' ' ' | sed 's/ $//'; }
policies() { cryptsetup luksDump "$1" | rago_luks_tpm2_tokens | awk '{ print $4 }' | sort; }

# --- TPM 2.0 émulé ----------------------------------------------------------------------------------
mkdir -p "$T/tpm"
swtpm socket --tpm2 --tpmstate dir="$T/tpm" --server type=unixio,path="$T/tpm.sock" \
	--ctrl type=unixio,path="$T/tpm.sock.ctrl" --flags not-need-init,startup-clear \
	--daemon --pid file="$T/swtpm.pid" --log file="$T/swtpm.log" || { echo "swtpm ne démarre pas" >&2; exit 2; }
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$T/tpm.sock" ] && break; sleep 0.2; done
TPMDEV="swtpm:path=$T/tpm.sock"
export TPM2TOOLS_TCTI=$TPMDEV
tpm2_pcrread sha256:0,7 >/dev/null || { echo "swtpm injoignable" >&2; exit 2; }
measure() { tpm2_pcrextend "$1:sha256=$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"; }
pcr() { tpm2_pcrread "sha256:$1" | awk -F: '/0x/ { gsub(/[ \t]|0x/, "", $2); print tolower($2) }'; }

# --- passphrase, volumes ------------------------------------------------------------------------------
printf '%s' "cheval-agrafe-batterie-42" > "$T/pass"
chmod 600 "$T/pass"
FAST=(--iter-time 100 --pbkdf-memory 32768)
new_loop LA a 48M
new_loop LB b 48M
new_loop LS swap 48M
for v in "$LA:root-a" "$LB:root-b" "$LS:swap"; do
	enc --device "${v%%:*}" --role "${v##*:}" --yes --passphrase-file "$T/pass" --no-mkswap "${FAST[@]}" format
	[ "$rc" = 0 ] || { echo "format ${v##*:} impossible :"; printf '%s\n' "$out" | tail -5; exit 1; }
done
UA=$(cryptsetup luksUUID "$LA")
UB=$(cryptsetup luksUUID "$LB")
US=$(cryptsetup luksUUID "$LS")
echo "disques de test : A=$LA B=$LB swap=$LS (fichiers dans $T)"

# --- fausse racine : M3 + M4 installés, ESP, clé MOK -------------------------------------------------
mkdir -p "$R/etc/rago/secureboot" "$ESP/EFI/Linux" "$ESP/loader/entries"
cat > "$R/etc/rago/encryption.conf" <<EOF
# Rago OS — chiffrement du disque (module M3). Marqueur : rago-secure-encryption
RAGO_ENC_SLOT="a"
RAGO_ENC_ROOT_A_UUID="$UA"
RAGO_ENC_ROOT_B_UUID="$UB"
RAGO_ENC_SWAP_UUID="$US"
RAGO_ENC_TPM_PCRS="0+7"
EOF
printf 'RAGO_CMDLINE="root=/dev/mapper/rago-root rw"\nRAGO_ESP=/boot\n' > "$R/etc/rago/kernel.conf"
printf '# Rago OS — M4. Marqueur : %s\nRAGO_AB_MODE="uki"\nRAGO_AB_PCR11="1"\n' "$RAGO_AB_MARKER" > "$R/etc/rago/update.conf"
openssl req -new -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=Rago test MOK/" \
	-keyout "$R/etc/rago/secureboot/MOK.key" -out "$R/etc/rago/secureboot/MOK.crt" > /dev/null 2>&1
openssl req -new -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=Autre clé/" \
	-keyout "$T/other.key" -out "$T/other.crt" > /dev/null 2>&1
head -c 200000 /dev/urandom > "$T/linux"
head -c 100000 /dev/urandom > "$T/initrd"
mk_uki() { # mk_uki <sortie> <slot> [cmdline] [rago:oui|non] [clé] [section en plus]
	local out=$1 slot=$2 cl=${3:-root=/dev/mapper/rago-root rw rd.shell=0} meta=${4:-oui} key=${5:-$R/etc/rago/secureboot/MOK}
	local a=()
	printf 'slot=%s\nkernel=7.0.0-test\nversion=t\npcr11-phases=enter-initrd\n' "$slot" > "$T/meta"
	printf 'NAME="Rago OS"\nID=rago\n' > "$T/osrel"
	[ "$meta" = oui ] && a+=(--section=.rago:@"$T/meta")
	[ -n "${6:-}" ] && a+=(--section="$6")
	ukify build --linux="$T/linux" --initrd="$T/initrd" --cmdline="$cl" --os-release=@"$T/osrel" --uname=7.0.0-test \
		"${a[@]}" --stub="$STUB" --signtool=sbsign --no-sign-kernel \
		--secureboot-private-key="$key.key" --secureboot-certificate="$key.crt" --output="$out" > "$T/ukify.log" 2>&1 ||
		{ echo "ukify : $(tail -2 "$T/ukify.log")"; exit 1; }
}
m0_entry() { printf 'title Rago OS\nlinux /vmlinuz-linux-rago\ninitrd /initramfs-linux-rago.img\noptions root=/dev/mapper/rago-root rw\n' > "$ESP/loader/entries/rago.conf"; }

# =====================================================================================
# 1. refus : PCR jamais mesurés, ESP sans entrée du slot en marche
# =====================================================================================
m0_entry
mk_uki "$ESP/EFI/Linux/rago-a.efi" a
enc --root "$R" --passphrase-file "$T/pass" enroll-tpm
check "PCR jamais mesurés : refus" 1 "$rc"
has "PCR jamais mesurés : raison" 'jamais mesurés par le firmware' "$out"
check "PCR jamais mesurés : aucun jeton" 0 "$(ntpm "$LA")"
measure 0 "firmware OVMF de test"
measure 7 "état Secure Boot de test"
mv "$ESP/EFI/Linux/rago-a.efi" "$T/rago-a.efi.save"
rm -f "$ESP/loader/entries/rago.conf"
enc --root "$R" --passphrase-file "$T/pass" enroll-tpm
check "ESP sans entrée du slot A : refus" 1 "$rc"
has "ESP sans entrée : raison (ESP pas montée ?)" 'aucune entrée de démarrage Rago du slot a.*rien n.est changé' "$out"
check "ESP sans entrée : aucun jeton" "0 0 0" "$(ntpm "$LA") $(ntpm "$LB") $(ntpm "$LS")"
mv "$T/rago-a.efi.save" "$ESP/EFI/Linux/rago-a.efi"
m0_entry

# =====================================================================================
# 2. mise en place : entrée de M0 (PCR 0+7) + UKI du slot A (PCR 0+7+11 prédit)
# =====================================================================================
enc --root "$R" --passphrase-file "$T/pass" enroll-tpm
check "enroll-tpm A/B (code)" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -15
has "entrée de M0 : jeton PCR 0+7" 'entrée rago.conf \(slot a\) : jeton PCR 0\+7$' "$out"
has "UKI A : jeton PCR 0+7+11 prédit" 'entrée rago-a.efi \(slot a\) : jeton PCR 0\+7 \+ 11 \(UKI signée, PCR 11 prédit' "$out"
hasnt "politique calculée = celle de systemd-cryptenroll (jamais d'écart)" "n'a pas la politique attendue" "$out"
check "racine A : passphrase + 2 jetons (M0, UKI A)" "password tpm2 tpm2" "$(types "$LA")"
check "racine A : PCR des jetons" "0+7 0+7+11" "$(tokpcrs "$LA")"
check "racine B : aucune entrée ne l'ouvre, passphrase seule" "password" "$(types "$LB")"
has "racine B : dit" 'root-b .* : aucune entrée de démarrage ne l.ouvre' "$out"
check "swap : passphrase + 2 jetons" "password tpm2 tpm2" "$(types "$LS")"
# Le jeton de l'UKI porte la valeur PRÉDITE de PCR 11 : sa politique = celle
# recalculée avec les PCR 0 et 7 du TPM et la prédiction lue dans l'UKI.
pred=$(rago_uki_unlock_pcr11 "$ESP/EFI/Linux/rago-a.efi")
want=$(rago_tpm2_policy_pcr "0=$(pcr 0)" "7=$(pcr 7)" "11=$pred")
check "jeton UKI A : politique = PCR 0 + 7 actuels + PCR 11 prédit" 1 "$(policies "$LA" | grep -c "^$want$")"
check "jeton UKI A : PCR 11 du TPM n'a rien à voir (jamais lu)" 0 "$(policies "$LA" | grep -c "^$(rago_tpm2_policy_pcr "0=$(pcr 0)" "7=$(pcr 7)" "11=$(pcr 11)")$")"
enc --root "$R" --passphrase-file "$T/pass" reseal
check "reseal sans changement (code)" 0 "$rc"
has "reseal sans changement : rien à faire, pas de passphrase demandée" 'chaque entrée de démarrage a déjà son jeton TPM : pas besoin de la passphrase' "$out"
check "reseal sans changement : jetons inchangés" "password tpm2 tpm2" "$(types "$LA")"
enc --root "$R" reseal
check "reseal sans changement, sans passphrase (service) : code" 0 "$rc"

# =====================================================================================
# 3. slot B écrit (apply) : sa racine reçoit le jeton de SON UKI, le swap aussi
# =====================================================================================
mk_uki "$ESP/EFI/Linux/rago-b.efi" b "root=/dev/mapper/rago-root rw rd.shell=0 slot-b"
enc --root "$R" reseal
check "nouvelle UKI sans passphrase ni terminal : échec propre" 1 "$rc"
check "nouvelle UKI sans passphrase : rien retiré" "password tpm2 tpm2|password" "$(types "$LA")|$(types "$LB")"
enc --root "$R" --passphrase-file "$T/pass" reseal
check "reseal avec l'UKI B (code)" 0 "$rc"
check "racine B : passphrase + jeton de l'UKI B" "password tpm2" "$(types "$LB")"
check "racine B : PCR 0+7+11" "0+7+11" "$(tokpcrs "$LB")"
check "racine A : inchangée" "password tpm2 tpm2" "$(types "$LA")"
check "swap : 3 jetons (M0, UKI A, UKI B)" "password tpm2 tpm2 tpm2" "$(types "$LS")"
has "racine A : déjà à jour, pas réenrôlée" 'root-a : jeton TPM à jour pour rago.conf' "$out"

# =====================================================================================
# 4. confirmation de la mise en place : entrée de M0 retirée -> prune-tpm
# =====================================================================================
rm -f "$ESP/loader/entries/rago.conf"
enc --root "$R" prune-tpm
check "prune-tpm (code)" 0 "$rc"
check "racine A : jeton PCR 0+7 de M0 retiré, celui de l'UKI gardé" "0+7+11" "$(tokpcrs "$LA")"
check "racine A : passphrase gardée" "password tpm2" "$(types "$LA")"
check "swap : 2 jetons (UKI A, UKI B)" "password tpm2 tpm2" "$(types "$LS")"
has "prune-tpm : retrait annoncé" 'retrait du jeton TPM qui ne sert plus .*PCR 0\+7\)' "$out"

# =====================================================================================
# 5. nouvelle UKI A (ligne de commande changée) : rien retiré tant qu'elle n'a pas son jeton
# =====================================================================================
cp "$ESP/EFI/Linux/rago-a.efi" "$T/rago-a.old.efi"
mk_uki "$ESP/EFI/Linux/rago-a.efi" a "root=/dev/mapper/rago-root rw rd.shell=0 quiet"
enc --root "$R" prune-tpm
check "prune-tpm, jeton manquant : code 1" 1 "$rc"
has "prune-tpm, jeton manquant : expliqué" 'pas de jeton TPM pour rago-a.efi' "$out"
check "prune-tpm, jeton manquant : ancien jeton gardé (rien retiré)" "password tpm2" "$(types "$LA")"
enc --root "$R" tpm-check
check "tpm-check : jetons manquants signalés (code 1)" 1 "$rc"
has "tpm-check : état a=refused" '^  a=refused$' "$out"
has "tpm-check : b=ok" '^  b=ok$' "$out"
has "tpm-check : reseal conseillé" 'sudo rago-encryption reseal' "$out"
enc --root "$R" --passphrase-file "$T/pass" reseal
check "reseal nouvelle UKI A (code)" 0 "$rc"
check "racine A : un seul jeton (le nouveau), passphrase gardée" "password tpm2" "$(types "$LA")"
check "racine A : le jeton est celui de la nouvelle UKI" 1 \
	"$(policies "$LA" | grep -c "^$(rago_tpm2_policy_pcr "0=$(pcr 0)" "7=$(pcr 7)" "11=$(rago_uki_unlock_pcr11 "$ESP/EFI/Linux/rago-a.efi")")$")"
enc --root "$R" tpm-check
check "tpm-check après reseal (code)" 0 "$rc"
has "tpm-check : a=ok b=ok swap=ok" '^  a=ok$' "$out"

# =====================================================================================
# 6. UKI refusées : non signée MOK, slot qui ne correspond pas au nom
# =====================================================================================
mk_uki "$ESP/EFI/Linux/rago-b.next.efi" b "x" oui "$T/other"
enc --root "$R" --passphrase-file "$T/pass" reseal
check "UKI signée par une autre clé : reseal (code)" 0 "$rc"
has "UKI signée par une autre clé : ignorée" 'rago-b.next.efi : pas signée par la clé MOK .* ignorée' "$out"
check "UKI signée par une autre clé : aucun jeton pour elle" "password tpm2" "$(types "$LB")"
cp "$T/rago-a.old.efi" "$ESP/EFI/Linux/rago-b.next.efi"
enc --root "$R" --passphrase-file "$T/pass" reseal
has "UKI du slot A sous le nom du slot B : ignorée" 'rago-b.next.efi : UKI du slot « a » sous le nom du slot b : ignorée' "$out"
check "UKI du slot A sous le nom du slot B : rien sur la racine B" "password tpm2" "$(types "$LB")"
rm -f "$ESP/EFI/Linux/rago-b.next.efi"

# =====================================================================================
# 7. dégradation gracieuse : PCR 0+7 (signalé), jamais de brique
# =====================================================================================
mk_uki "$ESP/EFI/Linux/rago-b.next.efi" b "root=/dev/mapper/rago-root rw" non
enc --root "$R" --passphrase-file "$T/pass" reseal
check "UKI sans métadonnées Rago : reseal (code)" 0 "$rc"
has "UKI sans métadonnées Rago : PCR 0+7 seulement, signalé" 'rago-b.next.efi : UKI sans métadonnées Rago .* PCR 0\+7 seulement \(dégradé\)' "$out"
check "UKI sans métadonnées Rago : racine B, jeton PCR 0+7 en plus" "0+7 0+7+11" "$(tokpcrs "$LB")"
printf 'ID=profil\n' > "$T/profile"
mk_uki "$ESP/EFI/Linux/rago-b.next.efi" b "root=/dev/mapper/rago-root rw" oui "$R/etc/rago/secureboot/MOK" ".profile:@$T/profile"
enc --root "$R" --passphrase-file "$T/pass" reseal
has "UKI à profils : PCR 11 non prédit, PCR 0+7 (dégradé)" 'rago-b.next.efi : UKI à sections non prises en charge' "$out"
check "UKI à profils : racine B toujours 2 jetons (même politique PCR 0+7)" "0+7 0+7+11" "$(tokpcrs "$LB")"
rm -f "$ESP/EFI/Linux/rago-b.next.efi"
enc --root "$R" prune-tpm
check "après retrait de l'essai : racine B, jeton PCR 0+7 retiré" "0+7+11" "$(tokpcrs "$LB")"
sed -i 's/^RAGO_AB_PCR11=.*/RAGO_AB_PCR11="0"/' "$R/etc/rago/update.conf"
enc --root "$R" --passphrase-file "$T/pass" reseal
check "RAGO_AB_PCR11=0 : reseal (code)" 0 "$rc"
check "RAGO_AB_PCR11=0 : racine A en PCR 0+7" "0+7" "$(tokpcrs "$LA")"
check "RAGO_AB_PCR11=0 : swap, un seul jeton PCR 0+7 (même politique pour les deux UKI)" "0+7" "$(tokpcrs "$LS")"
check "RAGO_AB_PCR11=0 : passphrase gardée partout" "password tpm2|password tpm2|password tpm2" "$(types "$LA")|$(types "$LB")|$(types "$LS")"
sed -i 's/^RAGO_AB_PCR11=.*/RAGO_AB_PCR11="1"/' "$R/etc/rago/update.conf"
enc --root "$R" --passphrase-file "$T/pass" reseal
check "retour à PCR 11 : racine A" "0+7+11" "$(tokpcrs "$LA")"
check "retour à PCR 11 : swap, 2 jetons" "0+7+11 0+7+11" "$(tokpcrs "$LS")"

# =====================================================================================
# 8. firmware changé (PCR 0) : jetons refusés, reseal les refait ; verify
# =====================================================================================
measure 0 "mise à jour du BIOS"
enc --root "$R" tpm-check
check "PCR 0 changé : tpm-check code 1" 1 "$rc"
has "PCR 0 changé : a=refused" '^  a=refused$' "$out"
enc --root "$R" verify
check "PCR 0 changé : verify en échec" 1 "$rc"
has "verify : entrée sans jeton à jour signalée" 'ÉCHEC.*rago-a.efi' "$out"
enc --root "$R" --passphrase-file "$T/pass" reseal
check "PCR 0 changé : reseal (code)" 0 "$rc"
check "PCR 0 changé : racine A, un jeton à jour" "0+7+11" "$(tokpcrs "$LA")"
enc --root "$R" tpm-check
check "après reseal : tpm-check" 0 "$rc"
enc --root "$R" verify
has "verify : jetons A/B à jour" '\[ OK \].*slot A : jeton TPM à jour pour rago-a.efi' "$out"
for l in "$LA" "$LB" "$LS"; do
	check "$(basename "$l") : la passphrase ouvre toujours" 0 "$(printf 'cheval-agrafe-batterie-42\n' | cryptsetup open --test-passphrase --disable-external-tokens --batch-mode "$l" >/dev/null 2>&1; echo $?)"
done

echo "test_ab_tpm_loop : $pass OK, $fail échec(s)"
[ "$fail" -eq 0 ]
