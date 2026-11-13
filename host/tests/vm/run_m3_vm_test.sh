#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test du module M3 dans une VM qemu jetable : UEFI (OVMF), TPM 2.0
# émulé (swtpm, vu par le noyau comme un vrai TPM CRB), disques VIRTUELS
# seulement (fichiers jetables). Jamais de vrai disque, jamais de vrai TPM.
#
# Six démarrages (détail : host/tests/vm/m3_vm_guest.sh) :
#   1  installateur (racine ext4 non chiffrée) : check, refus, format des slots
#      A / B et du swap, copie du système dans A, install (dracut réel),
#      enroll-tpm sur le TPM du noyau (PCR 0+7 mesurés par OVMF)
#   2  slot A : racine ET swap déverrouillés par le TPM sans passphrase, verify,
#      tpm-check, open / close, puis hibernation vers le swap chiffré
#   3  reprise de l'hibernation (le swap est ouvert par le TPM AVANT le
#      resume), puis installation du slot B depuis le slot A
#   4  slot B : sa propre crypttab, TPM, verify
#   5  Secure Boot ACTIVÉ (clés de test OVMF) : PCR 7 change, le TPM refuse, la
#      passphrase de secours est demandée et tapée sur la console série,
#      tpm-check le signale, verify le voit, reseal
#   6  slot A, Secure Boot actif : de nouveau déverrouillé par le TPM seul
#
# Limites : base Ubuntu 26.04 (dracut 110, systemd 259) et non Arch / base Rago
# (mkinitcpio non testé ici) ; noyau Ubuntu (verrouillé sous Secure Boot :
# l'hibernation n'est testée que Secure Boot inactif — le noyau Rago de M0
# n'impose pas ce verrouillage) ; émulation TCG lente ; le clavier réel au
# démarrage et un vrai TPM / firmware restent à tester sur le matériel.
#
# Usage (root : debootstrap, chroot, mkfs) :
#   run_m3_vm_test.sh [--rootfs DIR] [--keep]
#   --rootfs DIR   système de base déjà préparé (sinon construit ; ~900 Mo)
#   --keep         garde le dossier de travail (journaux, images)
#
# Dépendances : debootstrap, qemu-system-x86_64, OVMF (secboot + clés de test
# « snakeoil »), swtpm, sbsign (sbsigntool), openssl, mkfs.ext4, debugfs,
# sfdisk, python3, accès au miroir Ubuntu.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hostdir=$(cd "$here/../.." && pwd)
rootfs=""
keep=0
MIRROR=${RAGO_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
SUITE=${RAGO_M3_SUITE:-resolute}
TIMEOUT=${RAGO_VM_TIMEOUT:-2700}
OVMF_DIR=${RAGO_OVMF_DIR:-/usr/share/OVMF}
OVMF_CODE="$OVMF_DIR/OVMF_CODE_4M.secboot.fd"
OVMF_VARS_OFF="$OVMF_DIR/OVMF_VARS_4M.fd"
OVMF_VARS_SB="$OVMF_DIR/OVMF_VARS_4M.snakeoil.fd"
SNAKEOIL_KEY=${RAGO_SNAKEOIL_KEY:-/usr/share/ovmf/PkKek-1-snakeoil.key}
SNAKEOIL_CERT=${RAGO_SNAKEOIL_CERT:-/usr/share/ovmf/PkKek-1-snakeoil.pem}
PASSPHRASE="Rago-secours-M3-test"

while [ $# -gt 0 ]; do
	case "$1" in
	--rootfs) rootfs=$2; shift 2 ;;
	--keep) keep=1; shift ;;
	-h | --help) sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (debootstrap, chroot, mkfs)" >&2; exit 2; }
for t in qemu-system-x86_64 swtpm sbsign sbverify openssl mkfs.ext4 debugfs sfdisk python3; do
	command -v "$t" >/dev/null || { echo "outil manquant : $t" >&2; exit 2; }
done
for f in "$OVMF_CODE" "$OVMF_VARS_OFF" "$OVMF_VARS_SB" "$SNAKEOIL_KEY" "$SNAKEOIL_CERT"; do
	[ -f "$f" ] || { echo "fichier manquant : $f (paquet ovmf)" >&2; exit 2; }
done

