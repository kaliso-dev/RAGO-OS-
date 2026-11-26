#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test du côté Linux du module M7 (bibliothèque partagée) dans une
# VM qemu jetable.
#
# Ce qui est vrai ici : le noyau Ubuntu et son pilote ntfs3
# (linux-modules-extra), systemd, udev (/dev/disk/by-label), un second disque
# GPT avec RAGO-COMM (FAT32, faite ici) et RAGO-LIB (NTFS, créée dans la VM
# par mkntfs ; ntfs-3g sert seulement à créer et à relire le volume, jamais à
# le monter). On y vérifie les tests de test_library.py en vrai NTFS, le
# montage ntfs3 (lecture seule / écriture selon l'état de Windows écrit sur la
# FAT32 sans Linux), le PARTUUID noté pour Windows, la garde d'hibernation
# sous systemd, la désinstallation. Détail : m7_vm_guest.sh.
#
# Ce qui n'est PAS testé ici : Windows lui-même (agent PowerShell jamais
# exécuté, conteneur Linux), un volume NTFS laissé par un vrai Windows
# (hibernation, démarrage rapide : journal simulé dans test_library.py), une
# vraie hibernation de Linux, le vrai matériel.
#
# Usage (root : debootstrap, chroot) :
#   run_m7_vm_test.sh [--rootfs DIR] [--keep]
#   --rootfs DIR   système de base déjà préparé (complété si besoin : ntfs-3g,
#                  linux-modules-extra ; sinon construit, ~5 min)
#   --keep         garde le dossier de travail
#
# Variable RAGO_UBUNTU_SUITE : noble (défaut) ou questing.
# Dépendances : debootstrap, qemu-system-x86_64, mkfs.ext4, mkfs.vfat, sfdisk,
# accès au miroir Ubuntu (archive.ubuntu.com).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
rootfs=""
keep=0
MIRROR=${RAGO_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
# noble = Ubuntu 24.04 (systemd 255) ; questing = 25.10 (systemd 257, plus proche de la base Arch).
SUITE=${RAGO_UBUNTU_SUITE:-noble}
TIMEOUT=${RAGO_VM_TIMEOUT:-1500}

while [ $# -gt 0 ]; do
	case "$1" in
	--rootfs) rootfs=$2; shift 2 ;;
	--keep) keep=1; shift ;;
	-h | --help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (debootstrap, chroot, mkfs)" >&2; exit 2; }
for t in qemu-system-x86_64 mkfs.ext4 mkfs.vfat sfdisk debootstrap; do
	command -v "$t" >/dev/null || { echo "outil manquant : $t" >&2; exit 2; }
done

