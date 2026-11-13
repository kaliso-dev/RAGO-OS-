#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test du module M1 dans une VM qemu jetable (pas de matériel réel).
#
# Démarre un vrai système (systemd, udev, tuned, irqbalance, zram-generator,
# power-profiles-daemon) avec un vrai disque NVMe, un SSD SATA et un disque dur
# SATA émulés, y lance host/setup_host_tuning.sh et vérifie l'effet réel, puis
# redémarre avec threadirqs pour vérifier que tout revient au démarrage.
# Détail des vérifications : host/tests/vm/m1_vm_guest.sh.
#
# Limites : base Ubuntu 24.04 (tuned 2.21) et non Arch / base Rago ; pas de
# cpufreq dans une VM (gouverneur non vérifiable) ; aucune mesure de FPS.
# Le test matériel reste : setup_host_tuning.sh verify + tests/m1_frametime_compare.sh.
#
# Usage (root : debootstrap, chroot) :
#   run_m1_vm_test.sh [--rootfs DIR] [--keep]
#   --rootfs DIR   système de base déjà préparé (sinon construit dans DIR ou
#                  dans le dossier de travail ; ~830 Mo, ~3 min)
#   --keep         garde le dossier de travail
#
# Dépendances : debootstrap, qemu-system-x86_64, mkfs.ext4, accès au miroir
# Ubuntu (archive.ubuntu.com).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hostdir=$(cd "$here/../.." && pwd)
rootfs=""
keep=0
MIRROR=${RAGO_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
TIMEOUT=${RAGO_VM_TIMEOUT:-1200}

while [ $# -gt 0 ]; do
	case "$1" in
	--rootfs) rootfs=$2; shift 2 ;;
	--keep) keep=1; shift ;;
	-h | --help) sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (debootstrap, chroot, mkfs)" >&2; exit 2; }
for t in qemu-system-x86_64 mkfs.ext4 debootstrap; do
	command -v "$t" >/dev/null || { echo "outil manquant : $t" >&2; exit 2; }
done