work=$(mktemp -d /var/tmp/rago-m3-vm.XXXXXX)
mounted=""
# shellcheck disable=SC2317  # appelée par trap
cleanup() {
	local m
	for m in $mounted; do umount "$m" 2>/dev/null || true; done
	pkill -f "swtpm socket --tpmstate dir=$work/tpm" 2>/dev/null || true
	if [ "$keep" = 1 ]; then echo "dossier gardé : $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# --- système de base (Ubuntu 26.04 : dracut 110, systemd récent) ---------------------------
PKGS="dracut zstd linux-image-virtual cryptsetup cryptsetup-bin systemd-cryptsetup tpm2-tools fdisk e2fsprogs util-linux kbd dbus"
build_rootfs() {
	local d=$1 script=""
	[ -e "/usr/share/debootstrap/scripts/$SUITE" ] || script=/usr/share/debootstrap/scripts/gutsy
	echo "==> debootstrap Ubuntu $SUITE dans $d"
	# shellcheck disable=SC2086
	debootstrap --variant=minbase --include=systemd-sysv,udev,dbus,kmod,procps,iproute2 \
		--components=main,universe "$SUITE" "$d" "$MIRROR" $script > "$work/debootstrap.log" 2>&1 ||
		{ tail -20 "$work/debootstrap.log"; exit 1; }
	echo "deb $MIRROR $SUITE main universe" > "$d/etc/apt/sources.list"
	cp /etc/resolv.conf "$d/etc/resolv.conf" 2>/dev/null || true
	for m in proc sys dev; do mount --bind "/$m" "$d/$m"; mounted="$d/$m $mounted"; done
	# dracut d'abord : l'initramfs du noyau est alors faite par dracut.
	chroot "$d" bash -c "export DEBIAN_FRONTEND=noninteractive
		apt-get update -q && apt-get install -y -q --no-install-recommends dracut dracut-core zstd &&
		apt-get install -y -q --no-install-recommends $PKGS" > "$work/apt.log" 2>&1 ||
		{ tail -20 "$work/apt.log"; exit 1; }
	for m in proc sys dev; do umount "$d/$m"; done
	mounted=""
}
if [ -z "$rootfs" ]; then rootfs="$work/rootfs"; fi
if [ ! -x "$rootfs/usr/bin/systemd-cryptenroll" ] || [ ! -x "$rootfs/usr/bin/dracut" ]; then build_rootfs "$rootfs"; fi
kernel=$(find "$rootfs/boot" -name 'vmlinuz-*-generic' | sort -V | tail -1)
kver=${kernel##*/vmlinuz-}
[ -f "$rootfs/boot/initrd.img-$kver" ] || { echo "initramfs absente pour $kver" >&2; exit 1; }

# --- image de l'installateur -------------------------------------------------------------
echo "==> préparation des disques virtuels (dans $work)"
img="$work/inst"
cp -a "$rootfs" "$img"
mkdir -p "$img/opt/rago-m3" "$img/export"
cp -a "$hostdir" "$img/opt/rago-m3/host"
printf '%s' "$PASSPHRASE" > "$img/root/m3pass"
chmod 600 "$img/root/m3pass"
printf '%s' "$PASSPHRASE" > "$work/pass"
chmod 600 "$work/pass"
echo "LABEL=rago-inst / ext4 rw,errors=remount-ro 0 1" > "$img/etc/fstab"
echo rago-m3-vm > "$img/etc/hostname"
rm -rf "$img/var/lib/rago" "$img/etc/rago" "$img/etc/crypttab"
ln -sf /dev/null "$img/etc/systemd/system/serial-getty@ttyS0.service"
cat > "$img/etc/systemd/system/rago-m3-test.service" <<'EOF'
[Unit]
Description=Rago OS : test VM du module M3
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/opt/rago-m3/host/tests/vm/m3_vm_guest.sh
TimeoutStartSec=infinity
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyS0
[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/rago-m3-test.service "$img/etc/systemd/system/multi-user.target.wants/rago-m3-test.service"
truncate -s 5G "$work/inst.img"
mkfs.ext4 -q -F -L rago-inst -d "$img" "$work/inst.img"
rm -rf "$img"
truncate -s 3G "$work/a.img" "$work/b.img"
truncate -s 2G "$work/swap.img"
truncate -s 64M "$work/part.img"
printf 'label: gpt\n,16M\n,\n' | sfdisk -q "$work/part.img"

# Noyau signé avec la clé de test d'OVMF (démarrages 5 et 6, Secure Boot actif).
openssl pkey -in "$SNAKEOIL_KEY" -passin pass:snakeoil -out "$work/snakeoil.key" 2>/dev/null ||
	cp "$SNAKEOIL_KEY" "$work/snakeoil.key"
sbsign --key "$work/snakeoil.key" --cert "$SNAKEOIL_CERT" --output "$work/vmlinuz" "$kernel" > /dev/null 2>&1
sbverify --cert "$SNAKEOIL_CERT" "$work/vmlinuz" > /dev/null 2>&1 || { echo "signature du noyau impossible" >&2; exit 1; }
cp "$rootfs/boot/initrd.img-$kver" "$work/initrd-inst.img"
cp "$OVMF_VARS_OFF" "$work/vars-off.fd"
cp "$OVMF_VARS_SB" "$work/vars-sb.fd"
mkdir -p "$work/tpm"

# Fichier de l'image de l'installateur (lu sans la monter).
inst_get() { debugfs -R "dump -p $1 $2" "$work/inst.img" > /dev/null 2>&1 && [ -s "$2" ]; }

boot() { # boot <n> <vars> <initrd> <cmdline> <type|forbid>
	local n=$1 vars=$2 initrd=$3 cmdline=$4 mode=$5 qpid arc=0
	echo "==> démarrage $n de la VM (TCG : plusieurs minutes)"
	swtpm socket --tpmstate dir="$work/tpm" --ctrl type=unixio,path="$work/tpm/sock" --tpm2 \
		--terminate --daemon --log file="$work/swtpm$n.log"
	rm -f "$work/serial$n.sock"
	timeout "$TIMEOUT" qemu-system-x86_64 \
		-machine q35,smm=on -accel tcg,thread=multi -cpu max -smp 4 -m 2048 \
		-global driver=cfi.pflash01,property=secure,value=on \
		-drive "if=pflash,format=raw,unit=0,file=$OVMF_CODE,readonly=on" \
		-drive "if=pflash,format=raw,unit=1,file=$vars" \
		-chardev "socket,id=chrtpm,path=$work/tpm/sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
		-display none -monitor none -no-reboot \
		-chardev "socket,id=ser0,path=$work/serial$n.sock,server=on,wait=off,logfile=$work/serial$n.log" -serial chardev:ser0 \
		-kernel "$work/vmlinuz" -initrd "$initrd" \
		-append "$cmdline console=ttyS0,115200 loglevel=4 rago_m3_phase=$n" \
		-drive "file=$work/inst.img,if=none,id=inst,format=raw" -device virtio-blk-pci,drive=inst,serial=rago-inst \
		-drive "file=$work/a.img,if=none,id=da,format=raw" -device virtio-blk-pci,drive=da,serial=rago-a \
		-drive "file=$work/b.img,if=none,id=db,format=raw" -device virtio-blk-pci,drive=db,serial=rago-b \
		-drive "file=$work/swap.img,if=none,id=ds,format=raw" -device virtio-blk-pci,drive=ds,serial=rago-swap \
		-drive "file=$work/part.img,if=none,id=dp,format=raw" -device virtio-blk-pci,drive=dp,serial=rago-part \
		> "$work/qemu$n.log" 2>&1 &
	qpid=$!
	python3 "$here/m3_serial_agent.py" "$work/serial$n.sock" "$mode" "$work/pass" "$TIMEOUT" "$work/agent$n" || arc=$?
	if [ "$arc" = 10 ]; then
		echo "    passphrase demandée alors que le TPM devait déverrouiller : VM arrêtée"
		kill "$qpid" 2>/dev/null || true
	fi
	wait "$qpid" || echo "    qemu $n : code $? (délai $TIMEOUT s ?)"
	pkill -f "swtpm socket --tpmstate dir=$work/tpm" 2>/dev/null || true
	tr -d '\r' < "$work/serial$n.log" > "$work/serial$n.txt" 2>/dev/null || true
	grep -a 'RAGO-M3 ' "$work/serial$n.txt" || true
	echo "    console : $(cat "$work/agent$n" 2>/dev/null)"
}

done_ok() { grep -aq "RAGO-M3 DONE phase $1" "$work/serial$2.txt" 2>/dev/null; }

# 1. Installateur.
boot 1 "$work/vars-off.fd" "$work/initrd-inst.img" "root=LABEL=rago-inst rw" forbid
if ! { inst_get /export/initrd-a.img "$work/initrd-a.img" && inst_get /export/cmdline-a "$work/cmdline-a"; }; then
	echo "ÉCHEC : l'installateur n'a pas produit l'initramfs du slot A"
	exit 1
fi
mkdir -p "$work/guest"
for f in lsinitrd-a.txt initrd-crypttab-a.txt; do inst_get "/export/$f" "$work/guest/$f" || true; done
debugfs -R "rdump /export/logs-a $work/guest" "$work/inst.img" > /dev/null 2>&1 || true
CMD_A=$(cat "$work/cmdline-a")
echo "    ligne de commande du slot A (kernel.conf de M0, mise à jour par M3) : $CMD_A"

# 2 et 3. Slot A, puis reprise de l'hibernation (même ligne de commande).
boot 2 "$work/vars-off.fd" "$work/initrd-a.img" "$CMD_A" forbid
boot 3 "$work/vars-off.fd" "$work/initrd-a.img" "$CMD_A" forbid
if ! { inst_get /export/initrd-b.img "$work/initrd-b.img" && inst_get /export/cmdline-b "$work/cmdline-b"; }; then
	echo "ÉCHEC : pas d'initramfs pour le slot B"
fi
debugfs -R "rdump /export/logs-b $work/guest" "$work/inst.img" > /dev/null 2>&1 || true

# 4. Slot B.
if [ -s "$work/initrd-b.img" ]; then
	boot 4 "$work/vars-off.fd" "$work/initrd-b.img" "$(cat "$work/cmdline-b")" forbid
fi

# 5 et 6. Secure Boot activé : PCR 7 change.
boot 5 "$work/vars-sb.fd" "$work/initrd-a.img" "$CMD_A" type
boot 6 "$work/vars-sb.fd" "$work/initrd-a.img" "$CMD_A" forbid

# --- bilan ---------------------------------------------------------------------------------
cat "$work"/serial[1-6].txt > "$work/all.log" 2>/dev/null || true
npass=$(grep -ac 'RAGO-M3 PASS' "$work/all.log" || true)
nfail=$(grep -ac 'RAGO-M3 FAIL' "$work/all.log" || true)
hfail=0
# Le démarrage 2 finit en hibernation : sa suite (« phase 3 ») s'affiche au démarrage 3.
for n in 1 3 4 5 6; do
	if done_ok "$n" "$n"; then echo "démarrage $n : fini"; else echo "démarrage $n : NON fini"; hfail=$((hfail + 1)); fi
done
for n in 2 3 4 6; do
	if grep -q '^prompts=0 ' "$work/agent$n" 2>/dev/null; then
		echo "démarrage $n : aucune passphrase demandée (TPM)"
	else
		echo "ÉCHEC démarrage $n : $(cat "$work/agent$n" 2>/dev/null)"; hfail=$((hfail + 1))
	fi
done
if grep -aq 'RAGO-M3 HIBERNATE' "$work/serial2.txt" && ! grep -aq 'RAGO-M3 DONE phase 2' "$work/serial2.txt"; then
	echo "démarrage 2 : hibernation (la VM s'est éteinte pendant la phase 2)"
else
	echo "ÉCHEC démarrage 2 : pas d'hibernation"; hfail=$((hfail + 1))
fi
if grep -q '^prompts=[1-9].* typed=[1-9]' "$work/agent5" 2>/dev/null; then
	echo "démarrage 5 : TPM refusé (PCR 7), passphrase de secours demandée et tapée ($(cat "$work/agent5"))"
else
	echo "ÉCHEC démarrage 5 : la passphrase de secours n'a pas été demandée ($(cat "$work/agent5" 2>/dev/null))"; hfail=$((hfail + 1))
fi
echo "Bilan VM M3 : $npass PASS, $nfail FAIL (invité), $hfail échec(s) (hôte)"
if [ "$nfail" -eq 0 ] && [ "$hfail" -eq 0 ]; then
	echo "RÉUSSI"
	exit 0
fi
echo "ÉCHEC (journaux : relancer avec --keep)"
exit 1
