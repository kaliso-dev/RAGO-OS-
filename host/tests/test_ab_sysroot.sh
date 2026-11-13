#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests de host/manage_atomic_updates.sh (module M4) dans de FAUSSES
# racines : sans disque, sans TPM, sans redémarrage. Les variables EFI sont des
# fichiers (faux efivarfs), bootctl et l'outil de chiffrement M3 sont des
# doublures qui notent leurs appels ; les UKI sont de vraies UKI construites
# par ukify et signées par une clé MOK de test (si ukify et sbsign sont là).
#
# Vérifie : install-files (outils, services, générateur, crochet d'hibernation,
# module dracut, service activé), le générateur du chien de garde (armé
# seulement pendant l'essai), le crochet d'hibernation, confirm (essai réussi,
# entrée .next promue, entrée de M0 et noyau nu retirés, échec détecté, autre
# slot confirmé, confirmation à la main), switch, rollback, status, verify
# (signature MOK, noyau embarqué non signé, UKI modifiée refusée, entrées
# étrangères, défaut), check, setup --root, refus ; et M0 en mode A/B.
#
# Usage : host/tests/test_ab_sysroot.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
H=$(cd "$here/.." && pwd)
M="$H/manage_atomic_updates.sh"
GEN="$H/systemd/system-generators/rago-update-generator"
K="$H/../kernel/build_rago_kernel.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
skipped=0
check() { # check <nom> <attendu> <obtenu>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  attendu : %s\n  obtenu  : %s\n' "$1" "$2" "$3"
	fi
}
has() { # has <nom> <motif grep -E> <texte>
	if grep -Eq -- "$2" <<<"$3"; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  motif absent : %s\n' "$1" "$2"
		printf '%s\n' "$3" | tail -20 | sed 's/^/    | /'
	fi
}
hasnt() { # hasnt <nom> <motif grep -E> <texte>
	if grep -Eq -- "$2" <<<"$3"; then
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  motif présent : %s\n' "$1" "$2"
		printf '%s\n' "$3" | grep -E -- "$2" | head -5 | sed 's/^/    | /'
	else
		pass=$((pass + 1))
	fi
}
skip() { skipped=$((skipped + 1)); printf 'IGNORÉ %s\n' "$*"; }
yes_no() { if "$@"; then echo oui; else echo non; fi; }