work=$(mktemp -d /var/tmp/rago-m1-vm.XXXXXX)
mounted=""
# shellcheck disable=SC2317  # appelée par trap
cleanup() {
	local m
	for m in $mounted; do umount "$m" 2>/dev/null || true; done
	if [ "$keep" = 1 ]; then echo "dossier gardé : $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# --- système de base ---------------------------------------------------------------------
PKGS="tuned irqbalance systemd-zram-generator power-profiles-daemon linux-image-virtual initramfs-tools python3-dbus python3-gi"
build_rootfs() {
	local d=$1 k
	echo "==> debootstrap Ubuntu 24.04 dans $d"
	debootstrap --variant=minbase --include=systemd-sysv,udev,dbus,libpam-systemd,kmod,procps,iproute2 \
		--components=main,universe noble "$d" "$MIRROR" > "$work/debootstrap.log" 2>&1 ||
		{ tail -20 "$work/debootstrap.log"; exit 1; }
	echo "deb $MIRROR noble main universe" > "$d/etc/apt/sources.list"
	cp /etc/resolv.conf "$d/etc/resolv.conf" 2>/dev/null || true
	for m in proc sys dev; do mount --bind "/$m" "$d/$m"; mounted="$d/$m $mounted"; done
	chroot "$d" bash -c "export DEBIAN_FRONTEND=noninteractive
		apt-get update -q && apt-get install -y -q --no-install-recommends $PKGS" > "$work/apt.log" 2>&1 ||
		{ tail -20 "$work/apt.log"; exit 1; }
	k=$(basename "$(find "$d/boot" -name 'vmlinuz-*-generic' | sort -V | tail -1)")
	k=${k#vmlinuz-}
	# zram, bfq : dans linux-modules-extra.
	chroot "$d" bash -c "export DEBIAN_FRONTEND=noninteractive
		apt-get install -y -q --no-install-recommends linux-modules-extra-$k" >> "$work/apt.log" 2>&1 ||
		{ tail -20 "$work/apt.log"; exit 1; }
	for m in proc sys dev; do umount "$d/$m"; done
	mounted=""
}

if [ -z "$rootfs" ]; then rootfs="$work/rootfs"; fi
if [ ! -x "$rootfs/usr/sbin/tuned" ]; then build_rootfs "$rootfs"; fi

# --- image de la VM ---------------------------------------------------------------------
img="$work/img"
echo "==> préparation de l'image"
cp -a "$rootfs" "$img"
mkdir -p "$img/opt/rago-m1"
cp -a "$hostdir" "$img/opt/rago-m1/host"
echo "/dev/vda / ext4 rw,errors=remount-ro 0 1" > "$img/etc/fstab"
echo rago-m1-vm > "$img/etc/hostname"
rm -rf "$img/var/lib/rago-m1-vm" "$img/var/lib/rago" "$img/etc/rago"
ln -sf /dev/null "$img/etc/systemd/system/serial-getty@ttyS0.service"
cat > "$img/etc/systemd/system/rago-m1-test.service" <<'EOF'
[Unit]
Description=Rago OS : test VM du module M1
After=tuned.service irqbalance.service power-profiles-daemon.service systemd-udev-settle.service local-fs.target
[Service]
Type=oneshot
ExecStart=/opt/rago-m1/host/tests/vm/m1_vm_guest.sh
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyS0
[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/rago-m1-test.service "$img/etc/systemd/system/multi-user.target.wants/rago-m1-test.service"

kernel=$(find "$img/boot" -name 'vmlinuz-*-generic' | sort -V | tail -1)
initrd="$img/boot/initrd.img-${kernel##*/vmlinuz-}"
cp "$kernel" "$work/vmlinuz"
cp "$initrd" "$work/initrd"

truncate -s 4G "$work/root.img"
mkfs.ext4 -q -F -L rago-root -d "$img" "$work/root.img"
rm -rf "$img"
truncate -s 256M "$work/nvme.img" "$work/ssd.img" "$work/hdd.img"

boot() { # boot <n> <paramètres noyau en plus>
	local n=$1 extra=$2
	echo "==> démarrage $n de la VM (TCG, peut prendre quelques minutes)"
	timeout "$TIMEOUT" qemu-system-x86_64 \
		-machine q35 -accel tcg,thread=multi -cpu max -smp 4 -m 2048 \
		-nographic -monitor none -serial "file:$work/serial$n.log" -no-reboot \
		-kernel "$work/vmlinuz" -initrd "$work/initrd" \
		-append "root=/dev/vda rw console=ttyS0 quiet loglevel=3 systemd.show_status=0 $extra" \
		-drive "file=$work/root.img,if=virtio,format=raw" \
		-drive "file=$work/nvme.img,if=none,id=nv,format=raw" -device nvme,serial=rago0,drive=nv \
		-device ahci,id=ahci \
		-drive "file=$work/ssd.img,if=none,id=ssd,format=raw" -device ide-hd,drive=ssd,bus=ahci.0,rotation_rate=1 \
		-drive "file=$work/hdd.img,if=none,id=hdd,format=raw" -device ide-hd,drive=hdd,bus=ahci.1,rotation_rate=7200 \
		> "$work/qemu$n.log" 2>&1 || echo "qemu $n : code $? (délai $TIMEOUT s ?)"
	grep -a 'RAGO-M1 ' "$work/serial$n.log" | tr -d '\r' || true
}

# Étape 1 : démarrage normal. Étape 2 : avec ce que M1 a mis dans kernel.conf
# (M0 l'ajouterait à l'entrée systemd-boot).
boot 1 ""
boot 2 "threadirqs zswap.enabled=0"

cat "$work"/serial1.log "$work"/serial2.log | tr -d '\r' > "$work/all.log"
npass=$(grep -ac 'RAGO-M1 PASS' "$work/all.log" || true)
nfail=$(grep -ac 'RAGO-M1 FAIL' "$work/all.log" || true)
done1=$(grep -ac 'RAGO-M1 DONE étape 1' "$work/all.log" || true)
done2=$(grep -ac 'RAGO-M1 DONE étape 2' "$work/all.log" || true)
echo "Bilan VM M1 : $npass PASS, $nfail FAIL, étape 1 $([ "$done1" -ge 1 ] && echo finie || echo NON finie), étape 2 $([ "$done2" -ge 1 ] && echo finie || echo NON finie)"
if [ "$nfail" -eq 0 ] && [ "$done1" -ge 1 ] && [ "$done2" -ge 1 ]; then
	echo "RÉUSSI"
	exit 0
fi
echo "ÉCHEC (journaux : relancer avec --keep)"
exit 1
