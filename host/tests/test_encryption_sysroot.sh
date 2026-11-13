#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test de host/setup_secure_encryption.sh sur de FAUSSES racines
# (module M3) : aucun disque, aucun TPM, pas besoin de root.
#
# Vérifie ce que « install » écrit (crypttab, fstab, dracut ou mkinitcpio,
# ligne de commande du noyau Rago, réglages, outil et service), pour les slots A
# et B, avec et sans swap d'hibernation, l'idempotence, la vérification
# (« verify --root ») qui repère une crypttab ou des HOOKS cassés, les refus, et
# « check » (AES-NI / AVX2, TPM, PCR, Secure Boot) sur un faux /sys et /proc.
#
# Usage : host/tests/test_encryption_sysroot.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
S="$here/../setup_secure_encryption.sh"
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
has() { # has <nom> <motif grep -E> <texte>
	if grep -Eq -- "$2" <<<"$3"; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  motif absent : %s\n' "$1" "$2"
		printf '%s\n' "$3" | sed 's/^/    | /' | tail -15
	fi
}
hasnt() { # hasnt <nom> <motif grep -E> <texte>
	if grep -Eq -- "$2" <<<"$3"; then
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  motif présent : %s\n' "$1" "$2"
	else
		pass=$((pass + 1))
	fi
}
# Lance le script ; sortie (stdout + stderr, sans couleurs) dans $out, code dans $rc.
enc() {
	out=$(bash "$S" "$@" 2>&1)
	rc=$?
	out=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')
}
field() { grep -E "^$2=" "$1" | tail -1 | sed -E 's/^[^=]*="?//; s/"$//'; }
mode() { stat -c %a "$1"; }

UA=11111111-2222-4333-8444-555555555555
UB=22222222-3333-4444-8555-666666666666
US=33333333-4444-4555-8666-777777777777
KV=7.0.0-14-generic
OPTS="tpm2-device=auto,discard,no-read-workqueue,no-write-workqueue,x-initrd.attach"

# --- fausses racines -------------------------------------------------------------------
common_root() { # common_root <dossier>
	local r=$1
	mkdir -p "$r/etc/rago" "$r/usr/bin" "$r/usr/lib/systemd" "$r/boot"
	cat > "$r/etc/fstab" <<-'EOF'
	# fstab du joueur
	/dev/mapper/rago-root / ext4 rw,noatime 0 1
	UUID=ABCD-1234 /boot vfat umask=0077 0 2
	/dev/mapper/rago-swap none swap sw 0 0
	/data/swapfile none swap sw,pri=1 0 0
	EOF
	cat > "$r/etc/crypttab" <<-EOF
	# crypttab du joueur
	data UUID=99999999-0000-4000-8000-000000000000 /etc/keys/data.key luks
	luks-$UA UUID=$UA none luks
	EOF
	# Noyau Rago (M0) + réglages ajoutés par M1 (RAGO_CMDLINE_EXTRA).
	cat > "$r/etc/rago/kernel.conf" <<-'EOF'
	# Rago OS — options de démarrage du noyau Rago (lu par build_rago_kernel.sh).
	RAGO_CMDLINE="root=UUID=0b3c2d1e-aaaa-4bbb-8ccc-dddddddddddd rw quiet"
	RAGO_MITIGATIONS=auto
	RAGO_CMDLINE_EXTRA="threadirqs zswap.enabled=0"
	RAGO_ESP=/boot
	EOF
	echo 'KEYMAP=fr' > "$r/etc/vconsole.conf"
	printf '#!/bin/sh\nexit 0\n' > "$r/usr/lib/systemd/systemd-cryptsetup"
	chmod 755 "$r/usr/lib/systemd/systemd-cryptsetup"
}

dracut_root() { # Ubuntu / Debian : dracut 110
	local r=$1 m
	common_root "$r"
	printf '#!/bin/sh\necho "faux dracut $*" >> /dev/null\n' > "$r/usr/bin/dracut"
	printf '#!/bin/sh\nexit 0\n' > "$r/usr/bin/tpm2"
	chmod 755 "$r/usr/bin/dracut" "$r/usr/bin/tpm2"
	for m in 00systemd 10i18n 90crypt 01systemd-cryptsetup 91tpm2-tss 95resume 90kernel-modules 95rootfs-block; do
		mkdir -p "$r/usr/lib/dracut/modules.d/$m"
	done
	mkdir -p "$r/usr/lib/modules/$KV"
	: > "$r/usr/lib/modules/$KV/modules.dep"
	: > "$r/boot/vmlinuz-$KV"
	: > "$r/boot/initrd.img-$KV"
}