# --- doublures : bootctl, outil M3, variables EFI ------------------------------------------------
GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
mkdir -p "$T/bin"
efiw() { # efiw <dossier efivars> <nom> <texte> : variable systemd-boot (UTF-16LE)
	mkdir -p "$1"
	python3 -c 'import sys; open(sys.argv[1], "wb").write(b"\x07\0\0\0" + sys.argv[2].encode("utf-16-le") + b"\0\0")' "$1/$2-$GUID" "$3"
}
cat > "$T/bin/bootctl" <<'EOF'
#!/usr/bin/env bash
# Doublure de bootctl : note l'appel, écrit la variable EFI comme le vrai.
echo "$*" >> "$RAGO_TEST_BOOTCTL_LOG"
args=()
for a in "$@"; do case "$a" in --esp-path=*) ;; *) args+=("$a") ;; esac; done
v="$RAGO_SYSFS/firmware/efi/efivars"
w() { mkdir -p "$v"; if [ -z "$2" ]; then rm -f "$v/$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"; else python3 -c 'import sys; open(sys.argv[1], "wb").write(b"\x07\0\0\0" + sys.argv[2].encode("utf-16-le") + b"\0\0")' "$v/$1-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f" "$2"; fi; }
case "${args[0]:-}" in
set-oneshot) w LoaderEntryOneShot "${args[1]:-}" ;;
set-default) w LoaderEntryDefault "${args[1]:-}" ;;
*) exit 1 ;;
esac
EOF
cat > "$T/bin/m3stub" <<'EOF'
#!/usr/bin/env bash
# Doublure de setup_secure_encryption.sh : note l'appel.
echo "$*" >> "$RAGO_TEST_M3_LOG"
exit "$(cat "$RAGO_TEST_M3_RC" 2>/dev/null || echo 0)"
EOF
chmod 755 "$T/bin/bootctl" "$T/bin/m3stub"
export PATH="$T/bin:$PATH"
export RAGO_TEST_BOOTCTL_LOG="$T/bootctl.log" RAGO_TEST_M3_LOG="$T/m3.log" RAGO_TEST_M3_RC="$T/m3.rc"
export RAGO_M3_TOOL="$T/bin/m3stub"
export RAGO_SYSFS="$T/sys"
EFI="$T/sys/firmware/efi/efivars"
efir() { python3 -c 'import sys
try: d = open(sys.argv[1], "rb").read()[4:]
except OSError: d = b""
print(d.decode("utf-16-le").split("\0")[0])' "$EFI/$1-$GUID"; }

# --- fausse racine ----------------------------------------------------------------------------------
UA=11111111-2222-3333-4444-555555555555
UB=66666666-7777-8888-9999-000000000000
US=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
new_root() { # new_root <dossier> <dracut|mkinitcpio> [slot]
	local r=$1
	rm -rf "$r"
	mkdir -p "$r/etc/rago" "$r/usr/bin" "$r/boot/loader/entries" "$r/boot/EFI/Linux"
	cat > "$r/etc/rago/encryption.conf" <<-EOF
	# Rago OS — chiffrement (module M3). Marqueur : rago-secure-encryption
	RAGO_ENC_SLOT="${3:-a}"
	RAGO_ENC_ROOT_A_UUID="$UA"
	RAGO_ENC_ROOT_B_UUID="$UB"
	RAGO_ENC_SWAP_UUID="$US"
	EOF
	cat > "$r/etc/rago/kernel.conf" <<-'EOF'
	RAGO_CMDLINE="root=/dev/mapper/rago-root resume=/dev/mapper/rago-swap rw"
	RAGO_MITIGATIONS=auto
	RAGO_CMDLINE_EXTRA="console=ttyS0,115200"
	RAGO_ESP=/boot
	EOF
	printf 'timeout 3\n' > "$r/boot/loader/loader.conf"
	if [ "$2" = dracut ]; then
		printf '#!/bin/sh\nexit 0\n' > "$r/usr/bin/dracut"
		chmod 755 "$r/usr/bin/dracut"
		mkdir -p "$r/usr/lib/dracut/modules.d/11systemd-pcrextend"
	else
		printf '#!/bin/sh\nexit 0\n' > "$r/usr/bin/mkinitcpio"
		chmod 755 "$r/usr/bin/mkinitcpio"
		printf 'HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)\n' > "$r/etc/mkinitcpio.conf"
	fi
}
reset_calls() { : > "$T/bootctl.log"; : > "$T/m3.log"; rm -f "$T/m3.rc"; rm -rf "$EFI"; mkdir -p "$EFI"; }
run_m() { # run_m <arguments…> : sortie dans OUT (sans couleurs), code dans RC
	OUT=$(bash "$M" "$@" < /dev/null 2>&1)
	RC=$?
	OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
}

# --- 1. install-files ----------------------------------------------------------------------------------
R1="$T/r1"
new_root "$R1" dracut
reset_calls
run_m --root "$R1" install-files
check "install-files : code" 0 "$RC"
for f in usr/bin/rago-update usr/lib/rago/manage_atomic_updates.sh usr/lib/rago/rago_uki_lib.sh usr/lib/rago/rago_crypt_lib.sh \
	usr/lib/rago/rago_host_lib.sh usr/lib/systemd/system/rago-update-confirm.service usr/lib/systemd/system/rago-update-trial-failed.service \
	usr/lib/systemd/system-generators/rago-update-generator usr/lib/systemd/system-sleep/rago-update etc/rago/update.conf etc/dracut.conf.d/91-rago-uki.conf; do
	check "install-files : $f" oui "$(yes_no test -f "$R1/$f")"
done
check "install-files : rago-update exécutable" 755 "$(stat -c %a "$R1/usr/bin/rago-update")"
check "install-files : générateur exécutable" 755 "$(stat -c %a "$R1/usr/lib/systemd/system-generators/rago-update-generator")"
check "install-files : crochet d'hibernation exécutable" 755 "$(stat -c %a "$R1/usr/lib/systemd/system-sleep/rago-update")"
has "install-files : rago-update lance l'outil installé" '^exec /usr/lib/rago/manage_atomic_updates.sh "\$@"$' "$(cat "$R1/usr/bin/rago-update")"
check "install-files : confirm activé (multi-user.target.wants)" /usr/lib/systemd/system/rago-update-confirm.service \
	"$(readlink "$R1/etc/systemd/system/multi-user.target.wants/rago-update-confirm.service")"
has "install-files : module dracut systemd-pcrextend (barrière PCR 11)" '^add_dracutmodules\+=" systemd-pcrextend "$' "$(cat "$R1/etc/dracut.conf.d/91-rago-uki.conf")"
uc=$(cat "$R1/etc/rago/update.conf")
has "update.conf : marqueur" 'rago-atomic-updates' "$uc"
has "update.conf : mode uki" '^RAGO_AB_MODE="uki"$' "$uc"
has "update.conf : PCR 11" '^RAGO_AB_PCR11="1"$' "$uc"
has "update.conf : délai de l'essai 900 s" '^RAGO_AB_TRIAL_TIMEOUT="900"$' "$uc"
has "update.conf : pas de shell dans l'initramfs" '^RAGO_AB_CMDLINE_EXTRA="rd.shell=0 rd.emergency=reboot"$' "$uc"
if cmp -s "$M" "$R1/usr/lib/rago/manage_atomic_updates.sh"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ÉCHEC install-files : copie du script"; fi
sum1=$(find "$R1" -type f -newer "$R1/etc/rago/kernel.conf" -exec md5sum {} + | sort)
run_m --root "$R1" install-files
check "install-files : idempotent (code)" 0 "$RC"
check "install-files : idempotent (contenu)" "$sum1" "$(find "$R1" -type f -newer "$R1/etc/rago/kernel.conf" -exec md5sum {} + | sort)"
check "install-files : aucun appel bootctl" "" "$(cat "$T/bootctl.log")"
# Réglage existant gardé.
sed -i 's/^RAGO_AB_TRIAL_TIMEOUT=.*/RAGO_AB_TRIAL_TIMEOUT="300"/' "$R1/etc/rago/update.conf"
run_m --root "$R1" install-files
has "install-files : réglage du joueur gardé" '^RAGO_AB_TRIAL_TIMEOUT="300"$' "$(cat "$R1/etc/rago/update.conf")"

R2="$T/r2"
new_root "$R2" mkinitcpio
run_m --root "$R2" install-files
check "install-files mkinitcpio : code" 0 "$RC"
check "install-files mkinitcpio : pas de réglage dracut" non "$(yes_no test -e "$R2/etc/dracut.conf.d/91-rago-uki.conf")"
R3="$T/r3"
new_root "$R3" dracut
rm -rf "$R3/usr/lib/dracut/modules.d"
run_m --root "$R3" install-files
check "install-files dracut sans systemd-pcrextend : code" 0 "$RC"
has "install-files dracut sans systemd-pcrextend : signalé" 'module dracut systemd-pcrextend absent' "$OUT"
check "install-files dracut sans systemd-pcrextend : pas de réglage" non "$(yes_no test -e "$R3/etc/dracut.conf.d/91-rago-uki.conf")"

# --- 2. générateur (chien de garde de l'essai) -------------------------------------------------------
gen() { # gen <sélection EFI ou ""> <essai dans l'état ou ""> [délai] -> dossier de sortie
	local o="$T/gen.$RANDOM" v="$T/genefi" c="$T/gen-update.conf" st="$T/gen-state"
	rm -rf "$v" && mkdir -p "$v" "$o"
	[ -n "$1" ] && efiw "$v" LoaderEntrySelected "$1"
	printf '# marqueur rago-atomic-updates\nRAGO_AB_MODE="uki"\n%s\n' "${3:+RAGO_AB_TRIAL_TIMEOUT=\"$3\"}" > "$c"
	if [ -n "$2" ]; then printf 'RAGO_UPD_TRIAL="%s"\n' "$2" > "$st"; else : > "$st"; fi
	RAGO_EFIVARS="$v" RAGO_UPDATE_CONF="$c" RAGO_UPDATE_STATE="$st" sh "$GEN" "$o" "$o" "$o"
	echo "$o"
}
o=$(gen rago-b.efi rago-b.efi)
check "générateur : essai en cours -> délai sur multi-user.target" "JobTimeoutSec=900|JobTimeoutAction=reboot-force" \
	"$(grep -E '^Job' "$o/multi-user.target.d/50-rago-update-trial.conf" | tr '\n' '|' | sed 's/|$//')"
check "générateur : mode de secours -> rago-update-trial-failed (emergency)" /usr/lib/systemd/system/rago-update-trial-failed.service \
	"$(readlink "$o/emergency.target.wants/rago-update-trial-failed.service")"
check "générateur : mode de secours -> rago-update-trial-failed (rescue)" /usr/lib/systemd/system/rago-update-trial-failed.service \
	"$(readlink "$o/rescue.target.wants/rago-update-trial-failed.service")"
o=$(gen rago-a.next.efi rago-a.next.efi 300)
has "générateur : délai réglé (300 s)" '^JobTimeoutSec=300$' "$(cat "$o/multi-user.target.d/50-rago-update-trial.conf")"
o=$(gen rago-a.efi rago-a.efi 'abc')
has "générateur : délai invalide -> 900 s" '^JobTimeoutSec=900$' "$(cat "$o/multi-user.target.d/50-rago-update-trial.conf")"
o=$(gen rago-a.efi rago-b.efi)
check "générateur : autre entrée démarrée (retour arrière) -> rien" "" "$(find "$o" -mindepth 1 | head -1)"
o=$(gen rago-a.efi "")
check "générateur : pas d'essai -> rien" "" "$(find "$o" -mindepth 1 | head -1)"
o=$(gen "" rago-a.efi)
check "générateur : pas de systemd-boot (variable absente) -> rien" "" "$(find "$o" -mindepth 1 | head -1)"
o="$T/gen.noconf" && mkdir -p "$o"
RAGO_UPDATE_CONF="$T/absent.conf" sh "$GEN" "$o" "$o" "$o"
check "générateur : M4 pas installé -> rien" "" "$(find "$o" -mindepth 1 | head -1)"

# --- 2b. fichiers d'unités : un réglage hors de sa section est ignoré par systemd ----------------
# (SuccessAction= sous [Service] : la VM de M4 restait en mode de secours.)
key_sections() { # key_sections <fichier> <clé> -> sections où la clé apparaît
	awk -v k="$2" '/^[[:space:]]*\[.*\][[:space:]]*$/ { s = $0; gsub(/[[:space:]]/, "", s); next }
		$0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print s }' "$1" | sort -u | tr '\n' ' ' | sed 's/ $//'
}
TF="$H/systemd/rago-update-trial-failed.service"
check "trial-failed : SuccessAction= dans [Unit]" "[Unit]" "$(key_sections "$TF" SuccessAction)"
check "trial-failed : FailureAction= dans [Unit]" "[Unit]" "$(key_sections "$TF" FailureAction)"
check "trial-failed : redémarrage forcé (succès, échec)" "reboot-force reboot-force" \
	"$(sed -n 's/^\(Success\|Failure\)Action=//p' "$TF" | tr '\n' ' ' | sed 's/ $//')"
