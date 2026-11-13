#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests unitaires de host/lib/rago_crypt_lib.sh (module M3).
# Sans root, sans disque, sans TPM. Usage : host/tests/test_crypt_lib.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
fx="$here/fixtures/m3"
# shellcheck source-path=SCRIPTDIR source=../lib/rago_host_lib.sh
. "$here/../lib/rago_host_lib.sh"
# shellcheck source-path=SCRIPTDIR source=../lib/rago_crypt_lib.sh
. "$here/../lib/rago_crypt_lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

check() { # check <nom> <attendu> <obtenu>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  attendu : %s\n  obtenu  : %s\n' "$1" "$2" "$3"
	fi
}

check_rc() { # check_rc <nom> <code attendu> <commande...>
	local name=$1 want=$2 got
	shift 2
	"$@" >/dev/null 2>&1
	got=$?
	check "$name (code retour)" "$want" "$got"
}

# --- processeur -----------------------------------------------------------------------
cat > "$tmp/cpuinfo" <<'EOF'
processor	: 0
vendor_id	: AuthenticAMD
flags		: fpu vme de pse tsc msr pae sse sse2 pclmulqdq aes avx avx2 vaes vpclmulqdq sha_ni
processor	: 1
flags		: fpu
EOF
flags=$(rago_cpu_flags "$tmp/cpuinfo")
check "drapeaux du 1er CPU" "fpu vme de pse tsc msr pae sse sse2 pclmulqdq aes avx avx2 vaes vpclmulqdq sha_ni" "$flags"
check_rc "aes présent" 0 rago_flag_has "$flags" aes
check_rc "avx2 présent" 0 rago_flag_has "$flags" avx2
check_rc "avx512f absent" 1 rago_flag_has "$flags" avx512f
check_rc "pas de faux positif (av)" 1 rago_flag_has "$flags" av
check_rc "cpuinfo absent" 1 rago_flag_has "$(rago_cpu_flags "$tmp/none")" aes

cat > "$tmp/crypto" <<'EOF'
name         : xts(aes)
driver       : xts(ecb(aes-generic))
module       : kernel
priority     : 100

name         : xts(aes)
driver       : xts-aes-vaes-avx2
module       : aesni_intel
priority     : 600

name         : xts(aes)
driver       : xts-aes-aesni
module       : aesni_intel
priority     : 401

name         : cbc(aes)
driver       : cbc-aes-aesni
priority     : 900
EOF
check "pilote xts(aes) prioritaire" xts-aes-vaes-avx2 "$(rago_xts_driver "$tmp/crypto")"
check_rc "pilote VAES accéléré" 0 rago_xts_driver_accelerated xts-aes-vaes-avx2
check_rc "pilote AES-NI accéléré" 0 rago_xts_driver_accelerated xts-aes-aesni
check_rc "pilote générique lent" 1 rago_xts_driver_accelerated "xts(ecb(aes-generic))"
printf 'name : cbc(aes)\ndriver : x\npriority : 1\n' > "$tmp/crypto2"
check_rc "pas de xts(aes) chargé" 1 rago_xts_driver "$tmp/crypto2"

# --- passphrase -----------------------------------------------------------------------
check_rc "passphrase correcte" 0 rago_passphrase_check "cheval-batterie-agrafe"
check_rc "exactement 12" 0 rago_passphrase_check "abcdefghijkl"
check_rc "11 caractères : trop courte" 1 rago_passphrase_check "abcdefghijk"
check_rc "vide" 1 rago_passphrase_check ""
check_rc "retour à la ligne" 2 rago_passphrase_check "$(printf 'abcdefgh\nijklmnop')"
check_rc "tabulation" 2 rago_passphrase_check "$(printf 'abcdefgh\tijklmnop')"
check_rc "accents : à éviter" 3 rago_passphrase_check "mot-de-passe-évident"
check_rc "espaces acceptés" 0 rago_passphrase_check "trois mots simples ici"
check "retour final retiré" "secret-de-test-1" "$(rago_strip_newline "$(printf 'secret-de-test-1\n')")"
check "CRLF retiré" "secret-de-test-1" "$(rago_strip_newline "$(printf 'secret-de-test-1\r')")"
check "sans retour : identique" "abc" "$(rago_strip_newline abc)"