mkinitcpio_root() { # Arch / CachyOS : mkinitcpio + noyau Rago (pkgbase linux-rago)
	local r=$1
	common_root "$r"
	# Le vrai mkinitcpio lit /etc/mkinitcpio.conf.d/*.conf (v38+) : le test le repère ainsi.
	printf '#!/bin/bash\n# lit aussi /etc/mkinitcpio.conf.d\nexit 0\n' > "$r/usr/bin/mkinitcpio"
	chmod 755 "$r/usr/bin/mkinitcpio"
	cat > "$r/etc/mkinitcpio.conf" <<-'EOF'
	# vim:set ft=sh
	MODULES=()
	BINARIES=()
	FILES=()
	HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)
	EOF
	mkdir -p "$r/usr/lib/modules/6.18.0-rago"
	echo linux-rago > "$r/usr/lib/modules/6.18.0-rago/pkgbase"
	: > "$r/usr/lib/modules/6.18.0-rago/modules.dep"
	: > "$r/boot/vmlinuz-linux-rago"
	: > "$r/boot/initramfs-linux-rago.img"
}

# =====================================================================================
# 1. dracut, slot A, swap d'hibernation, deux slots
# =====================================================================================
R1="$tmp/r1"
dracut_root "$R1"
cp "$R1/etc/crypttab" "$tmp/crypttab.orig"
cp "$R1/etc/fstab" "$tmp/fstab.orig"
enc --root "$R1" --slot a --root-uuid "$UA" --other-slot-uuid "$UB" --swap-uuid "$US" install
check "dracut : install (code)" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -20

ct="$R1/etc/crypttab"
check "crypttab : mode 600" 600 "$(mode "$ct")"
check "crypttab : rago-root -> slot A" "rago-root  UUID=$UA none $OPTS" "$(grep '^rago-root ' "$ct")"
check "crypttab : rago-swap" "rago-swap  UUID=$US none $OPTS" "$(grep '^rago-swap ' "$ct")"
check "crypttab : entrée du joueur gardée" 1 "$(grep -c '^data UUID=99999999' "$ct")"
check "crypttab : même volume sous un autre nom retiré" 0 "$(grep -c "^luks-$UA" "$ct")"
check "crypttab : commentaire du joueur gardé" 1 "$(grep -c '^# crypttab du joueur' "$ct")"
check "crypttab : pas l'autre slot (sa propre crypttab)" 0 "$(grep -c "$UB" "$ct")"
check "crypttab : rien de « swap » / « tmp »" 0 "$(grep -v '^#' "$ct" | grep -Ec '[ ,](swap|tmp)(,|$| )')"

fs="$R1/etc/fstab"
check "fstab : swap chiffré" "/dev/mapper/rago-swap none swap defaults,pri=10 0 0" "$(grep '^/dev/mapper/rago-swap' "$fs")"
check "fstab : un seul swap rago-swap" 1 "$(grep -c '^/dev/mapper/rago-swap' "$fs")"
check "fstab : racine gardée" 1 "$(grep -c '^/dev/mapper/rago-root / ext4' "$fs")"
check "fstab : autre swap du joueur gardé" 1 "$(grep -c '^/data/swapfile' "$fs")"

dc="$R1/etc/dracut.conf.d/90-rago-encryption.conf"
check "dracut : modules (i18n : clavier fr pour la passphrase)" 'add_dracutmodules+=" systemd crypt systemd-cryptsetup tpm2-tss resume rago-crypttab i18n "' "$(grep '^add_dracutmodules' "$dc")"
check "dracut : racine et swap dans l'initramfs" "add_device+=\" /dev/disk/by-uuid/$UA /dev/disk/by-uuid/$US \"" "$(grep '^add_device' "$dc")"
check "dracut : pas toute la crypttab dans l'image" 0 "$(grep -c '^install_items' "$dc")"
dm="$R1/usr/lib/dracut/modules.d/91rago-crypttab/module-setup.sh"
check "dracut : module rago-crypttab installé" "ok" "$(cmp -s "$here/../dracut/91rago-crypttab/module-setup.sh" "$dm" && [ -x "$dm" ] && echo ok)"
ci="$R1/etc/crypttab.initramfs"
check "crypttab.initramfs : rago-root" "rago-root  UUID=$UA none $OPTS" "$(grep '^rago-root ' "$ci")"
check "crypttab.initramfs : rago-swap" "rago-swap  UUID=$US none $OPTS" "$(grep '^rago-swap ' "$ci")"
check "crypttab.initramfs : pas le volume « data » du joueur" 0 "$(grep -c '^data ' "$ci")"
check "crypttab.initramfs : mode 600" 600 "$(mode "$ci")"