check "trial-failed : délai du script (TimeoutStartSec=, dans [Service])" "[Service]" "$(key_sections "$TF" TimeoutStartSec)"
o=$(gen rago-b.efi rago-b.efi)
check "générateur : JobTimeoutAction= dans [Unit]" "[Unit]" "$(key_sections "$o/multi-user.target.d/50-rago-update-trial.conf" JobTimeoutAction)"
bad=""
while IFS= read -r u; do
	for k in SuccessAction FailureAction JobTimeoutAction JobTimeoutSec JobRunningTimeoutSec StartLimitAction \
		StartLimitIntervalSec StartLimitBurst OnFailure OnSuccess DefaultDependencies; do
		s=$(key_sections "$u" "$k")
		[ -z "$s" ] || [ "$s" = "[Unit]" ] || bad="$bad ${u#"$H/"}:$k=$s"
	done
done < <(find "$H/systemd" -type f \( -name '*.service' -o -name '*.timer' -o -name '*.target' \) | sort)
check "unités de host/systemd : réglages d'unité tous dans [Unit]" "" "$bad"
if command -v systemd-analyze > /dev/null 2>&1; then
	# Les exécutables (/usr/lib/rago/…) ne sont pas installés ici : seul le texte est jugé.
	va=$(find "$H/systemd" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) -print0 | sort -z |
		SYSTEMD_LOG_LEVEL=warning xargs -0 systemd-analyze verify --man=no 2>&1 |
		grep -E 'Unknown (key|section|lvalue)|Invalid|Failed to parse|Missing .=|assignment outside of section' || true)
	check "systemd-analyze verify : unités de host/systemd sans réglage inconnu" "" "$va"