# --- PCR ------------------------------------------------------------------------------
check "PCR 0+7" "0+7" "$(rago_pcrs_normalize 0+7)"
check "PCR 7,0 -> 0+7" "0+7" "$(rago_pcrs_normalize 7,0)"
check "PCR doublon" "7" "$(rago_pcrs_normalize 7+7)"
check "PCR 0+2+7+11" "0+2+7+11" "$(rago_pcrs_normalize 11+7+2+0)"
check_rc "PCR 24 refusé" 1 rago_pcrs_normalize 24
check_rc "PCR 07 refusé" 1 rago_pcrs_normalize 07
check_rc "PCR vide" 1 rago_pcrs_normalize ""
check_rc "PCR ++" 1 rago_pcrs_normalize "0++7"
check_rc "PCR lettres" 1 rago_pcrs_normalize "0+x"
check_rc "PCR séparateur final" 1 rago_pcrs_normalize "0+"
check "PCR en virgules" "0,7" "$(rago_pcrs_comma 0+7)"
check_rc "PCR que des 0 : non mesuré" 0 rago_pcr_is_unmeasured 0x0000000000000000000000000000000000000000000000000000000000000000
check_rc "PCR que des F : non mesuré" 0 rago_pcr_is_unmeasured FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
check_rc "PCR mesuré" 1 rago_pcr_is_unmeasured 0x0F7F6FE0E3ABF8D0D18D5FB06BFF3158D1317C727A603C1233D6D7FD0E87A007
check_rc "PCR vide = non mesuré" 0 rago_pcr_is_unmeasured ""
cat > "$tmp/pcrread" <<'EOF'
  sha256:
    0 : 0x0F7F6FE0E3ABF8D0D18D5FB06BFF3158D1317C727A603C1233D6D7FD0E87A007
    7 : 0xBD034528111D2AB04869ECFFF89C0D0B1C0FAA9AB048CCE3C99EF97B42B48D34
EOF
check "lecture tpm2_pcrread" "0 0f7f6fe0e3abf8d0d18d5fb06bff3158d1317c727a603c1233d6d7fd0e87a007
7 bd034528111d2ab04869ecfff89c0d0b1c0faa9ab048cce3c99ef97b42b48d34" "$(rago_pcrread_parse < "$tmp/pcrread")"
printf '0 aaa\n7 bbb\n' > "$tmp/pcr-old"
printf '0 aaa\n7 bbb\n' > "$tmp/pcr-same"
printf '0 aaa\n7 ccc\n' > "$tmp/pcr-7"
printf '0 ddd\n7 ccc\n' > "$tmp/pcr-07"
check "PCR inchangés" "" "$(rago_pcr_changed "$tmp/pcr-old" "$tmp/pcr-same")"
check "PCR 7 changé" "7" "$(rago_pcr_changed "$tmp/pcr-old" "$tmp/pcr-7")"
check "PCR 0 et 7 changés" "0+7" "$(rago_pcr_changed "$tmp/pcr-old" "$tmp/pcr-07")"

# --- luksDump / systemd-cryptenroll (sorties réelles) ---------------------------------
sum=$(rago_luks_summary < "$fx/luksdump-cryptsetup-2.7-tpm2.txt")
check "luksDump : version" "version 2" "$(grep '^version' <<<"$sum")"
check "luksDump : chiffrement" "cipher aes-xts-plain64" "$(grep '^cipher' <<<"$sum")"
check "luksDump : sans étiquette" "label " "$(grep '^label' <<<"$sum")"
check "luksDump : emplacement passphrase" "keyslot 0 512 argon2id sha512" "$(grep '^keyslot 0' <<<"$sum")"
check "luksDump : emplacement TPM" "keyslot 2 512 pbkdf2 sha512" "$(grep '^keyslot 2' <<<"$sum")"
check "luksDump : jeton TPM2 PCR 0+7" "token 1 systemd-tpm2 2 0+7" "$(grep '^token' <<<"$sum")"
check "luksDump : hash du condensé" "digest-hash sha512" "$(grep '^digest-hash' <<<"$sum")"
check "luksDump : 2 emplacements" 2 "$(grep -c '^keyslot' <<<"$sum")"
# Étiquette et ancien nom du champ PCR (systemd < 252).
sed -e 's/^Label:.*/Label:          \trago-a/' -e 's/tpm2-hash-pcrs:/tpm2-pcrs:/' "$fx/luksdump-cryptsetup-2.7-tpm2.txt" > "$tmp/dump2"
sum2=$(rago_luks_summary < "$tmp/dump2")
check "luksDump : étiquette" "label rago-a" "$(grep '^label' <<<"$sum2")"
check "luksDump : tpm2-pcrs (ancien)" "token 1 systemd-tpm2 2 0+7" "$(grep '^token' <<<"$sum2")"