# Le module dracut, appelé comme dracut l'appelle (initdir = image en cours).
dmod() { # dmod <racine> <image> : lance check() puis install()
	bash -c '. "$1"; dracutsysrootdir=$2 initdir=$3; check; echo "check=$?"; install; echo "install=$?"' _ "$dm" "$1" "$2"
}
mkdir -p "$tmp/img1"
check "module : check = seulement si demandé (255)" "check=255" "$(dmod "$R1" "$tmp/img1" | grep '^check=')"
dmod "$R1" "$tmp/img1" > /dev/null
check "module : non hostonly -> crypttab Rago seule" "ok" "$(cmp -s "$ci" "$tmp/img1/etc/crypttab" && echo ok)"
check "module : crypttab de l'image en 600" 600 "$(mode "$tmp/img1/etc/crypttab")"
# hostonly : le module crypt a déjà écrit sa crypttab filtrée (racine + un volume utile).
mkdir -p "$tmp/img2/etc"
printf 'luks-%s UUID=%s none luks\nhome UUID=44444444-0000-4000-8000-000000000000 none luks\n' "$UA" "$UA" > "$tmp/img2/etc/crypttab"
dmod "$R1" "$tmp/img2" > /dev/null
check "module hostonly : entrée du module crypt pour le même volume remplacée" 0 "$(grep -c "^luks-$UA" "$tmp/img2/etc/crypttab")"
check "module hostonly : autre volume gardé" 1 "$(grep -c '^home ' "$tmp/img2/etc/crypttab")"
check "module hostonly : rago-root et rago-swap" 2 "$(grep -c -e '^rago-root ' -e '^rago-swap ' "$tmp/img2/etc/crypttab")"
check "module : sans crypttab.initramfs, pas inclus" "check=1" "$(dmod "$tmp/vide" "$tmp/img3" 2>/dev/null | grep '^check=')"
check "dracut : fichier valide pour bash" "ok" "$(bash -n "$dc" && echo ok)"

kc="$R1/etc/rago/kernel.conf"
check "noyau : root= vers rago-root" "root=/dev/mapper/rago-root rw quiet" "$(field "$kc" RAGO_CMDLINE)"
check "noyau : resume= ajouté, réglages M1 gardés" "threadirqs zswap.enabled=0 resume=/dev/mapper/rago-swap" "$(field "$kc" RAGO_CMDLINE_EXTRA)"
check "noyau : autres réglages gardés" "auto" "$(field "$kc" RAGO_MITIGATIONS)"
check "noyau : jetons notés" "resume=/dev/mapper/rago-swap" "$(cat "$R1/var/lib/rago/encryption/cmdline-tokens")"
has "noyau : ancienne ligne sauvegardée" 'RAGO_CMDLINE="root=UUID=0b3c2d1e' "$(cat "$R1/var/lib/rago/encryption/kernel-cmdline-before")"

ec="$R1/etc/rago/encryption.conf"
check "réglages : slot" a "$(field "$ec" RAGO_ENC_SLOT)"
check "réglages : slot A" "$UA" "$(field "$ec" RAGO_ENC_ROOT_A_UUID)"
check "réglages : slot B" "$UB" "$(field "$ec" RAGO_ENC_ROOT_B_UUID)"
check "réglages : swap" "$US" "$(field "$ec" RAGO_ENC_SWAP_UUID)"
check "réglages : PCR 0+7" "0+7" "$(field "$ec" RAGO_ENC_TPM_PCRS)"
check "réglages : TRIM" 1 "$(field "$ec" RAGO_ENC_DISCARD)"

check "outil : rago-encryption" "exec /usr/lib/rago/setup_secure_encryption.sh \"\$@\"" "$(tail -1 "$R1/usr/bin/rago-encryption")"
check "outil : exécutable" 755 "$(mode "$R1/usr/bin/rago-encryption")"
check "outil : bibliothèques copiées" "ok" "$([ -f "$R1/usr/lib/rago/rago_crypt_lib.sh" ] && [ -f "$R1/usr/lib/rago/rago_host_lib.sh" ] && [ -x "$R1/usr/lib/rago/setup_secure_encryption.sh" ] && echo ok)"
check "service rago-tpm-check" "ok" "$(cmp -s "$here/../systemd/rago-tpm-check.service" "$R1/usr/lib/systemd/system/rago-tpm-check.service" && echo ok)"
check "minuterie activée" "/usr/lib/systemd/system/rago-tpm-check.timer" "$(readlink "$R1/etc/systemd/system/timers.target.wants/rago-tpm-check.timer")"
check "sauvegarde crypttab d'origine" "ok" "$(cmp -s "$tmp/crypttab.orig" "$R1/var/lib/rago/encryption/backup/etc%crypttab" && echo ok)"
check "sauvegarde fstab d'origine" "ok" "$(cmp -s "$tmp/fstab.orig" "$R1/var/lib/rago/encryption/backup/etc%fstab" && echo ok)"
hasnt "--root : initramfs pas régénérée" '^==> dracut : /boot' "$out"