else
	skip "systemd-analyze absent : vérification des unités par systemd"
fi

# --- 3. UKI de test (vraies UKI : ukify + sbsign) -------------------------------------------------
STUB=""
for s in /usr/lib/systemd/boot/efi/linuxx64.efi.stub /lib/systemd/boot/efi/linuxx64.efi.stub; do [ -f "$s" ] && STUB=$s && break; done
UKI_OK=0
mk_keys() { # mk_keys <dossier> : clé MOK de test (comme build_rago_kernel.sh mok-gen)
	mkdir -p "$1"
	openssl req -new -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=Rago test MOK/" \
		-keyout "$1/MOK.key" -out "$1/MOK.crt" > /dev/null 2>&1
}
mk_uki() { # mk_uki <sortie> <slot> [cmdline] [noyau]
	local out=$1 slot=$2 cl=${3:-root=/dev/mapper/rago-root resume=/dev/mapper/rago-swap rw console=ttyS0,115200 rd.shell=0 rd.emergency=reboot}
	local lin=${4:-$T/linux}
	printf 'slot=%s\nkernel=7.0.0-test\nversion=test-%s\nsource=test\nbuilt=2026-11-13T00:00:00Z\npcr11-phases=enter-initrd\n' "$slot" "$slot" > "$T/meta"
	printf 'NAME="Rago OS"\nID=rago\nPRETTY_NAME="Rago OS — slot %s"\n' "$slot" > "$T/osrel"
	ukify build --linux="$lin" --initrd="$T/initrd" --cmdline="$cl" --os-release=@"$T/osrel" --uname=7.0.0-test \
		--section=.rago:@"$T/meta" --stub="$STUB" --signtool=sbsign --no-sign-kernel \
		--secureboot-private-key="$KEYS/MOK.key" --secureboot-certificate="$KEYS/MOK.crt" --output="$out" > "$T/ukify.log" 2>&1
}
KEYS="$T/keys"
if command -v ukify >/dev/null && command -v sbsign >/dev/null && command -v sbverify >/dev/null && [ -n "$STUB" ] && mk_keys "$KEYS"; then
	head -c 300000 /dev/urandom > "$T/linux"
	head -c 200000 /dev/urandom > "$T/initrd"
	if mk_uki "$T/uki-a.efi" a && mk_uki "$T/uki-b.efi" b; then UKI_OK=1; else skip "ukify build a échoué : $(tail -1 "$T/ukify.log")"; fi
else
	skip "ukify / sbsign / sbverify / systemd-stub / openssl absents : UKI réelles non testées"
	printf 'pas une UKI\n' > "$T/uki-a.efi"
	cp "$T/uki-a.efi" "$T/uki-b.efi"
fi

# Machine A/B complète (slot en marche A) dans une fausse racine.
new_ab() { # new_ab <dossier>
	new_root "$1" dracut a
	bash "$M" --root "$1" install-files > /dev/null 2>&1
	sed -i 's/^RAGO_AB_TRIAL_TIMEOUT=.*/RAGO_AB_TRIAL_TIMEOUT="300"/' "$1/etc/rago/update.conf"
	mkdir -p "$1/etc/rago/secureboot"
	cp "$KEYS"/MOK.* "$1/etc/rago/secureboot/" 2>/dev/null || true
	printf 'editor no\ndefault rago-a.efi\n' > "$1/boot/loader/loader.conf"
}
state() { grep -E "^$2=" "$1/var/lib/rago/update/state" 2>/dev/null | tail -1 | sed 's/^[^=]*="\(.*\)"$/\1/'; }

# --- 4. confirm -------------------------------------------------------------------------------------
# 4a. Essai réussi d'une UKI reconstruite (.next) du slot en marche.
RA="$T/ra"
new_ab "$RA"
reset_calls
cp "$T/uki-a.efi" "$RA/boot/EFI/Linux/rago-a.efi"
printf 'nouvelle\n' >> "$RA/boot/EFI/Linux/rago-a.next.efi"
mkdir -p "$RA/var/lib/rago/update"
printf 'RAGO_UPD_TRIAL="rago-a.next.efi"\nRAGO_UPD_PENDING="rago-a.next.efi"\nRAGO_UPD_PENDING_FROM="rago-a.efi"\n' > "$RA/var/lib/rago/update/state"
efiw "$EFI" LoaderEntrySelected rago-a.next.efi
efiw "$EFI" LoaderEntryDefault rago-a.efi
run_m --root "$RA" confirm --auto
check "confirm (.next réussie) : code" 0 "$RC"
check "confirm (.next réussie) : rago-a.next.efi devient rago-a.efi" "nouvelle|absent" \
	"$(cat "$RA/boot/EFI/Linux/rago-a.efi")|$([ -e "$RA/boot/EFI/Linux/rago-a.next.efi" ] && echo présent || echo absent)"
