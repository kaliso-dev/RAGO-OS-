#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test du module M14 dans une VM qemu jetable (pas de matériel réel).
#
# Démarre un vrai système (systemd, tuned) : installe M1 (base, C-states
# shallow tenus par tuned), puis M14 avec daemons/rago-profiled/install.sh
# (service durci, socket root:rago 0660, joueur non root dans le groupe rago),
# et vérifie l'effet réel d'un profil de jeu par-dessus la base de M1, le
# retour exact à la base, le refus d'un utilisateur hors du groupe rago, la
# reprise après un arrêt brutal du service (relancé par systemd), le hook de
# switch, puis la désinstallation. Détail : m14_vm_guest.sh.
#
# Limites : base Ubuntu 24.04 (noyau 6.8, sans sched_ext : pas de M0, donc
# pas de rago-sched-hint), pas de cpufreq dans une VM (gouverneur non
# vérifiable), aucune mesure de FPS.
#
# Usage (root : debootstrap, chroot) :
#   run_m14_vm_test.sh [--rootfs DIR] [--bin FICHIER] [--keep]
#   --rootfs DIR   système de base déjà préparé (sinon construit, ~3 min)
#   --bin FICHIER  rago-profiled à tester (défaut : target/release/rago-profiled)
#   --keep         garde le dossier de travail
#
# Dépendances : debootstrap, qemu-system-x86_64, mkfs.ext4, accès au miroir
# Ubuntu (archive.ubuntu.com). Le binaire doit être compilé pour la même glibc
# que la VM (Ubuntu 24.04 : 2.39) ou plus ancienne.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
rootfs=""
keep=0
bin="$repo/target/release/rago-profiled"
MIRROR=${RAGO_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
TIMEOUT=${RAGO_VM_TIMEOUT:-1500}

while [ $# -gt 0 ]; do
	case "$1" in
	--rootfs) rootfs=$2; shift 2 ;;
	--bin) bin=$2; shift 2 ;;
	--keep) keep=1; shift ;;
	-h | --help) sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (debootstrap, chroot, mkfs)" >&2; exit 2; }
for t in qemu-system-x86_64 mkfs.ext4 debootstrap; do
	command -v "$t" >/dev/null || { echo "outil manquant : $t" >&2; exit 2; }
done
[ -x "$bin" ] || { echo "$bin absent : cargo build --release -p rago-profiled" >&2; exit 2; }

work=$(mktemp -d /var/tmp/rago-m14-vm.XXXXXX)
mounted=""
# shellcheck disable=SC2317,SC2329  # appelée par trap
cleanup() {
	local m
	for m in $mounted; do umount "$m" 2>/dev/null || true; done
	if [ "$keep" = 1 ]; then echo "dossier gardé : $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# --- système de base (mêmes paquets que le test VM de M1) -------------------------------
PKGS="tuned irqbalance systemd-zram-generator power-profiles-daemon linux-image-virtual initramfs-tools python3-dbus python3-gi"
build_rootfs() {
	local d=$1
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
	for m in proc sys dev; do umount "$d/$m"; done
	mounted=""
}
if [ -z "$rootfs" ]; then rootfs="$work/rootfs"; fi
if [ ! -x "$rootfs/usr/sbin/tuned" ]; then build_rootfs "$rootfs"; fi

# --- image de la VM ---------------------------------------------------------------------
img="$work/img"
echo "==> préparation de l'image"
cp -a "$rootfs" "$img"
o="$img/opt/rago"
mkdir -p "$o/daemons/rago-profiled" "$o/bin"
cp -a "$repo/host" "$o/host"
cp -a "$repo/profiles" "$o/profiles"
cp -a "$repo/daemons/rago-profiled/install.sh" "$repo/daemons/rago-profiled/tests" "$o/daemons/rago-profiled/"
install -m 0755 "$bin" "$o/bin/rago-profiled"
echo "/dev/vda / ext4 rw,errors=remount-ro 0 1" > "$img/etc/fstab"
echo rago-m14-vm > "$img/etc/hostname"
rm -rf "$img/var/lib/rago-m14-vm" "$img/var/lib/rago" "$img/etc/rago"
ln -sf /dev/null "$img/etc/systemd/system/serial-getty@ttyS0.service"
cat > "$img/etc/systemd/system/rago-m14-test.service" <<'EOF'
[Unit]
Description=Rago OS : test VM du module M14
After=tuned.service irqbalance.service power-profiles-daemon.service local-fs.target
[Service]
Type=oneshot
ExecStart=/opt/rago/daemons/rago-profiled/tests/vm/m14_vm_guest.sh
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyS0
[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/rago-m14-test.service "$img/etc/systemd/system/multi-user.target.wants/rago-m14-test.service"

kernel=$(find "$img/boot" -name 'vmlinuz-*-generic' | sort -V | tail -1)
initrd="$img/boot/initrd.img-${kernel##*/vmlinuz-}"
cp "$kernel" "$work/vmlinuz"
cp "$initrd" "$work/initrd"
truncate -s 4G "$work/root.img"
mkfs.ext4 -q -F -L rago-root -d "$img" "$work/root.img"
rm -rf "$img"

echo "==> démarrage de la VM (TCG, peut prendre quelques minutes)"
timeout "$TIMEOUT" qemu-system-x86_64 \
	-machine q35 -accel tcg,thread=multi -cpu max -smp 4 -m 2048 \
	-nographic -monitor none -serial "file:$work/serial.log" -no-reboot \
	-kernel "$work/vmlinuz" -initrd "$work/initrd" \
	-append "root=/dev/vda rw console=ttyS0 quiet loglevel=3 systemd.show_status=0" \
	-drive "file=$work/root.img,if=virtio,format=raw" \
	> "$work/qemu.log" 2>&1 || echo "qemu : code $? (délai $TIMEOUT s ?)"
tr -d '\r' < "$work/serial.log" | grep -a 'RAGO-M14 ' || true

npass=$(grep -ac 'RAGO-M14 PASS' "$work/serial.log" || true)
nfail=$(grep -ac 'RAGO-M14 FAIL' "$work/serial.log" || true)
done=$(grep -ac 'RAGO-M14 DONE' "$work/serial.log" || true)
echo "Bilan VM M14 : $npass PASS, $nfail FAIL, $([ "$done" -ge 1 ] && echo "test fini" || echo "test NON fini")"
if [ "$nfail" -eq 0 ] && [ "$done" -ge 1 ] && [ "$npass" -gt 0 ]; then
	echo "RÉUSSI"
	exit 0
fi
echo "ÉCHEC (journaux : relancer avec --keep)"
exit 1