# Idempotence : relancer ne change rien.
sum1=$(cd "$R1" && find . -type f ! -name '*.rago.*' -print0 | sort -z | xargs -0 sha256sum)
enc --root "$R1" --slot a --root-uuid "$UA" --other-slot-uuid "$UB" --swap-uuid "$US" install
check "dracut : 2e install (code)" 0 "$rc"
sum2=$(cd "$R1" && find . -type f ! -name '*.rago.*' -print0 | sort -z | xargs -0 sha256sum)
check "install idempotent (mêmes fichiers)" "$sum1" "$sum2"
check "sauvegarde gardée (pas écrasée par la 2e install)" "ok" "$(cmp -s "$tmp/crypttab.orig" "$R1/var/lib/rago/encryption/backup/etc%crypttab" && echo ok)"
# Relance sans rien redonner : les réglages enregistrés suffisent.
enc --root "$R1" install
check "install depuis les réglages (code)" 0 "$rc"
sum3=$(cd "$R1" && find . -type f ! -name '*.rago.*' -print0 | sort -z | xargs -0 sha256sum)
check "install depuis les réglages : mêmes fichiers" "$sum1" "$sum3"

# Vérification.
enc --root "$R1" verify
check "verify --root (code)" 0 "$rc"
has "verify : crypttab rago-root" '\[ OK \] +crypttab : rago-root' "$out"
has "verify : crypttab rago-swap" '\[ OK \] +crypttab : rago-swap' "$out"
has "verify : fstab" '\[ OK \] +fstab : swap /dev/mapper/rago-swap' "$out"
has "verify : dracut" '\[ OK \] +dracut : /etc/dracut' "$out"
has "verify : module dracut" '\[ OK \] +dracut : module rago-crypttab' "$out"
has "verify : crypttab.initramfs" '\[ OK \] +crypttab.initramfs : rago-swap' "$out"
has "verify : root= dans kernel.conf" '\[ OK \] +/etc/rago/kernel.conf : root=/dev/mapper/rago-root' "$out"
has "verify : resume= dans kernel.conf" '\[ OK \] +/etc/rago/kernel.conf : resume=/dev/mapper/rago-swap' "$out"
has "verify : bilan sans échec" 'Bilan : [0-9]+ OK, 0 échec' "$out"

enc --root "$R1" cmdline
check "cmdline (slot A)" "root=/dev/mapper/rago-root resume=/dev/mapper/rago-swap" "$out"
enc --root "$R1" --slot b cmdline
check "cmdline (slot B, même jetons)" "root=/dev/mapper/rago-root resume=/dev/mapper/rago-swap" "$out"

# verify repère les crypttab dangereuses.
cp "$ct" "$tmp/ct.good"
sed -i "s|^rago-swap .*|rago-swap  UUID=$US none tpm2-device=auto,swap|" "$ct"
enc --root "$R1" verify
check "verify : option swap -> échec" 1 "$rc"
has "verify : option swap expliquée" 'ÉCHEC.*rago-swap a l.option « swap »' "$out"
cp "$tmp/ct.good" "$ct"
sed -i "s|^rago-root .*|rago-root  UUID=$UA /etc/rago.key $OPTS|" "$ct"
enc --root "$R1" verify
check "verify : fichier de clé -> échec" 1 "$rc"
has "verify : fichier de clé expliqué" 'ÉCHEC.*fichier de clé.*contournerait le TPM' "$out"
cp "$tmp/ct.good" "$ct"
sed -i "s|^rago-root .*|rago-root  UUID=$UA none discard|" "$ct"
enc --root "$R1" verify
check "verify : sans tpm2-device -> échec" 1 "$rc"
has "verify : sans tpm2-device expliqué" 'ÉCHEC.*rago-root sans tpm2-device' "$out"
cp "$tmp/ct.good" "$ct"
sed -i "s|^rago-root .*|rago-root  UUID=$UB none $OPTS|" "$ct"
enc --root "$R1" verify
check "verify : mauvais slot -> échec" 1 "$rc"
cp "$tmp/ct.good" "$ct"
rm "$R1/boot/initrd.img-$KV"
enc --root "$R1" verify
check "verify : initramfs absente -> échec" 1 "$rc"
: > "$R1/boot/initrd.img-$KV"

# =====================================================================================
# 2. slot B (même machine, autre racine) : sa crypttab nomme SON volume rago-root
# =====================================================================================
R2="$tmp/r2"
dracut_root "$R2"
enc --root "$R2" --slot b --root-uuid "$UB" --other-slot-uuid "$UA" --swap-uuid "$US" install
check "slot B : install (code)" 0 "$rc"
check "slot B : rago-root -> volume B" "rago-root  UUID=$UB none $OPTS" "$(grep '^rago-root ' "$R2/etc/crypttab")"
check "slot B : même swap" "rago-swap  UUID=$US none $OPTS" "$(grep '^rago-swap ' "$R2/etc/crypttab")"
check "slot B : réglages slot" b "$(field "$R2/etc/rago/encryption.conf" RAGO_ENC_SLOT)"
check "slot B : réglages A" "$UA" "$(field "$R2/etc/rago/encryption.conf" RAGO_ENC_ROOT_A_UUID)"
check "slot B : réglages B" "$UB" "$(field "$R2/etc/rago/encryption.conf" RAGO_ENC_ROOT_B_UUID)"
check "slot B : dracut ouvre B et le swap" "add_device+=\" /dev/disk/by-uuid/$UB /dev/disk/by-uuid/$US \"" "$(grep '^add_device' "$R2/etc/dracut.conf.d/90-rago-encryption.conf")"
check "slot B : même ligne de commande (rago-root)" "root=/dev/mapper/rago-root rw quiet" "$(field "$R2/etc/rago/kernel.conf" RAGO_CMDLINE)"
enc --root "$R2" verify
check "slot B : verify (code)" 0 "$rc"