check "confirm (.next réussie) : défaut EFI" rago-a.efi "$(efir LoaderEntryDefault)"
has "confirm (.next réussie) : bootctl set-default" 'set-default rago-a.efi' "$(cat "$T/bootctl.log")"
has "confirm (.next réussie) : loader.conf default" '^default rago-a.efi$' "$(cat "$RA/boot/loader/loader.conf")"
check "confirm (.next réussie) : entrée démarrée notée sous son nom définitif" rago-a.efi "$(cat "$RA/run/rago/update/booted-entry" 2>/dev/null)"
check "confirm (.next réussie) : plus d'essai en cours" "|" "$(state "$RA" RAGO_UPD_TRIAL)|$(state "$RA" RAGO_UPD_PENDING)"
has "confirm (.next réussie) : dernier résultat" 'essai réussi : rago-a.efi est le défaut' "$(state "$RA" RAGO_UPD_LAST)"
has "confirm (.next réussie) : historique" 'confirm : rago-a.efi par défaut' "$(cat "$RA/var/lib/rago/update/history.log")"
has "confirm (.next réussie) : jetons TPM des anciennes entrées retirés (M3 prune-tpm)" '--root .* --quiet prune-tpm' "$(cat "$T/m3.log")"
hasnt "confirm (.next réussie) : jamais de reseal (pas de passphrase ici)" 'reseal' "$(cat "$T/m3.log")"

# 4b. Mise en place réussie : l'entrée de M0 et son noyau nu signé sont retirés.
reset_calls
cp "$T/uki-a.efi" "$RA/boot/EFI/Linux/rago-a.efi"
printf 'title Rago OS\nlinux /vmlinuz-linux-rago\ninitrd /initramfs-linux-rago.img\noptions root=/dev/mapper/rago-root\n' > "$RA/boot/loader/entries/rago.conf"
printf 'noyau' > "$RA/boot/vmlinuz-linux-rago"
printf 'initramfs' > "$RA/boot/initramfs-linux-rago.img"
printf 'autre' > "$RA/boot/vmlinuz-autre"
printf 'RAGO_UPD_TRIAL="rago-a.efi"\nRAGO_UPD_PENDING="rago-a.efi"\nRAGO_UPD_PENDING_FROM="rago.conf"\n' > "$RA/var/lib/rago/update/state"
efiw "$EFI" LoaderEntrySelected rago-a.efi
efiw "$EFI" LoaderEntryDefault rago.conf
run_m --root "$RA" confirm --auto
check "confirm (mise en place) : code" 0 "$RC"
check "confirm (mise en place) : rago.conf, noyau nu et initramfs de M0 retirés" "non non non" \
	"$(yes_no test -e "$RA/boot/loader/entries/rago.conf") $(yes_no test -e "$RA/boot/vmlinuz-linux-rago") $(yes_no test -e "$RA/boot/initramfs-linux-rago.img")"
check "confirm (mise en place) : un autre fichier de l'ESP n'est pas touché" oui "$(yes_no test -e "$RA/boot/vmlinuz-autre")"
check "confirm (mise en place) : défaut = UKI du slot" rago-a.efi "$(efir LoaderEntryDefault)"

# 4c. Essai de l'autre slot raté : retour automatique constaté.
reset_calls
cp "$T/uki-b.efi" "$RA/boot/EFI/Linux/rago-b.efi"
printf 'RAGO_UPD_PENDING="rago-b.efi"\nRAGO_UPD_PENDING_FROM="rago-a.efi"\n' > "$RA/var/lib/rago/update/state"
rm -f "$RA/run/rago/update/booted-entry"
efiw "$EFI" LoaderEntrySelected rago-a.efi
efiw "$EFI" LoaderEntryDefault rago-a.efi
run_m --root "$RA" confirm --auto
check "confirm (essai de B raté) : code" 0 "$RC"
has "confirm (essai de B raté) : échec noté" "ÉCHEC de l'essai de rago-b.efi : retour sur rago-a.efi" "$(state "$RA" RAGO_UPD_LAST)"
check "confirm (essai de B raté) : plus en attente" "" "$(state "$RA" RAGO_UPD_PENDING)"
check "confirm (essai de B raté) : l'UKI de B reste (nouvel essai possible)" oui "$(yes_no test -f "$RA/boot/EFI/Linux/rago-b.efi")"
check "confirm (essai de B raté) : défaut inchangé, aucun bootctl" "rago-a.efi|" "$(efir LoaderEntryDefault)|$(cat "$T/bootctl.log")"
has "confirm (essai de B raté) : historique" "échec de l'essai de rago-b.efi" "$(cat "$RA/var/lib/rago/update/history.log")"

# 4d. Essai de B réussi puis retour sur A (choisi au menu) : B a été confirmé.
reset_calls
printf 'RAGO_UPD_PENDING="rago-b.efi"\nRAGO_UPD_PENDING_FROM="rago-a.efi"\n' > "$RA/var/lib/rago/update/state"
efiw "$EFI" LoaderEntrySelected rago-a.efi
efiw "$EFI" LoaderEntryDefault rago-b.efi
run_m --root "$RA" confirm --auto
has "confirm (B confirmé de l'autre côté) : noté" 'le slot de rago-b.efi a été confirmé' "$(state "$RA" RAGO_UPD_LAST)"
check "confirm (B confirmé de l'autre côté) : défaut gardé (B)" rago-b.efi "$(efir LoaderEntryDefault)"