slots=$(rago_enroll_list_parse < "$fx/cryptenroll-list-systemd-255.txt")
check "cryptenroll : liste" "0 password
2 tpm2" "$slots"
check "cryptenroll : 1 passphrase" 1 "$(rago_slots_count "$slots" password)"
check "cryptenroll : 1 TPM" 1 "$(rago_slots_count "$slots" tpm2)"
check "cryptenroll : 0 recovery" 0 "$(rago_slots_count "$slots" recovery)"
check "cryptenroll : liste vide" 0 "$(rago_slots_count "" password)"
list3=$(printf 'SLOT TYPE    \n   1 tpm2\n   4 recovery\n' | rago_enroll_list_parse)
check "cryptenroll : TPM seul -> 0 passphrase" 0 "$(rago_slots_count "$list3" password)"

# --- crypttab -------------------------------------------------------------------------
opts=$(rago_crypttab_options 1)
check "options crypttab" "tpm2-device=auto,discard,no-read-workqueue,no-write-workqueue,x-initrd.attach" "$opts"
check "options sans discard" "tpm2-device=auto,no-read-workqueue,no-write-workqueue,x-initrd.attach" "$(rago_crypttab_options 0)"
check "options Rago sans danger" "" "$(rago_crypttab_bad_options "$opts")"
check "option swap refusée" "swap" "$(rago_crypttab_bad_options "tpm2-device=auto,swap,cipher=aes")"
check "options tmp / plain refusées" "tmp=ext4 plain" "$(rago_crypttab_bad_options "tmp=ext4,plain")"
U1=11111111-2222-3333-4444-555555555555
U2=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
l1=$(rago_crypttab_line rago-root "$U1" "$opts")
l2=$(rago_crypttab_line rago-swap "$U2" "$opts")
check "ligne crypttab" "rago-root  UUID=$U1 none $opts" "$l1"
cat > "$tmp/crypttab" <<EOF
# crypttab du joueur
data       UUID=99999999-0000-0000-0000-000000000000 /etc/keys/data.key luks
rago-root  UUID=00000000-dead-beef-0000-000000000000 none luks
luks-$U2   UUID=$U2 none luks,swap
EOF
merged=$(rago_crypttab_merge "$tmp/crypttab" "$l1" "$l2")
check "fusion : entrée du joueur gardée" 1 "$(grep -c '^data ' <<<"$merged")"
check "fusion : commentaire gardé" 1 "$(grep -c '^# crypttab du joueur' <<<"$merged")"
check "fusion : ancienne rago-root remplacée" 0 "$(grep -c 'dead-beef' <<<"$merged")"
check "fusion : même volume sous un autre nom retiré" 0 "$(grep -c "^luks-$U2" <<<"$merged")"
check "fusion : rago-root" "rago-root UUID=$U1 none $opts" "$(rago_crypttab_entry <(printf '%s\n' "$merged") rago-root)"
check "fusion : rago-swap" "rago-swap UUID=$U2 none $opts" "$(rago_crypttab_entry <(printf '%s\n' "$merged") rago-swap)"
check "fusion : marqueurs" 2 "$(grep -c "^# $RAGO_ENC_MARKER" <<<"$merged")"
printf '%s\n' "$merged" > "$tmp/crypttab2"
again=$(rago_crypttab_merge "$tmp/crypttab2" "$l1" "$l2")
check "fusion idempotente" "$merged" "$again"
check "crypttab vide" "2" "$(rago_crypttab_merge /dev/null "$l1" "$l2" | grep -vc '^#')"
check "crypttab absente (set -e)" "2" "$(set -e; rago_crypttab_merge "$tmp/absente" "$l1" "$l2" | grep -vc '^#')"
check "crypttab absente : retrait sans erreur" "0" "$(set -e; rago_crypttab_remove "$tmp/absente" rago-root; echo $?)"
check "fstab absent (set -e)" "/dev/mapper/rago-swap none swap defaults,pri=10 0 0" "$(set -e; rago_fstab_swap_merge "$tmp/absent" /dev/mapper/rago-swap 10 | grep -v '^#')"
removed=$(rago_crypttab_remove "$tmp/crypttab2" rago-root rago-swap)
check "retrait : seules les entrées du joueur" "data" "$(grep -v '^[[:space:]]*#' <<<"$removed" | awk 'NF { print $1 }')"
check_rc "entrée absente" 1 rago_crypttab_entry "$tmp/crypttab" nope
check "entrée sans options" "x /dev/sda1 - -" "$(rago_crypttab_entry <(printf 'x /dev/sda1\n') x)"