# =====================================================================================
# 3. sans swap : pas de resume, avertissement M6
# =====================================================================================
R3="$tmp/r3"
dracut_root "$R3"
cp "$R3/etc/fstab" "$tmp/fstab3.orig"
enc --root "$R3" --root-uuid "$UA" --no-discard install
check "sans swap : install (code)" 0 "$rc"
has "sans swap : avertit (Fast OS Switch)" 'pas de swap chiffré.*M6' "$out"
check "sans swap : crypttab sans rago-swap" 0 "$(grep -c '^rago-swap' "$R3/etc/crypttab")"
check "sans swap, sans TRIM : options" "rago-root  UUID=$UA none tpm2-device=auto,no-read-workqueue,no-write-workqueue,x-initrd.attach" "$(grep '^rago-root ' "$R3/etc/crypttab")"
check "sans swap : fstab intact" "ok" "$(cmp -s "$tmp/fstab3.orig" "$R3/etc/fstab" && echo ok)"
check "sans swap : pas de resume=" "threadirqs zswap.enabled=0" "$(field "$R3/etc/rago/kernel.conf" RAGO_CMDLINE_EXTRA)"
check "sans swap : dracut, racine seule" "add_device+=\" /dev/disk/by-uuid/$UA \"" "$(grep '^add_device' "$R3/etc/dracut.conf.d/90-rago-encryption.conf")"
check "sans swap : slot a par défaut" a "$(field "$R3/etc/rago/encryption.conf" RAGO_ENC_SLOT)"
enc --root "$R3" cmdline
check "sans swap : cmdline" "root=/dev/mapper/rago-root" "$out"
enc --root "$R3" verify
check "sans swap : verify (code)" 0 "$rc"

# Sans noyau Rago (pas de kernel.conf) : avertit, ne crée rien.
R3b="$tmp/r3b"
dracut_root "$R3b"
rm "$R3b/etc/rago/kernel.conf"
enc --root "$R3b" --root-uuid "$UA" --swap-uuid "$US" install
check "sans kernel.conf : install (code)" 0 "$rc"
has "sans kernel.conf : dit quoi ajouter au chargeur" 'kernel.conf absent.*root=/dev/mapper/rago-root resume=/dev/mapper/rago-swap' "$out"
check "sans kernel.conf : rien créé" "absent" "$([ -e "$R3b/etc/rago/kernel.conf" ] && echo présent || echo absent)"

# Système neuf sans /etc/crypttab ni /etc/fstab (Ubuntu n'a pas de crypttab au départ).
R3d="$tmp/r3d"
dracut_root "$R3d"
rm "$R3d/etc/crypttab" "$R3d/etc/fstab"
enc --root "$R3d" --root-uuid "$UA" --swap-uuid "$US" install
check "sans crypttab ni fstab : install (code)" 0 "$rc"
check "sans crypttab : en-tête + 2 entrées" "3" "$(grep -c -e '^# /etc/crypttab' -e '^rago-root ' -e '^rago-swap ' "$R3d/etc/crypttab" 2>/dev/null)"
check "sans fstab : swap ajouté" 1 "$(grep -c '^/dev/mapper/rago-swap none swap' "$R3d/etc/fstab" 2>/dev/null)"
check "sans crypttab : absence notée" "ok" "$([ -e "$R3d/var/lib/rago/encryption/backup/etc%crypttab.absent" ] && echo ok)"
enc --root "$R3d" install
check "sans crypttab : 2e install (code)" 0 "$rc"
check "sans crypttab : la crypttab Rago n'est pas prise pour l'originale" "absent" "$([ -e "$R3d/var/lib/rago/encryption/backup/etc%crypttab" ] && echo présent || echo absent)"

# rd.luks.* : n'ouvrirait que ces volumes (swap oublié -> pas de resume).
R3c="$tmp/r3c"
dracut_root "$R3c"
sed -i 's/^RAGO_CMDLINE=.*/RAGO_CMDLINE="root=UUID=x rw rd.luks.uuid=1234"/' "$R3c/etc/rago/kernel.conf"
enc --root "$R3c" --root-uuid "$UA" --swap-uuid "$US" install
has "rd.luks.uuid : avertissement" 'rd\.luks\.\* sur la ligne de commande' "$out"

