#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test de host/setup_secure_encryption.sh sur des disques VIRTUELS
# (loop devices sur des fichiers jetables) avec un TPM 2.0 émulé (swtpm).
# Module M3.
#
# SÉCURITÉ : jamais de vrai disque. Chaque volume est un loop device dont le
# fichier est dans le dossier de travail du test (vérifié avant chaque
# commande), et le script est toujours lancé avec --virtual-only.
#
# Vérifie : format (LUKS2 aes-xts-plain64 512 bits, sha512, argon2id,
# étiquettes), règles de la passphrase de secours, refus (volume monté, pas de
# terminal pour confirmer), enrôlement TPM (PCR 0+7) qui garde la passphrase,
# refus d'enrôler sur des PCR jamais mesurés / avec une mauvaise passphrase /
# sur un volume sans passphrase (TPM seul), install sur les vrais volumes,
# verify, changement de PCR 7 (Secure Boot) repéré puis « reseal ».
#
# Le vrai descellement par le TPM (jeton systemd-tpm2) a besoin d'un TPM du
# noyau et de dm-crypt : il est testé dans la VM (tests/vm/run_m3_vm_test.sh).
#
# Usage (root) : host/tests/test_encryption_loop.sh [--keep]
# Dépendances : losetup, cryptsetup ≥ 2.4, systemd-cryptenroll, swtpm,
# tpm2-tools, mkfs.ext4.
set -u

here=$(cd "$(dirname "$0")" && pwd)
S="$here/../setup_secure_encryption.sh"
keep=0
[ "${1:-}" = --keep ] && keep=1

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (loop devices)" >&2; exit 2; }
for t in losetup cryptsetup systemd-cryptenroll swtpm tpm2_pcrextend tpm2_pcrread mkfs.ext4 python3; do
	command -v "$t" >/dev/null || { echo "outil manquant : $t" >&2; exit 2; }
done

T=$(mktemp -d /var/tmp/rago-m3-loop.XXXXXX)
LOOPS=""
cleanup() {
	local l
	umount "$T/mnt" 2>/dev/null || true
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
		printf '%s\n' "$3" | sed 's/^/    | /' | tail -15
	fi
}

# --- disques virtuels -------------------------------------------------------------------
new_loop() { # new_loop <variable> <nom> <taille> : crée le loop device, le met dans <variable>
	local f="$T/$2.img" l
	truncate -s "$3" "$f"
	l=$(losetup -f --show "$f") || { echo "losetup impossible" >&2; exit 2; }
	LOOPS="$LOOPS $l"
	printf -v "$1" '%s' "$l"
}
# Garde-fou : un loop device sur un fichier du dossier de test, rien d'autre.
assert_ours() {
	local back
	case "$1" in /dev/loop[0-9]*) ;; *) echo "REFUS : $1 n'est pas un loop device" >&2; exit 3 ;; esac
	back=$(losetup -nO BACK-FILE "$1" 2>/dev/null | sed 's/[[:space:]]*$//')
	case "$back" in "$T"/*) ;; *) echo "REFUS : $1 n'est pas un disque de test ($back)" >&2; exit 3 ;; esac
}
# Le script, toujours en mode disques virtuels ; sortie sans couleurs dans $out.
enc() {
	local a
	for a in "$@"; do case "$a" in /dev/*) [ "$a" = /dev/null ] || assert_ours "$a" ;; esac; done
	out=$(setsid -w bash "$S" --virtual-only "$@" < /dev/null 2>&1)
	rc=$?
	out=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
}
slots() { systemd-cryptenroll "$1" 2>/dev/null | awk 'NR > 1 { print $1 ":" $2 }' | tr '\n' ' ' | sed 's/ $//'; }
# Types d'emplacements (sans leurs numéros, qui changent à chaque reseal).
types() { systemd-cryptenroll "$1" 2>/dev/null | awk 'NR > 1 { print $2 }' | sort | tr '\n' ' ' | sed 's/ $//'; }
dumpval() { cryptsetup luksDump "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*//p" | head -1; }
tok_json() { # tok_json <volume> <champ> : champ du (premier) jeton systemd-tpm2
	local id
	id=$(cryptsetup luksDump "$1" | awk '/^Tokens:/ { t = 1; next } t && /systemd-tpm2/ { sub(":", "", $1); print $1; exit }')
	[ -n "$id" ] || return 1
	cryptsetup token export --token-id "$id" "$1" | python3 -c 'import json, sys; v = json.load(sys.stdin).get(sys.argv[1]); print(v if not isinstance(v, list) else "+".join(map(str, v)))' "$2"
}