# --- fstab ------------------------------------------------------------------------------
cat > "$tmp/fstab" <<'EOF'
# fstab
/dev/mapper/rago-root / ext4 defaults 0 1
UUID=0000-1111 /boot vfat umask=0077 0 2
/dev/mapper/rago-swap none swap sw 0 0
UUID=deadbeef-swap none swap sw 0 0
/swapfile none swap sw 0 0
EOF
f=$(rago_fstab_swap_merge "$tmp/fstab" /dev/mapper/rago-swap 10 UUID=deadbeef-swap)
check "fstab : racine gardée" 1 "$(grep -c '^/dev/mapper/rago-root / ' <<<"$f")"
check "fstab : un seul swap Rago" 1 "$(grep -c '^/dev/mapper/rago-swap ' <<<"$f")"
check "fstab : même swap par UUID retiré" 0 "$(grep -c '^UUID=deadbeef-swap' <<<"$f")"
check "fstab : autre swap du joueur gardé" 1 "$(grep -c '^/swapfile' <<<"$f")"
check "fstab : ligne swap" "/dev/mapper/rago-swap none swap defaults,pri=10 0 0" "$(grep '^/dev/mapper/rago-swap' <<<"$f")"
printf '%s\n' "$f" > "$tmp/fstab2"
check "fstab idempotent" "$f" "$(rago_fstab_swap_merge "$tmp/fstab2" /dev/mapper/rago-swap 10 UUID=deadbeef-swap)"
check "fstab : source de /" /dev/mapper/rago-root "$(rago_fstab_root_source "$tmp/fstab")"

# --- mkinitcpio -------------------------------------------------------------------------
# shellcheck disable=SC2086  # découpage voulu
hk() { rago_mkinitcpio_hooks $1; }
check "HOOKS Arch par défaut (busybox)" \
	"base systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck" \
	"$(hk "base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck")"
check "HOOKS systemd déjà là" \
	"base systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck" \
	"$(hk "base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck")"
check "HOOKS encrypt + resume (busybox)" \
	"base systemd keyboard autodetect modconf sd-vconsole block sd-encrypt filesystems fsck" \
	"$(hk "base udev autodetect modconf block keyboard keymap encrypt resume filesystems fsck")"
check "HOOKS avec lvm2" \
	"base systemd keyboard autodetect modconf sd-vconsole block sd-encrypt lvm2 filesystems fsck" \
	"$(hk "base udev autodetect modconf block lvm2 filesystems keyboard fsck")"
check "HOOKS sans autodetect" \
	"base systemd keyboard modconf sd-vconsole block sd-encrypt filesystems" \
	"$(hk "base udev modconf block filesystems")"
check "HOOKS sans base" \
	"systemd keyboard autodetect sd-vconsole block sd-encrypt filesystems" \
	"$(hk "systemd autodetect filesystems")"
check "HOOKS idempotents" \
	"$(hk "base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck")" \
	"$(hk "$(hk "base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck")")"