# =====================================================================================
# 4. mkinitcpio (Arch / CachyOS) : HOOKS systemd + sd-encrypt, crypttab.initramfs
# =====================================================================================
R4="$tmp/r4"
mkinitcpio_root "$R4"
enc --root "$R4" --root-uuid "$UA" --other-slot-uuid "$UB" --swap-uuid "$US" install
check "mkinitcpio : install (code)" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -20
mk="$R4/etc/mkinitcpio.conf.d/90-rago-encryption.conf"
check "mkinitcpio : HOOKS" "HOOKS=(base systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck)" "$(grep '^HOOKS=' "$mk")"
has "mkinitcpio : HOOKS d'origine notés" "^# HOOKS d'origine : \(base udev autodetect" "$(cat "$mk")"
check "mkinitcpio : mkinitcpio.conf du système intact" "HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)" "$(grep '^HOOKS=' "$R4/etc/mkinitcpio.conf")"
check "mkinitcpio : HOOKS effectifs (lus comme mkinitcpio)" "base systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck" \
	"$(bash -c 'HOOKS=(); . "$1/etc/mkinitcpio.conf"; for f in "$1"/etc/mkinitcpio.conf.d/*.conf; do . "$f"; done; echo "${HOOKS[*]}"' _ "$R4")"