# --- TPM 2.0 émulé ----------------------------------------------------------------------
mkdir -p "$T/tpm"
swtpm socket --tpm2 --tpmstate dir="$T/tpm" --server type=unixio,path="$T/tpm.sock" \
	--ctrl type=unixio,path="$T/tpm.sock.ctrl" --flags not-need-init,startup-clear \
	--daemon --pid file="$T/swtpm.pid" --log file="$T/swtpm.log" || { echo "swtpm ne démarre pas" >&2; exit 2; }
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$T/tpm.sock" ] && break; sleep 0.2; done
TPMDEV="swtpm:path=$T/tpm.sock"
export TPM2TOOLS_TCTI=$TPMDEV
tpm2_pcrread sha256:0,7 >/dev/null || { echo "swtpm injoignable" >&2; exit 2; }
# Ce que ferait le firmware : mesurer son code (PCR 0) et l'état Secure Boot (PCR 7).
measure() { tpm2_pcrextend "$1:sha256=$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"; }

# --- passphrases ------------------------------------------------------------------------
secret() { printf '%s' "$2" > "$T/$1"; chmod 600 "$T/$1"; echo "$T/$1"; }
PASS=$(secret pass "cheval-agrafe-batterie-42")
printf '\n' >> "$PASS" # comme « echo » : le retour final est ignoré
WRONG=$(secret wrong "pas-la-bonne-passe-00")
SHORT=$(secret short "court-11car")
CTRL=$(secret ctrl "$(printf 'ligne-un-assez\tlongue')")
ACC=$(secret acc "phrase-évidente-du-joueur")
OPEN=$(secret open "cheval-agrafe-batterie-42")
chmod 644 "$OPEN"
FAST=(--iter-time 100 --pbkdf-memory 32768) # argon2id rapide pour les tests

new_loop LA a 48M
new_loop LB b 48M
new_loop LS swap 48M
new_loop LX x 48M
new_loop LM m 32M
echo "disques de test : A=$LA B=$LB swap=$LS X=$LX M=$LM (fichiers dans $T)"

# =====================================================================================
# 1. format : refus
# =====================================================================================
enc --device "$LX" --role root-a --yes --passphrase-file "$OPEN" "${FAST[@]}" format
check "refus : passphrase lisible par d'autres" 1 "$rc"
has "refus : mode du fichier expliqué" "lisible par d'autres comptes.*chmod 600" "$out"
enc --device "$LX" --role root-a --yes --passphrase-file "$SHORT" "${FAST[@]}" format
check "refus : passphrase de 11 caractères" 1 "$rc"
has "refus : trop courte" 'trop courte : 12 caractères' "$out"
enc --device "$LX" --role root-a --yes --passphrase-file "$CTRL" "${FAST[@]}" format
check "refus : tabulation" 1 "$rc"
has "refus : caractère de contrôle" 'caractère de contrôle' "$out"
enc --device "$LX" --role root-a "${FAST[@]}" format
check "refus : sans --yes et sans terminal" 1 "$rc"
has "refus : confirmation impossible" 'pas de terminal pour confirmer' "$out"
enc --device "$LX" --role root-a --yes "${FAST[@]}" format
check "refus : passphrase sans terminal ni fichier" 1 "$rc"
has "refus : passphrase impossible à taper" 'pas de terminal pour taper la passphrase' "$out"
check "refus : rien écrit sur le disque" "" "$(blkid -p -o value -s TYPE "$LX" 2>/dev/null)"
mkfs.ext4 -q "$LM"
mkdir -p "$T/mnt"
if mount "$LM" "$T/mnt" 2>/dev/null; then
	enc --device "$LM" --role root-a --yes --passphrase-file "$PASS" "${FAST[@]}" format
	check "refus : volume monté" 1 "$rc"
	has "refus : monté, raison" 'est monté' "$out"
	umount "$T/mnt"
	check "refus : ext4 intact" ext4 "$(blkid -p -o value -s TYPE "$LM")"