# 4e. UKI reconstruite qui ne démarre pas : retirée avec ses jetons.
reset_calls
printf 'x' > "$RA/boot/EFI/Linux/rago-a.next.efi"
printf 'RAGO_UPD_TRIAL="rago-a.next.efi"\nRAGO_UPD_PENDING="rago-a.next.efi"\nRAGO_UPD_PENDING_FROM="rago-a.efi"\n' > "$RA/var/lib/rago/update/state"
efiw "$EFI" LoaderEntrySelected rago-a.efi
efiw "$EFI" LoaderEntryDefault rago-a.efi
run_m --root "$RA" confirm --auto
check "confirm (.next ratée) : rago-a.next.efi retirée" non "$(yes_no test -e "$RA/boot/EFI/Linux/rago-a.next.efi")"
check "confirm (.next ratée) : rago-a.efi gardée" oui "$(yes_no test -e "$RA/boot/EFI/Linux/rago-a.efi")"
check "confirm (.next ratée) : plus d'essai" "|" "$(state "$RA" RAGO_UPD_TRIAL)|$(state "$RA" RAGO_UPD_PENDING)"
has "confirm (.next ratée) : jetons de l'UKI retirée (prune-tpm)" 'prune-tpm' "$(cat "$T/m3.log")"

# 4f. Rien en cours : --auto ne touche à rien.
reset_calls
printf 'RAGO_UPD_LAST="x"\n' > "$RA/var/lib/rago/update/state"
efiw "$EFI" LoaderEntrySelected rago-a.efi
efiw "$EFI" LoaderEntryDefault rago-a.efi
run_m --root "$RA" confirm --auto
check "confirm --auto sans essai : code" 0 "$RC"
check "confirm --auto sans essai : aucun appel" "|" "$(cat "$T/bootctl.log")|$(cat "$T/m3.log")"

# 4g. Confirmation à la main : le démarrage en cours (B, par switch) devient le défaut.
reset_calls
efiw "$EFI" LoaderEntrySelected rago-b.efi
efiw "$EFI" LoaderEntryDefault rago-a.efi
run_m --root "$RA" confirm
check "confirm à la main : code" 0 "$RC"
check "confirm à la main : défaut = entrée démarrée" rago-b.efi "$(efir LoaderEntryDefault)"
efiw "$EFI" LoaderEntrySelected autre.conf
run_m --root "$RA" confirm
check "confirm à la main d'une entrée étrangère : refusé" 1 "$RC"
has "confirm à la main d'une entrée étrangère : raison" "n'est pas une entrée Rago" "$OUT"

# 4h. Sans M4 : --auto (service) ne fait rien, sans erreur.
R0="$T/r0"
new_root "$R0" dracut
run_m --root "$R0" confirm --auto
check "confirm --auto sans M4 : code 0" 0 "$RC"

# --- 5. switch, rollback -------------------------------------------------------------------------
reset_calls
efiw "$EFI" LoaderEntryDefault rago-a.efi
run_m --root "$RA" switch
check "switch : code" 0 "$RC"
check "switch : démarrage unique de B" rago-b.efi "$(efir LoaderEntryOneShot)"
check "switch : défaut inchangé" rago-a.efi "$(efir LoaderEntryDefault)"
has "switch : jetons TPM mis à jour (M3 reseal, sans passphrase donnée)" '^--root [^ ]+ reseal$' "$(cat "$T/m3.log")"
reset_calls
echo 1 > "$T/m3.rc"
efiw "$EFI" LoaderEntryDefault rago-a.efi
efiw "$EFI" LoaderEntryOneShot rago-b.efi
run_m --root "$RA" rollback
check "rollback : code (même si le re-scellement échoue)" 0 "$RC"
has "rollback : re-scellement raté expliqué, passphrase au démarrage" 'passphrase de secours sera demandée' "$OUT"
check "rollback : B devient le défaut, essai annulé" "rago-b.efi|" "$(efir LoaderEntryDefault)|$(efir LoaderEntryOneShot)"
has "rollback : loader.conf" '^default rago-b.efi$' "$(cat "$RA/boot/loader/loader.conf")"
reset_calls
rm -f "$RA/boot/EFI/Linux/rago-b.efi"
run_m --root "$RA" switch
check "switch sans entrée pour l'autre slot : refusé" 1 "$RC"
has "switch sans entrée : raison" "n'a pas d'entrée de démarrage" "$OUT"
check "switch sans entrée : aucun bootctl" "" "$(cat "$T/bootctl.log")"

# --- 6. crochet d'hibernation -------------------------------------------------------------------
reset_calls
efiw "$EFI" LoaderEntrySelected rago-b.efi
efiw "$EFI" LoaderEntryDefault rago-a.efi
cp "$T/uki-b.efi" "$RA/boot/EFI/Linux/rago-b.efi"
rm -f "$RA/run/rago/update/booted-entry"
run_m --root "$RA" sleep-hook pre hibernate
check "hibernation hors défaut : reprise sur la même entrée" rago-b.efi "$(efir LoaderEntryOneShot)"
check "hibernation hors défaut : noté pour l'après" rago-b.efi "$(cat "$RA/run/rago/update/sleep-oneshot" 2>/dev/null)"
run_m --root "$RA" sleep-hook post hibernate
check "après la reprise : entrée unique retirée" "" "$(efir LoaderEntryOneShot)"
check "après la reprise : note retirée" non "$(yes_no test -e "$RA/run/rago/update/sleep-oneshot")"
reset_calls
efiw "$EFI" LoaderEntrySelected rago-b.efi
efiw "$EFI" LoaderEntryDefault rago-a.efi
efiw "$EFI" LoaderEntryOneShot windows.conf
run_m --root "$RA" sleep-hook pre hibernate
check "hibernation avec une entrée unique déjà choisie (M6 : Windows) : pas touchée" "windows.conf|" "$(efir LoaderEntryOneShot)|$(cat "$T/bootctl.log")"
reset_calls
efiw "$EFI" LoaderEntrySelected rago-a.efi
efiw "$EFI" LoaderEntryDefault rago-a.efi
run_m --root "$RA" sleep-hook pre hibernate
check "hibernation sur le défaut : rien" "" "$(cat "$T/bootctl.log")"
efiw "$EFI" LoaderEntrySelected rago-b.efi
run_m --root "$RA" sleep-hook pre suspend
check "mise en veille simple : rien" "" "$(cat "$T/bootctl.log")"