check "HOOKS vides" "systemd keyboard sd-vconsole block sd-encrypt" "$(hk "")"
# shellcheck disable=SC2046
check_rc "ordre bon" 0 rago_mkinitcpio_hooks_ok $(hk "base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck")
check_rc "udev refusé" 1 rago_mkinitcpio_hooks_ok base udev keyboard block sd-encrypt filesystems
check_rc "encrypt refusé" 1 rago_mkinitcpio_hooks_ok base systemd keyboard block encrypt filesystems
check_rc "sans sd-encrypt" 1 rago_mkinitcpio_hooks_ok base systemd keyboard block filesystems
check_rc "sd-encrypt après filesystems" 1 rago_mkinitcpio_hooks_ok base systemd keyboard block filesystems sd-encrypt
check_rc "block après sd-encrypt" 1 rago_mkinitcpio_hooks_ok base systemd keyboard sd-encrypt block filesystems
check_rc "keyboard après sd-encrypt" 1 rago_mkinitcpio_hooks_ok base systemd block sd-encrypt keyboard filesystems
check_rc "sans keyboard" 1 rago_mkinitcpio_hooks_ok base systemd block sd-encrypt filesystems
check "raison affichée" "hook encrypt (busybox) : pas de TPM2, un seul volume" "$(rago_mkinitcpio_hooks_ok base systemd keyboard block encrypt filesystems)"
drop=$(rago_mkinitcpio_dropin "base udev" "base systemd keyboard sd-vconsole block sd-encrypt")
check "drop-in : HOOKS" "HOOKS=(base systemd keyboard sd-vconsole block sd-encrypt)" "$(grep '^HOOKS=' <<<"$drop")"
check "drop-in : marqueur" 1 "$(grep -c "$RAGO_ENC_MARKER" <<<"$drop")"
check "drop-in : HOOKS d'origine notés" "# HOOKS d'origine : (base udev)" "$(grep "^# HOOKS d'origine" <<<"$drop")"
# Le drop-in se lit comme mkinitcpio le lit (bash) : HOOKS final.
printf 'HOOKS=(base udev autodetect)\n' > "$tmp/mk.conf"
printf '%s\n' "$drop" > "$tmp/mk.d.conf"
check "drop-in sourcé après mkinitcpio.conf" "base systemd keyboard sd-vconsole block sd-encrypt" \
	"$(bash -c 'HOOKS=(); . "$1"; . "$2"; echo "${HOOKS[*]}"' _ "$tmp/mk.conf" "$tmp/mk.d.conf")"

# --- dracut -------------------------------------------------------------------------------
mkdir -p "$tmp/dracut/modules.d/10systemd" "$tmp/dracut/modules.d/70crypt" "$tmp/dracut/modules.d/71systemd-cryptsetup" \
	"$tmp/dracut/modules.d/73tpm2-tss" "$tmp/dracut/modules.d/74resume" "$tmp/dracut/modules.d/20i18n" "$tmp/dracut/modules.d/90kernel-modules"
touch "$tmp/dracut/modules.d/README"
mods=$(rago_dracut_modules "$tmp/dracut/modules.d")
check "modules dracut (dracut 110)" "systemd i18n crypt systemd-cryptsetup tpm2-tss resume kernel-modules" "$mods"
conf=$(rago_dracut_conf "$mods" "$U1" "$U2" 1)
check "dracut : modules" 'add_dracutmodules+=" systemd crypt systemd-cryptsetup tpm2-tss resume i18n "' "$(grep '^add_dracutmodules' <<<"$conf")"
check "dracut : volumes" "add_device+=\" /dev/disk/by-uuid/$U1 /dev/disk/by-uuid/$U2 \"" "$(grep '^add_device' <<<"$conf")"
check "dracut : crypttab" 'install_items+=" /etc/crypttab "' "$(grep '^install_items' <<<"$conf")"
check "dracut : marqueur" 1 "$(grep -c "$RAGO_ENC_MARKER" <<<"$conf")"
conf2=$(rago_dracut_conf "systemd crypt resume" "$U1" "" 0)
check "dracut ancien (sans systemd-cryptsetup / tpm2-tss)" 'add_dracutmodules+=" systemd crypt resume "' "$(grep '^add_dracutmodules' <<<"$conf2")"
check "dracut sans swap" "add_device+=\" /dev/disk/by-uuid/$U1 \"" "$(grep '^add_device' <<<"$conf2")"
check "dracut sans clavier : pas d'i18n" 0 "$(grep -c i18n <<<"$(rago_dracut_conf "$mods" "$U1" "" 0 | grep '^add_dracut')")"
# Le fichier se lit comme dracut le lit (bash) : variables valides.
printf '%s\n' "$conf" > "$tmp/d.conf"
check "dracut : fichier sourcé" " systemd crypt systemd-cryptsetup tpm2-tss resume i18n " \
	"$(bash -c 'add_dracutmodules=""; . "$1"; echo "$add_dracutmodules"' _ "$tmp/d.conf")"