else
	echo "  (montage impossible ici : refus « volume monté » non testé)"
fi
enc --device "$T/a.img" --role root-a --yes --passphrase-file "$PASS" format
check "refus : fichier (pas un périphérique bloc)" 1 "$rc"

# Accents : acceptés, avec un avertissement (clavier QWERTY au démarrage).
enc --device "$LX" --role root-a --yes --passphrase-file "$ACC" "${FAST[@]}" format
check "accents : format (code)" 0 "$rc"
has "accents : avertissement clavier" 'accentués.*QWERTY' "$out"

# =====================================================================================
# 2. format : les trois volumes Rago
# =====================================================================================
enc --device "$LA" --role root-a --yes --passphrase-file "$PASS" "${FAST[@]}" format
check "format slot A (code)" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -10
has "format : paramètres annoncés" 'LUKS2 aes-xts-plain64 512 bits, sha512, argon2id, étiquette rago-a' "$out"
has "format : passphrase vérifiée" 'passphrase de secours posée \(emplacement 0\) et vérifiée' "$out"
check "LUKS version" 2 "$(dumpval "$LA" Version)"
check "étiquette" rago-a "$(dumpval "$LA" Label)"
check "chiffrement" aes-xts-plain64 "$(dumpval "$LA" cipher)"
check "taille de clé" "512 bits" "$(dumpval "$LA" Key)"
check "PBKDF" argon2id "$(dumpval "$LA" PBKDF)"
check "AF hash" sha512 "$(dumpval "$LA" 'AF hash')"
check "hash du condensé" sha512 "$(cryptsetup luksDump "$LA" | awk '/^Digests:/ { d = 1 } d && /Hash:/ { print $2; exit }')"
check "1 seule passphrase" "0:password" "$(slots "$LA")"
check "la passphrase ouvre (comme tapée au clavier)" 0 "$(printf 'cheval-agrafe-batterie-42\n' | cryptsetup open --test-passphrase --batch-mode "$LA" >/dev/null 2>&1; echo $?)"
check "une autre passphrase n'ouvre pas" 2 "$(printf 'pas-la-bonne-passe-00\n' | cryptsetup open --test-passphrase --batch-mode "$LA" >/dev/null 2>&1; echo $?)"
enc --device "$LB" --role root-b --yes --passphrase-file "$PASS" "${FAST[@]}" format
check "format slot B (code)" 0 "$rc"
check "étiquette B" rago-b "$(dumpval "$LB" Label)"
# Le swap est créé dans le volume ouvert : dm-crypt requis (fait dans la VM).
enc --device "$LS" --role swap --no-mkswap --yes --passphrase-file "$PASS" "${FAST[@]}" format
check "format swap (code)" 0 "$rc"
check "étiquette swap" rago-swap "$(dumpval "$LS" Label)"
check "UUID différents" 3 "$(for l in "$LA" "$LB" "$LS"; do cryptsetup luksUUID "$l"; done | sort -u | wc -l)"

# =====================================================================================
# 3. enrôlement TPM
# =====================================================================================
ROOT="$T/root"
mkdir -p "$ROOT"
enc --root "$ROOT" --device "$LA" --tpm2-device "$TPMDEV" --passphrase-file "$PASS" enroll-tpm
check "refus : PCR jamais mesurés (code)" 1 "$rc"
has "refus : PCR jamais mesurés, raison" 'PCR 0 7 jamais mesurés.*ne protégerait rien' "$out"
check "refus : pas de TPM ajouté" "0:password" "$(slots "$LA")"