# --- 7. status, verify, check ---------------------------------------------------------------------
reset_calls
RV="$T/rv"
new_ab "$RV"
cp "$T/uki-a.efi" "$RV/boot/EFI/Linux/rago-a.efi"
cp "$T/uki-b.efi" "$RV/boot/EFI/Linux/rago-b.efi"
mkdir -p "$RV/boot/EFI/systemd"
efiw "$EFI" LoaderEntryDefault rago-a.efi
efiw "$EFI" LoaderEntrySelected rago-a.efi
run_m --root "$RV" status
check "status : code" 0 "$RC"
has "status : slot en marche et défaut" 'défaut \(dernier bon connu\) : rago-a.efi' "$OUT"
if [ "$UKI_OK" = 1 ]; then
	has "status : UKI décrite par ses métadonnées signées" 'slot A : rago-a.efi — UKI test-a, noyau 7.0.0-test' "$OUT"
	sbsign --key "$KEYS/MOK.key" --cert "$KEYS/MOK.crt" --output "$RV/boot/EFI/systemd/systemd-bootx64.efi" "$STUB" > /dev/null 2>&1
	run_m --root "$RV" verify
	check "verify : code (tout bon)" 0 "$RC"
	has "verify : UKI A signée MOK" '\[ OK \] +rago-a.efi : signée par la clé MOK' "$OUT"
	has "verify : noyau embarqué non signé" '\[ OK \] +rago-a.efi : noyau embarqué non signé à part' "$OUT"
	has "verify : métadonnée slot" '\[ OK \] +rago-b.efi : slot b' "$OUT"
	has "verify : ligne de commande" '\[ OK \] +rago-a.efi : root=/dev/mapper/rago-root' "$OUT"
	has "verify : pas de shell dans l'initramfs" '\[ OK \] +rago-a.efi : pas de shell dans l.initramfs' "$OUT"
	has "verify : PCR 11 prédit" '\[ OK \] +rago-a.efi : PCR 11 prédit \(enter-initrd\)' "$OUT"
	has "verify : systemd-boot signé" '\[ OK \] +systemd-boot signé par la clé MOK : EFI/systemd/systemd-bootx64.efi' "$OUT"
	has "verify : éditeur coupé" '\[ OK \] +loader.conf : editor no' "$OUT"
	has "verify : défaut" '\[ OK \] +défaut \(dernier bon connu\) : rago-a.efi' "$OUT"
	# UKI modifiée après signature (un octet de la ligne de commande) : refusée.
	python3 - "$RV/boot/EFI/Linux/rago-b.efi" <<-'EOF'
	import sys
	p = sys.argv[1]
	d = bytearray(open(p, "rb").read())
	i = d.find(b"rd.shell=0")
	d[i + 9] = ord("1")
	open(p, "wb").write(bytes(d))
	EOF
	run_m --root "$RV" verify
	check "verify : UKI modifiée -> échec" 1 "$RC"
	has "verify : UKI modifiée -> PAS signée" '\[ ÉCHEC \] +rago-b.efi : PAS signée par la clé MOK' "$OUT"
	cp "$T/uki-b.efi" "$RV/boot/EFI/Linux/rago-b.efi"
	# Noyau embarqué signé par la clé MOK (rejeu de PCR 11 possible) : refusé.
	sbsign --key "$KEYS/MOK.key" --cert "$KEYS/MOK.crt" --output "$T/linux-signed" "$STUB" > /dev/null 2>&1
	mk_uki "$RV/boot/EFI/Linux/rago-b.efi" b "" "$T/linux-signed"
	run_m --root "$RV" verify
	has "verify : noyau embarqué signé MOK -> échec" '\[ ÉCHEC \] +rago-b.efi : noyau embarqué signé par la clé MOK' "$OUT"
	cp "$T/uki-b.efi" "$RV/boot/EFI/Linux/rago-b.efi"
	# Entrée étrangère et noyau nu signé laissés sur l'ESP.
	printf 'title autre\nlinux /vmlinuz\n' > "$RV/boot/loader/entries/autre.conf"
	cp "$T/linux-signed" "$RV/boot/vmlinuz-linux-rago"
	run_m --root "$RV" verify
	check "verify : noyau nu signé sur l'ESP -> échec" 1 "$RC"
	has "verify : entrée étrangère signalée" 'ATTENTION.*entrée étrangère autre.conf' "$OUT"
	has "verify : noyau nu signé signalé" 'ÉCHEC.*noyau nu signé par la clé MOK sur l.ESP' "$OUT"
	rm -f "$RV/boot/loader/entries/autre.conf" "$RV/boot/vmlinuz-linux-rago"
	printf 'default rago-a.efi\n' > "$RV/boot/loader/loader.conf"
	run_m --root "$RV" verify
	has "verify : éditeur de systemd-boot actif -> échec" '\[ ÉCHEC \] +loader.conf : éditeur de systemd-boot actif' "$OUT"
else
	skip "verify sur de vraies UKI (ukify absent)"