check "mkinitcpio : crypttab.initramfs rago-root" "rago-root  UUID=$UA none $OPTS" "$(grep '^rago-root ' "$R4/etc/crypttab.initramfs")"
check "mkinitcpio : crypttab.initramfs rago-swap" "rago-swap  UUID=$US none $OPTS" "$(grep '^rago-swap ' "$R4/etc/crypttab.initramfs")"
check "mkinitcpio : crypttab.initramfs mode 600" 600 "$(mode "$R4/etc/crypttab.initramfs")"
check "mkinitcpio : pas de fichier dracut" "absent" "$([ -e "$R4/etc/dracut.conf.d/90-rago-encryption.conf" ] && echo présent || echo absent)"
check "mkinitcpio : réglages auto" auto "$(field "$R4/etc/rago/encryption.conf" RAGO_ENC_INITRAMFS)"
enc --root "$R4" verify
check "mkinitcpio : verify (code)" 0 "$rc"
has "mkinitcpio : verify HOOKS" '\[ OK \] +mkinitcpio : HOOKS=\(base systemd' "$out"
has "mkinitcpio : verify crypttab.initramfs" '\[ OK \] +crypttab.initramfs : rago-swap' "$out"
sum1=$(cd "$R4" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
enc --root "$R4" install
sum2=$(cd "$R4" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
check "mkinitcpio : install idempotent" "$sum1" "$sum2"
# Un drop-in du joueur plus tard dans l'ordre remet le hook encrypt (busybox) : verify le voit.
printf 'HOOKS=(base udev autodetect modconf block encrypt filesystems fsck)\n' > "$R4/etc/mkinitcpio.conf.d/99-joueur.conf"
enc --root "$R4" verify
check "mkinitcpio : drop-in qui casse les HOOKS -> échec" 1 "$rc"
has "mkinitcpio : raison" 'ÉCHEC.*mkinitcpio : hook udev' "$out"
rm "$R4/etc/mkinitcpio.conf.d/99-joueur.conf"

# HOOKS déjà en systemd (installation Arch récente) : rien de doublé.
R5="$tmp/r5"
mkinitcpio_root "$R5"
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' "$R5/etc/mkinitcpio.conf"
enc --root "$R5" --root-uuid "$UA" --swap-uuid "$US" install
check "mkinitcpio systemd : install (code)" 0 "$rc"
check "mkinitcpio systemd : HOOKS" "HOOKS=(base systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems fsck)" "$(grep '^HOOKS=' "$R5/etc/mkinitcpio.conf.d/90-rago-encryption.conf")"

# Forcer dracut sur une racine qui a les deux.
R6="$tmp/r6"
mkinitcpio_root "$R6"
cp -a "$R1/usr/lib/dracut" "$R6/usr/lib/"
cp "$R1/usr/bin/dracut" "$R1/usr/bin/tpm2" "$R6/usr/bin/"
enc --root "$R6" --root-uuid "$UA" --initramfs dracut install
check "--initramfs dracut : install (code)" 0 "$rc"
check "--initramfs dracut : fichier dracut" "ok" "$([ -f "$R6/etc/dracut.conf.d/90-rago-encryption.conf" ] && [ ! -e "$R6/etc/mkinitcpio.conf.d/90-rago-encryption.conf" ] && echo ok)"
check "--initramfs dracut : retenu dans les réglages" dracut "$(field "$R6/etc/rago/encryption.conf" RAGO_ENC_INITRAMFS)"

# =====================================================================================
# 5. refus
# =====================================================================================
R7="$tmp/r7"
dracut_root "$R7"
enc --root "$R7" --root-uuid "$UA" --other-slot-uuid "$UA" install
check "refus : deux slots sur le même volume" 1 "$rc"
has "refus : deux slots, raison" 'les deux slots ont le même volume' "$out"
enc --root "$R7" --root-uuid "$UA" --swap-uuid "$UA" install
check "refus : swap = racine" 1 "$rc"
enc --root "$R7" install
check "refus : racine inconnue" 1 "$rc"
has "refus : racine inconnue, raison" 'racine chiffrée introuvable' "$out"
enc --root "$R7" --root-uuid "$UA" --pcrs 0+25 install
check "refus : PCR invalides" 1 "$rc"
enc --root "$R7" --root-uuid "$UA" --slot c install
check "refus : slot invalide" 1 "$rc"
enc --root "$R7" --root-uuid "$UA" --initramfs booster install
check "refus : générateur inconnu" 1 "$rc"
check "refus : rien écrit" "absent" "$([ -e "$R7/etc/rago/encryption.conf" ] && echo présent || echo absent)"
# initramfs-tools seul (Ubuntu par défaut) : ne sait pas faire le TPM2.
R8="$tmp/r8"
common_root "$R8"
mkdir -p "$R8/usr/sbin" && printf '#!/bin/sh\n' > "$R8/usr/sbin/update-initramfs" && chmod 755 "$R8/usr/sbin/update-initramfs"
enc --root "$R8" --root-uuid "$UA" install
check "refus : initramfs-tools" 1 "$rc"
has "refus : initramfs-tools, propose dracut" 'initramfs-tools ne sait pas déverrouiller par TPM2 : installe dracut' "$out"
enc --root "$R1" --device "$tmp/r1/etc/fstab" --role swap format
check "refus : format avec --root" 1 "$rc"
enc --dry-run --device "$tmp/r1/etc/fstab" --role root-a format
check "refus : format d'un fichier ordinaire" 1 "$rc"
has "refus : pas un périphérique bloc" "n'est pas un périphérique bloc" "$out"
enc --dry-run --device /dev/null --role root-z format
check "refus : rôle inconnu" 1 "$rc"
enc install verify
check "refus : deux commandes" 1 "$rc"
enc --truc
check "refus : option inconnue" 1 "$rc"
enc
check "sans commande : aide (code 2)" 2 "$rc"
enc --help
check "--help (code)" 0 "$rc"
has "--help : commandes" 'enroll-tpm' "$out"

# --dry-run : n'écrit rien.
R9="$tmp/r9"
dracut_root "$R9"
sum1=$(cd "$R9" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
enc --root "$R9" --root-uuid "$UA" --swap-uuid "$US" --dry-run install
check "--dry-run install (code)" 0 "$rc"
has "--dry-run : annonce l'écriture de la crypttab" '\[dry-run\] écrire .*/etc/crypttab' "$out"
sum2=$(cd "$R9" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
check "--dry-run : aucun fichier changé" "$sum1" "$sum2"

# =====================================================================================
# 6. check : AES-NI / AVX2, TPM, PCR, Secure Boot (faux /sys et /proc)
# =====================================================================================
fake_hw() { # fake_hw <dossier> <drapeaux cpu> <pilote xts> <pcr0> <pcr7> <secure boot 0|1|-> <tpm 0|1>
	local d=$1
	mkdir -p "$d/proc" "$d/sys/firmware/efi/efivars" "$d/sys/module/dm_crypt"
	printf 'processor\t: 0\nflags\t\t: %s\n' "$2" > "$d/proc/cpuinfo"
	printf 'name         : xts(aes)\ndriver       : %s\nmodule       : kernel\npriority     : 401\n' "$3" > "$d/proc/crypto"
	printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$d/proc/swaps"
	if [ "$7" = 1 ]; then
		mkdir -p "$d/sys/class/tpm/tpm0/pcr-sha256" "$d/sys/class/tpm/tpm0/device"
		echo 2 > "$d/sys/class/tpm/tpm0/tpm_version_major"
		echo "$4" > "$d/sys/class/tpm/tpm0/pcr-sha256/0"
		echo "$5" > "$d/sys/class/tpm/tpm0/pcr-sha256/7"
		echo "TPM 2.0 Device" > "$d/sys/class/tpm/tpm0/device/description"
	fi
	if [ "$6" != - ]; then
		# efivarfs : 4 octets d'attributs puis la valeur (1 = Secure Boot actif).
		printf '\x06\x00\x00\x00' > "$d/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
		if [ "$6" = 1 ]; then printf '\x01'; else printf '\x00'; fi >> "$d/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
	fi
}
P0=3D458CFE55CC03EA1F443F1562BEEC8DF51C75E14A9FCF9A7234A13F198E7969
P7=B5710BF57D25623E4019027DA116821FA99F5C81E9E38B87671CC574F9281439
Z=0000000000000000000000000000000000000000000000000000000000000000
H1="$tmp/hw1"
fake_hw "$H1" "fpu sse2 pclmulqdq aes avx avx2 vaes" xts-aes-vaes-avx2 "$P0" "$P7" 1 1
out=$(RAGO_SYSFS="$H1/sys" RAGO_PROCFS="$H1/proc" bash "$S" --root "$R1" check 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
has "check : AES-NI" '\[ OK \] +AES-NI présent' "$out"
has "check : AVX2" '\[ OK \] +AVX2 présent' "$out"
has "check : VAES" '\[ OK \] +VAES présent' "$out"
has "check : pilote xts accéléré" '\[ OK \] +xts\(aes\) du noyau : xts-aes-vaes-avx2' "$out"
has "check : TPM 2.0" '\[ OK \] +TPM 2.0 présent \(TPM 2.0 Device\)' "$out"
has "check : PCR mesurés" '\[ OK \] +PCR 0\+7 mesurés' "$out"
has "check : UEFI" '\[ OK \] +démarrage UEFI' "$out"
has "check : Secure Boot actif" '\[ OK \] +Secure Boot actif' "$out"
has "check : dracut + tpm2-tools" '\[ OK \] +tpm2-tools' "$out"
has "check : clavier fr au démarrage" '\[ OK \] +clavier au démarrage : fr' "$out"

H2="$tmp/hw2"
fake_hw "$H2" "fpu sse2" "xts(ecb(aes-generic))" "$Z" "$P7" 0 1
rm -rf "$H2/sys/module/dm_crypt"
out=$(RAGO_SYSFS="$H2/sys" RAGO_PROCFS="$H2/proc" bash "$S" --root "$R3" check 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
rc_chk=${PIPESTATUS[0]}
has "check : AES-NI absent -> avertit" '\[ ATTENTION \] AES-NI absent : chiffrement logiciel' "$out"
has "check : AVX2 absent -> avertit" '\[ ATTENTION \] AVX2 absent' "$out"
has "check : pilote xts lent" '\[ ATTENTION \] xts\(aes\) du noyau : xts\(ecb\(aes-generic\)\) \(pas accéléré\)' "$out"
has "check : PCR 0 jamais mesuré -> échec" '\[ ÉCHEC \] +PCR 0 jamais mesurés' "$out"
has "check : Secure Boot inactif -> PCR 7 changera" '\[ ATTENTION \] Secure Boot inactif.*PCR 7 changera' "$out"
: "$rc_chk"

H3="$tmp/hw3"
fake_hw "$H3" "fpu aes avx2" xts-aes-aesni "$P0" "$P7" - 0
rm -rf "$H3/sys/firmware"
sed -i '/^KEYMAP/d' "$R3/etc/vconsole.conf"
enc_out=$(RAGO_SYSFS="$H3/sys" RAGO_PROCFS="$H3/proc" bash "$S" --root "$R3" check 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
has "check : sans TPM -> échec" '\[ ÉCHEC \] +pas de TPM 2.0' "$enc_out"
has "check : BIOS legacy -> échec" '\[ ÉCHEC \] +démarrage BIOS \(legacy\)' "$enc_out"
has "check : pas de KEYMAP -> QWERTY" '\[ ATTENTION \] pas de KEYMAP.*QWERTY' "$enc_out"
has "check : code 1 si pas prêt" '^Bilan : .* [1-9][0-9]* échec' "$enc_out"

R10="$tmp/r10"
common_root "$R10"
out=$(RAGO_SYSFS="$H1/sys" RAGO_PROCFS="$H1/proc" bash "$S" --root "$R10" check 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
has "check : sans générateur d'initramfs -> échec" '\[ ÉCHEC \] +aucun générateur' "$out"
mkdir -p "$R10/usr/sbin" && printf '#!/bin/sh\n' > "$R10/usr/sbin/update-initramfs" && chmod 755 "$R10/usr/sbin/update-initramfs"
out=$(RAGO_SYSFS="$H1/sys" RAGO_PROCFS="$H1/proc" bash "$S" --root "$R10" check 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
has "check : initramfs-tools -> échec, propose dracut" '\[ ÉCHEC \] +initramfs : initramfs-tools.*installe dracut' "$out"
printf '#!/bin/bash\nexit 0\n' > "$R10/usr/bin/mkinitcpio" && chmod 755 "$R10/usr/bin/mkinitcpio" && : > "$R10/etc/mkinitcpio.conf"
out=$(RAGO_SYSFS="$H1/sys" RAGO_PROCFS="$H1/proc" bash "$S" --root "$R10" check 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
has "check : mkinitcpio trop ancien -> échec" '\[ ÉCHEC \] +mkinitcpio trop ancien' "$out"

printf 'test_encryption_sysroot : %d OK, %d échec(s)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