# --- contenu de l'initramfs ------------------------------------------------------------
cat > "$tmp/lsinitrd" <<'EOF'
drwxr-xr-x  12 root     root            0 Nov 13 13:00 .
-rw-------   1 root     root          312 Nov 13 13:00 etc/crypttab
-rwxr-xr-x   1 root     root        85080 Nov 13 13:00 usr/bin/systemd-cryptsetup
lrwxrwxrwx   1 root     root           28 Nov 13 13:00 usr/lib/systemd/systemd-cryptsetup -> ../../bin/systemd-cryptsetup
-rwxr-xr-x   1 root     root        23816 Nov 13 13:00 usr/lib/systemd/system-generators/systemd-cryptsetup-generator
-rwxr-xr-x   1 root     root        41000 Nov 13 13:00 usr/lib/x86_64-linux-gnu/cryptsetup/libcryptsetup-token-systemd-tpm2.so
lrwxrwxrwx   1 root     root           22 Nov 13 13:00 usr/lib/x86_64-linux-gnu/libtss2-esys.so.0 -> libtss2-esys.so.0.0.0
lrwxrwxrwx   1 root     root           29 Nov 13 13:00 usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0 -> libtss2-tcti-device.so.0.0.0
-rw-r--r--   1 root     root        29000 Nov 13 13:00 usr/lib/modules/7.0.0-14-generic/kernel/drivers/md/dm-crypt.ko.zst
-rwxr-xr-x   1 root     root        12000 Nov 13 13:00 usr/lib/systemd/systemd-hibernate-resume
EOF
printf 'kernel/drivers/char/tpm/tpm_crb.ko\nkernel/drivers/char/tpm/tpm_tis.ko\n' > "$tmp/builtin"
check "initramfs complète" "" "$(rago_initramfs_missing "$tmp/lsinitrd" 1 "$tmp/builtin")"
check "initramfs : TPM ni intégré ni présent" "tpm_crb.ko|tpm_tis.ko" "$(rago_initramfs_missing "$tmp/lsinitrd" 1 "")"
grep -v 'systemd-hibernate-resume\|libtss2-tcti-device' "$tmp/lsinitrd" > "$tmp/lsinitrd2"
check "initramfs : manque resume et tcti" "libtss2-tcti-device systemd-hibernate-resume" "$(rago_initramfs_missing "$tmp/lsinitrd2" 1 "$tmp/builtin")"
check "initramfs sans swap : resume pas exigé" "libtss2-tcti-device" "$(rago_initramfs_missing "$tmp/lsinitrd2" 0 "$tmp/builtin")"
grep -v 'etc/crypttab\|dm-crypt' "$tmp/lsinitrd" > "$tmp/lsinitrd3"
check "initramfs : manque crypttab et dm-crypt" "etc/crypttab dm-crypt.ko" "$(rago_initramfs_missing "$tmp/lsinitrd3" 1 "$tmp/builtin")"
printf 'kernel/drivers/md/dm-crypt.ko\nkernel/drivers/char/tpm/tpm_crb.ko\n' > "$tmp/builtin-rago"
check "dm-crypt intégré (noyau Rago)" "etc/crypttab" "$(rago_initramfs_missing "$tmp/lsinitrd3" 1 "$tmp/builtin-rago")"
# Format lsinitcpio : un chemin par ligne.
sed -E 's/^.* [0-9]{2}:[0-9]{2} //; s/ -> .*//' "$tmp/lsinitrd" > "$tmp/lsinitcpio"
check "liste lsinitcpio complète" "" "$(rago_initramfs_missing "$tmp/lsinitcpio" 1 "$tmp/builtin")"
grep -v 'generator' "$tmp/lsinitrd" > "$tmp/lsinitrd4"
printf '... usr/lib/systemd/system-generators/systemd-cryptsetup-generator\n' > "$tmp/gen-only"
check "générateur seul ≠ systemd-cryptsetup" "systemd-cryptsetup" "$(rago_initramfs_missing "$tmp/gen-only" 0 "$tmp/builtin-rago" | tr ' ' '\n' | grep -x systemd-cryptsetup)"

# --- ligne de commande ------------------------------------------------------------------
check "cmdline avec swap" "root=/dev/mapper/rago-root resume=/dev/mapper/rago-swap" "$(rago_enc_cmdline 1)"
check "cmdline sans swap" "root=/dev/mapper/rago-root" "$(rago_enc_cmdline 0)"
check "valeur root (dernière)" "/dev/b" "$(rago_cmdline_value "root=/dev/a quiet root=/dev/b" root)"
check_rc "valeur absente" 1 rago_cmdline_value "quiet" root
check "valeur vide" "" "$(rago_cmdline_value "resume= quiet" resume)"
check "retrait root=" "quiet rw splash" "$(rago_cmdline_drop_key "root=UUID=x quiet rw root=/dev/y splash" root)"
check "retrait : ne touche pas rootflags=" "rootflags=subvol=@ quiet" "$(rago_cmdline_drop_key "root=x rootflags=subvol=@ quiet" root)"