fi
run_m --root "$RV" check
has "check : volumes M3 lus" '\[ OK \] +slot B : UUID='"$UB" "$OUT"
has "check : ESP" '\[ OK \] +ESP : ' "$OUT"
run_m --root "$R0" status
has "status sans M4" 'M4 pas en place' "$OUT"

# --- 8. setup --root : réglages et fichiers, loader.conf --------------------------------------------
RS="$T/rs"
new_root "$RS" dracut a
mkdir -p "$RS/etc/rago/secureboot"
cp "$KEYS"/MOK.* "$RS/etc/rago/secureboot/" 2>/dev/null || true
printf 'title Rago OS\nlinux /vmlinuz-linux-rago\n' > "$RS/boot/loader/entries/rago.conf"
reset_calls
run_m --root "$RS" setup
check "setup --root : code" 0 "$RC"
has "setup --root : éditeur de systemd-boot coupé" '^editor no$' "$(cat "$RS/boot/loader/loader.conf")"
has "setup --root : l'entrée de M0 reste le défaut (repli)" '^default rago.conf$' "$(cat "$RS/boot/loader/loader.conf")"
has "setup --root : réglage gardé du loader.conf" '^timeout 3$' "$(cat "$RS/boot/loader/loader.conf")"
check "setup --root : update.conf écrit" oui "$(yes_no grep -q rago-atomic-updates "$RS/etc/rago/update.conf")"
has "setup --root : pas d'UKI ni de TPM avec --root" 'pas d.UKI, pas de TPM' "$OUT"
# Défaut = entrée de M0 : repli pendant l'essai de la première UKI, sinon signalé.
mkdir -p "$RS/var/lib/rago/update"
printf 'RAGO_UPD_TRIAL="rago-a.efi"\n' > "$RS/var/lib/rago/update/state"
run_m --root "$RS" verify
has "verify : rago.conf en repli pendant l'essai de la première UKI" '\[ OK \] +défaut : rago\.conf \(entrée de M0\), repli jusqu.à la confirmation de rago-a\.efi' "$OUT"
: > "$RS/var/lib/rago/update/state"
run_m --root "$RS" verify
has "verify : rago.conf par défaut sans essai -> signalé" '\[ ATTENTION \] +défaut : rago\.conf \(entrée de M0, sans UKI' "$OUT"

# --- 9. refus -------------------------------------------------------------------------------------
run_m --root "$RA" apply --clone
check "apply --root : refusé" 1 "$RC"
run_m --root "$RA" uki
check "uki --root : refusé" 1 "$RC"
run_m --root "$RA" status verify
check "deux commandes : refusé" 1 "$RC"
run_m --root "$RA" --bidon status
check "option inconnue : refusée" 1 "$RC"
run_m
check "sans commande : aide, code 2" 2 "$RC"
run_m --help
has "aide" 'Usage : manage_atomic_updates.sh' "$OUT"

# --- 10. M0 en mode A/B (build_rago_kernel.sh) -----------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
	KC="$T/m0-kernel.conf"
	printf 'RAGO_CMDLINE="root=/dev/mapper/rago-root rw"\nRAGO_MITIGATIONS=auto\nRAGO_CMDLINE_EXTRA=""\nRAGO_ESP=%s\n' "$RV/boot" > "$KC"
	k0() { OUT=$(RAGO_KERNEL_CONF="$KC" RAGO_UPDATE_CONF="$RV/etc/rago/update.conf" RAGO_MOK_DIR="$KEYS" bash "$K" "$@" < /dev/null 2>&1); RC=$?; OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g'); }
	k0 install
	check "M0 install sur le slot en marche en mode A/B : refusé" 1 "$RC"
	has "M0 install : commande rago-update apply donnée" 'rago-update apply --clone --bind .* --run ".*/build_rago_kernel.sh install"' "$OUT"
	k0 sign
	check "M0 sign en mode A/B : refusé (noyau nu jamais signé)" 1 "$RC"
	has "M0 sign : raison" 'rejouer la mesure PCR 11' "$OUT"
	rm -f "$RV/boot/loader/entries/rago.conf"
	k0 --dry-run bootloader
	check "M0 bootloader --dry-run en mode A/B : code" 0 "$RC"
	has "M0 bootloader A/B : pas d'entrée rago.conf" "pas d'entrée rago.conf" "$OUT"
	hasnt "M0 bootloader A/B : rago.conf jamais écrit" 'entrée systemd-boot :' "$OUT"
	has "M0 bootloader : systemd-boot signé posé explicitement" "install -m 0644 .*systemd-bootx64.efi.signed $RV/boot/EFI/systemd/systemd-bootx64.efi" "$OUT"
	has "M0 bootloader A/B : UKI du slot reconstruite ensuite" 'rago-update' "$OUT"
	RAGO_UPDATE_TARGET_SLOT=b k0 --dry-run bootloader
	has "M0 bootloader dans le slot en cours d'écriture : rien (rago-update fait l'UKI)" 'slot b en cours d.écriture' "$OUT"
	k0() { OUT=$(RAGO_KERNEL_CONF="$KC" RAGO_UPDATE_CONF="$T/absent.conf" RAGO_MOK_DIR="$KEYS" bash "$K" "$@" < /dev/null 2>&1); RC=$?; OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g'); }
	k0 --dry-run bootloader
	has "M0 bootloader sans M4 : entrée rago.conf comme avant" 'entrée systemd-boot : .*/loader/entries/rago.conf' "$OUT"
else
	skip "M0 en mode A/B : need_root (lancer en root, rien n'est écrit : --dry-run et refus)"
fi

echo "test_ab_sysroot : $pass OK, $fail échec(s), $skipped ignoré(s)"
[ "$fail" -eq 0 ]