work=$(mktemp -d /var/tmp/rago-m7-vm.XXXXXX)
mounted=""
# shellcheck disable=SC2317,SC2329  # appelée par trap
cleanup() {
	local m
	for m in $mounted; do umount "$m" 2>/dev/null || true; done
	if [ "$keep" = 1 ]; then echo "dossier gardé : $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# ntfs-3g : mkntfs (créer RAGO-LIB) et ntfsls / ntfscat (relire sans monter), jamais pour monter.
PKGS="linux-image-virtual initramfs-tools python3 dosfstools mtools util-linux ntfs-3g psmisc"
build_rootfs() {
	local d=$1
	echo "==> debootstrap Ubuntu $SUITE dans $d"
	debootstrap --variant=minbase --include=systemd-sysv,udev,dbus,kmod,procps,iproute2 \
		--components=main,universe "$SUITE" "$d" "$MIRROR" > "$work/debootstrap.log" 2>&1 ||
		{ tail -20 "$work/debootstrap.log"; exit 1; }
	echo "deb $MIRROR $SUITE main universe" > "$d/etc/apt/sources.list"
	cp /etc/resolv.conf "$d/etc/resolv.conf" 2>/dev/null || true
	for m in proc sys dev; do mount --bind "/$m" "$d/$m"; mounted="$d/$m $mounted"; done
	chroot "$d" bash -c "export DEBIAN_FRONTEND=noninteractive
		apt-get update -q && apt-get install -y -q --no-install-recommends $PKGS" > "$work/apt.log" 2>&1 ||
		{ tail -20 "$work/apt.log"; exit 1; }
	for m in proc sys dev; do umount "$d/$m"; done
	mounted=""
}
# ntfs3 est dans linux-modules-extra pour les noyaux Ubuntu (absent du paquet virtual).
complete_rootfs() {
	local d=$1 kver
	kver=$(find "$d/boot" -name 'vmlinuz-*-generic' | sort -V | tail -1)
	kver=${kver##*/vmlinuz-}
	[ -n "$kver" ] || { echo "pas de noyau dans $d/boot" >&2; exit 1; }
	if [ -x "$d/usr/sbin/mkntfs" ] && [ -x "$d/usr/bin/fuser" ] &&
		find "$d/lib/modules/$kver" -name 'ntfs3.ko*' | grep -q .; then
		return 0
	fi
	echo "==> ajout de ntfs-3g, psmisc, linux-modules-extra-$kver"
	cp /etc/resolv.conf "$d/etc/resolv.conf" 2>/dev/null || true
	for m in proc sys dev; do mount --bind "/$m" "$d/$m"; mounted="$d/$m $mounted"; done
	chroot "$d" bash -c "export DEBIAN_FRONTEND=noninteractive
		apt-get update -q && apt-get install -y -q --no-install-recommends ntfs-3g psmisc mtools dosfstools linux-modules-extra-$kver" \
		> "$work/apt-extra.log" 2>&1 || { tail -20 "$work/apt-extra.log"; exit 1; }
	for m in proc sys dev; do umount "$d/$m"; done
	mounted=""
	find "$d/lib/modules/$kver" -name 'ntfs3.ko*' | grep -q . || { echo "ntfs3.ko absent après installation" >&2; exit 1; }
}
if [ -z "$rootfs" ]; then rootfs="$work/rootfs"; fi
if [ ! -x "$rootfs/usr/bin/mtype" ] || [ ! -x "$rootfs/usr/bin/python3" ]; then build_rootfs "$rootfs"; fi
complete_rootfs "$rootfs"

# --- image de la VM ---------------------------------------------------------------------
img="$work/img"
echo "==> préparation de l'image"
cp -a "$rootfs" "$img"
o="$img/opt/rago"
mkdir -p "$o"
cp -a "$repo/host" "$o/host"
cp -a "$repo/windows" "$o/windows"
find "$o" -name __pycache__ -prune -exec rm -rf {} +
echo "/dev/vda / ext4 rw,errors=remount-ro 0 1" > "$img/etc/fstab"
echo rago-m7-vm > "$img/etc/hostname"
rm -rf "$img/var/lib/rago" "$img/etc/rago"
ln -sf /dev/null "$img/etc/systemd/system/serial-getty@ttyS0.service"
cat > "$img/etc/systemd/system/rago-m7-test.service" <<'EOF'
[Unit]
Description=Rago OS : test VM du module M7 (côté Linux)
After=local-fs.target systemd-udev-settle.service
[Service]
Type=oneshot
ExecStart=/opt/rago/host/tests/vm/m7_vm_guest.sh
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyS0
[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/rago-m7-test.service "$img/etc/systemd/system/multi-user.target.wants/rago-m7-test.service"

kernel=$(find "$img/boot" -name 'vmlinuz-*-generic' | sort -V | tail -1)
initrd="$img/boot/initrd.img-${kernel##*/vmlinuz-}"
cp "$kernel" "$work/vmlinuz"
cp "$initrd" "$work/initrd"
truncate -s 4G "$work/root.img"
mkfs.ext4 -q -F -L rago-root -d "$img" "$work/root.img"
rm -rf "$img"

# --- second disque : GPT, RAGO-COMM (basic data, FAT32) + RAGO-LIB (basic data, vide) ------
# RAGO-LIB : formatée en NTFS dans la VM (mkntfs), pas d'outil NTFS sur l'hôte.
echo "==> disque RAGO-COMM + RAGO-LIB (GPT, basic data)"
truncate -s 1G "$work/comm.img"
printf 'label: gpt\nstart=2048, size=131072, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="RAGO-COMM"\nstart=133120, size=1048576, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="RAGO-LIB"\n' |
	sfdisk -q "$work/comm.img"
mkfs.vfat -F 32 -n RAGO-COMM --offset=2048 "$work/comm.img" $((131072 / 2)) > /dev/null

echo "==> démarrage de la VM (TCG, peut prendre quelques minutes)"
timeout "$TIMEOUT" qemu-system-x86_64 \
	-machine q35 -accel tcg,thread=multi -cpu max -smp 4 -m 2048 \
	-nographic -monitor none -serial "file:$work/serial.log" -no-reboot \
	-kernel "$work/vmlinuz" -initrd "$work/initrd" \
	-append "root=/dev/vda rw console=ttyS0 quiet loglevel=3 systemd.show_status=0" \
	-drive "file=$work/root.img,if=virtio,format=raw" \
	-drive "file=$work/comm.img,if=virtio,format=raw" \
	> "$work/qemu.log" 2>&1 || echo "qemu : code $? (délai $TIMEOUT s ?)"
tr -d '\r' < "$work/serial.log" | grep -a 'RAGO-M7 ' || true

npass=$(grep -ac 'RAGO-M7 PASS' "$work/serial.log" || true)
nfail=$(grep -ac 'RAGO-M7 FAIL' "$work/serial.log" || true)
done=$(grep -ac 'RAGO-M7 DONE' "$work/serial.log" || true)
echo "Bilan VM M7 : $npass PASS, $nfail FAIL, $([ "$done" -ge 1 ] && echo "test fini" || echo "test NON fini")"
if [ "$nfail" -eq 0 ] && [ "$done" -ge 1 ] && [ "$npass" -gt 0 ]; then
	echo "RÉUSSI"
	exit 0
fi
echo "ÉCHEC (journaux : relancer avec --keep)"
exit 1