measure 0 "firmware OVMF v1"
measure 7 "Secure Boot : off"
enc --root "$ROOT" --tpm2-device "$TPMDEV" check
has "check : TPM donné" '\[ OK \] +TPM donné : swtpm' "$out"
has "check : PCR mesurés" '\[ OK \] +PCR 0\+7 mesurés' "$out"

enc --root "$ROOT" --device "$LA" --tpm2-device "$TPMDEV" --passphrase-file "$WRONG" enroll-tpm
check "refus : mauvaise passphrase (code)" 1 "$rc"
has "refus : mauvaise passphrase, raison" "la passphrase de secours n'ouvre pas.*rien n'a été changé" "$out"
check "refus : toujours pas de TPM" "0:password" "$(slots "$LA")"

enc --root "$ROOT" --device "$LA" --tpm2-device "$TPMDEV" --passphrase-file "$PASS" --dry-run enroll-tpm
check "--dry-run enroll (code)" 0 "$rc"
has "--dry-run : commande affichée" '\[dry-run\] systemd-cryptenroll --tpm2-device=swtpm:path=.* --tpm2-pcrs=0\+7 --wipe-slot=tpm2' "$out"
check "--dry-run : rien changé" "0:password" "$(slots "$LA")"

for v in "$LA" "$LB" "$LS"; do
	enc --root "$ROOT" --device "$v" --tpm2-device "$TPMDEV" --passphrase-file "$PASS" enroll-tpm
	check "enroll-tpm $v (code)" 0 "$rc"
	[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -10
	check "enroll-tpm $v : passphrase + TPM" "0:password 1:tpm2" "$(slots "$v")"
	check "enroll-tpm $v : PCR 0+7" "0+7" "$(tok_json "$v" tpm2-pcrs)"
done
has "enroll : risque PCR 7 expliqué" 'Risque PCR 7.*' "$out"
has "enroll : commande reseal donnée" 'sudo rago-encryption reseal' "$out"
check "enroll : passphrase de secours gardée (ouvre)" 0 "$(printf 'cheval-agrafe-batterie-42\n' | cryptsetup open --test-passphrase --disable-external-tokens --batch-mode "$LA" >/dev/null 2>&1; echo $?)"
check "enroll : une autre n'ouvre toujours pas" 2 "$(printf 'pas-la-bonne-passe-00\n' | cryptsetup open --test-passphrase --disable-external-tokens --batch-mode "$LA" >/dev/null 2>&1; echo $?)"
check "enroll : PCR notés" 2 "$(grep -vc '^#' "$ROOT/var/lib/rago/encryption/pcrs-at-enroll")"
# Ré-enrôler remplace l'ancien enrôlement (jamais deux) et garde la passphrase.
enc --root "$ROOT" --device "$LA" --tpm2-device "$TPMDEV" --passphrase-file "$PASS" enroll-tpm
check "ré-enrôlement (code)" 0 "$rc"
check "ré-enrôlement : un seul TPM, passphrase gardée" 2 "$(systemd-cryptenroll "$LA" | awk 'NR > 1' | wc -l)"
check "ré-enrôlement : la passphrase est toujours l'emplacement 0" "0:password" "$(slots "$LA" | cut -d' ' -f1)"

# Volume où ne reste QUE le TPM (passphrase retirée à la main) : refus et alarme.
mkdir -p "$T/rootx"
enc --device "$LX" --role root-a --yes --passphrase-file "$PASS" "${FAST[@]}" format
enc --root "$T/rootx" --device "$LX" --tpm2-device "$TPMDEV" --passphrase-file "$PASS" enroll-tpm
check "volume X enrôlé" "password tpm2" "$(types "$LX")"
systemd-cryptenroll --wipe-slot=password "$LX" < /dev/null > /dev/null 2>&1
check "volume X : TPM seul" "tpm2" "$(types "$LX")"
enc --root "$T/rootx" --device "$LX" --tpm2-device "$TPMDEV" --passphrase-file "$PASS" reseal
check "refus : reseal sans passphrase de secours" 1 "$rc"
has "refus : jamais le TPM seul" 'AUCUNE passphrase de secours : refusé \(jamais le TPM seul\)' "$out"
check "refus : volume X inchangé" "tpm2" "$(types "$LX")"
mkdir -p "$T/rootx/usr/bin" "$T/rootx/usr/lib/dracut/modules.d/90crypt" "$T/rootx/usr/lib/dracut/modules.d/00systemd"
printf '#!/bin/sh\n' > "$T/rootx/usr/bin/dracut"; chmod 755 "$T/rootx/usr/bin/dracut"
enc --root "$T/rootx" --root-device "$LX" install
enc --root "$T/rootx" --tpm2-device "$TPMDEV" verify
check "verify : TPM seul -> échec" 1 "$rc"
has "verify : alarme TPM seul" 'ÉCHEC.*AUCUNE passphrase de secours.*DANGER' "$out"

# =====================================================================================
# 4. install sur les vrais volumes, verify
# =====================================================================================
mkdir -p "$ROOT/etc/rago" "$ROOT/usr/bin" "$ROOT/boot" "$ROOT/usr/lib/modules/7.0.0-14-generic"
for m in 00systemd 90crypt 01systemd-cryptsetup 91tpm2-tss 95resume; do mkdir -p "$ROOT/usr/lib/dracut/modules.d/$m"; done
printf '#!/bin/sh\n' > "$ROOT/usr/bin/dracut"; printf '#!/bin/sh\n' > "$ROOT/usr/bin/tpm2"; chmod 755 "$ROOT/usr/bin/dracut" "$ROOT/usr/bin/tpm2"
: > "$ROOT/usr/lib/modules/7.0.0-14-generic/modules.dep"
: > "$ROOT/boot/initrd.img-7.0.0-14-generic"
printf 'RAGO_CMDLINE="root=UUID=x rw quiet"\nRAGO_CMDLINE_EXTRA=""\n' > "$ROOT/etc/rago/kernel.conf"
UA=$(cryptsetup luksUUID "$LA"); UB=$(cryptsetup luksUUID "$LB"); US=$(cryptsetup luksUUID "$LS")
enc --root "$ROOT" --root-device "$LA" --other-slot-device "$LB" --swap-device "$LS" install
check "install (code)" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -10
check "install : slot a (étiquette rago-a)" 'RAGO_ENC_SLOT="a"' "$(grep '^RAGO_ENC_SLOT=' "$ROOT/etc/rago/encryption.conf")"
check "install : crypttab rago-root = volume A" "UUID=$UA" "$(awk '$1 == "rago-root" { print $2 }' "$ROOT/etc/crypttab")"
check "install : crypttab rago-swap = swap" "UUID=$US" "$(awk '$1 == "rago-swap" { print $2 }' "$ROOT/etc/crypttab")"
check "install : slot B noté" "RAGO_ENC_ROOT_B_UUID=\"$UB\"" "$(grep '^RAGO_ENC_ROOT_B_UUID=' "$ROOT/etc/rago/encryption.conf")"
# Slot B détecté par son étiquette (rago-b), sans --slot.
ROOTB="$T/rootb"
cp -a "$ROOT" "$ROOTB"
rm -rf "${ROOTB:?}/etc/rago/encryption.conf" "${ROOTB:?}/etc/crypttab" "${ROOTB:?}/var"
enc --root "$ROOTB" --root-device "$LB" --other-slot-device "$LA" --swap-device "$LS" install
check "install slot B (code)" 0 "$rc"
check "install slot B : détecté par l'étiquette" 'RAGO_ENC_SLOT="b"' "$(grep '^RAGO_ENC_SLOT=' "$ROOTB/etc/rago/encryption.conf")"
check "install slot B : rago-root = volume B" "UUID=$UB" "$(awk '$1 == "rago-root" { print $2 }' "$ROOTB/etc/crypttab")"
enc --root "$ROOT" --root-device "$LS" --swap-device "$LS" install
check "refus : racine = swap" 1 "$rc"
mkdir -p "$T/rootbad"
enc --root "$T/rootbad" --root-device "$LM" install
check "refus : racine pas en LUKS2" 1 "$rc"
has "refus : pas LUKS2, raison" "n'est pas un volume LUKS2" "$out"

enc --root "$ROOT" --tpm2-device "$TPMDEV" verify
check "verify (code)" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out"
for role in "slot A" "slot B" "swap"; do
	has "verify $role : LUKS2" "\[ OK \] +$role \(/dev/loop[0-9]+\) : LUKS2" "$out"
	has "verify $role : chiffrement" "\[ OK \] +$role : aes-xts-plain64" "$out"
	has "verify $role : argon2id" "\[ OK \] +$role : clé 512 bits, passphrase en argon2id, sha512" "$out"
	has "verify $role : passphrase de secours" "\[ OK \] +$role : passphrase de secours présente" "$out"
	has "verify $role : TPM PCR 0+7" "\[ OK \] +$role : TPM enrôlé \(PCR 0\+7\)" "$out"
done
has "verify : PCR identiques" '\[ OK \] +PCR 0\+7 identiques à l.enrôlement' "$out"

# =====================================================================================
# 5. Secure Boot change (PCR 7) : repéré, puis reseal
# =====================================================================================
pol_a=$(tok_json "$LA" tpm2-policy-hash)
measure 7 "Secure Boot : on, db Rago"
enc --root "$ROOT" --tpm2-device "$TPMDEV" verify
check "PCR 7 changé : verify (code)" 1 "$rc"
has "PCR 7 changé : repéré" 'ÉCHEC.*PCR 7 changés depuis l.enrôlement.*reseal' "$out"
for v in "$LA" "$LB" "$LS"; do
	enc --root "$ROOT" --device "$v" --tpm2-device "$TPMDEV" --passphrase-file "$PASS" reseal
	check "reseal $v (code)" 0 "$rc"
	check "reseal $v : passphrase + 1 TPM" "password tpm2" "$(types "$v")"
	check "reseal $v : passphrase toujours l'emplacement 0" "0:password" "$(slots "$v" | cut -d' ' -f1)"
done
pol_a2=$(tok_json "$LA" tpm2-policy-hash)
check "reseal : nouvelle politique (PCR 7 actuels)" "différente" "$([ -n "$pol_a" ] && [ "$pol_a" != "$pol_a2" ] && echo différente || echo "identique ($pol_a)")"
enc --root "$ROOT" --tpm2-device "$TPMDEV" verify
check "après reseal : verify (code)" 0 "$rc"
has "après reseal : PCR identiques" '\[ OK \] +PCR 0\+7 identiques' "$out"
check "après reseal : passphrase toujours bonne" 0 "$(printf 'cheval-agrafe-batterie-42\n' | cryptsetup open --test-passphrase --disable-external-tokens --batch-mode "$LS" >/dev/null 2>&1; echo $?)"
# Mise à jour du firmware (PCR 0) : même chose.
measure 0 "firmware OVMF v2"
enc --root "$ROOT" --tpm2-device "$TPMDEV" verify
has "PCR 0 changé : repéré" 'ÉCHEC.*PCR 0 changés' "$out"

# tpm-check (service au démarrage) : écrit l'état pour l'interface.
enc --root "$ROOT" tpm-check
check "tpm-check sans TPM du noyau : code 4 (pas testable)" 4 "$rc"
check "tpm-check : état écrit" "a=untestable b=untestable swap=untestable" "$(grep -v '^#' "$ROOT/run/rago/encryption-status" | tr '\n' ' ' | sed 's/ $//')"

printf 'test_encryption_loop : %d OK, %d échec(s)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