# --- disque virtuel ou réel ? ------------------------------------------------------------
S="$tmp/sys"
mkdir -p "$S/devices/virtual/block/loop0/loop" "$S/devices/virtual/block/loop0/loop0p1" "$S/class/block" \
	"$S/devices/pci/virtio2/block/vda/vda1" "$S/devices/pci/nvme/nvme0/nvme0n1/nvme0n1p2" \
	"$S/devices/pci/ata1/sda/sda1" "$S/devices/pci/ata2/sdb" "$S/devices/pci/nvme/nvme1/nvme1n1" "$S/drivers/virtio_blk" \
	"$S/devices/pci/virtio3/block/xvda"
echo /var/tmp/disk.img > "$S/devices/virtual/block/loop0/loop/backing_file"
touch "$S/devices/virtual/block/loop0/loop0p1/partition" "$S/devices/pci/virtio2/block/vda/vda1/partition" \
	"$S/devices/pci/nvme/nvme0/nvme0n1/nvme0n1p2/partition" "$S/devices/pci/ata1/sda/sda1/partition"
mkdir -p "$S/devices/pci/nvme/nvme0/nvme0n1/device" "$S/devices/pci/ata1/sda/device" "$S/devices/pci/ata2/sdb/device" \
	"$S/devices/pci/nvme/nvme1/nvme1n1/device" "$S/devices/pci/virtio3/block/xvda/device"
echo "QEMU NVMe Ctrl" > "$S/devices/pci/nvme/nvme0/nvme0n1/device/model"
echo "ATA     " > "$S/devices/pci/ata1/sda/device/vendor"
echo "QEMU HARDDISK" > "$S/devices/pci/ata1/sda/device/model"
echo "ATA     " > "$S/devices/pci/ata2/sdb/device/vendor"
echo "Samsung SSD 990 PRO 2TB" > "$S/devices/pci/ata2/sdb/device/model"
echo "Samsung SSD 990 PRO 2TB" > "$S/devices/pci/nvme/nvme1/nvme1n1/device/model"
ln -s "$S/drivers/virtio_blk" "$S/devices/pci/virtio3/block/xvda/device/driver"
for p in devices/virtual/block/loop0 devices/virtual/block/loop0/loop0p1 devices/pci/virtio2/block/vda \
	devices/pci/virtio2/block/vda/vda1 devices/pci/nvme/nvme0/nvme0n1 devices/pci/nvme/nvme0/nvme0n1/nvme0n1p2 \
	devices/pci/ata1/sda devices/pci/ata1/sda/sda1 devices/pci/ata2/sdb devices/pci/nvme/nvme1/nvme1n1 devices/pci/virtio3/block/xvda; do
	ln -s "$S/$p" "$S/class/block/${p##*/}"
done
check_rc "loop0 virtuel" 0 rago_dev_is_virtual "$S/class/block/loop0"
check_rc "partition de loop virtuelle" 0 rago_dev_is_virtual "$S/class/block/loop0p1"
check_rc "vda virtuel" 0 rago_dev_is_virtual "$S/class/block/vda"
check_rc "vda1 virtuel" 0 rago_dev_is_virtual "$S/class/block/vda1"
check_rc "NVMe QEMU virtuel" 0 rago_dev_is_virtual "$S/class/block/nvme0n1"
check_rc "partition NVMe QEMU virtuelle" 0 rago_dev_is_virtual "$S/class/block/nvme0n1p2"
check_rc "disque SATA QEMU virtuel" 0 rago_dev_is_virtual "$S/class/block/sda1"
check_rc "pilote virtio_blk virtuel" 0 rago_dev_is_virtual "$S/class/block/xvda"
check_rc "vrai SSD SATA refusé" 1 rago_dev_is_virtual "$S/class/block/sdb"
check_rc "vrai NVMe refusé" 1 rago_dev_is_virtual "$S/class/block/nvme1n1"

printf 'test_crypt_lib : %d OK, %d échec(s)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
