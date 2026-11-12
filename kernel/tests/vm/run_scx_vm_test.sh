#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test de scx_rago dans une VM qemu jetable (pas de matériel réel).
#
# Charge VRAIMENT scx_rago (vérifieur BPF du noyau, sched_ext actif), lance un
# faux jeu via rago-sched-hint avec des tâches de fond concurrentes et mesure
# où tournent ses threads. Valide la logique BPF ; ne remplace pas le test
# matériel (kernel/tests/m0_hardware_test.sh), car une VM n'a ni X3D ni
# P/E-cores réels : on impose ici un faux X3D (--rago-topo x3d), le socket 0
# de la VM jouant le CCD à cache 3D.
#
# Usage : run_scx_vm_test.sh [--kernel VMLINUZ] [--bin-dir DIR] [--keep]
#   --kernel   noyau avec CONFIG_SCHED_CLASS_EXT=y (défaut : le plus récent de /boot)
#   --bin-dir  dossier contenant scx_rago et rago-sched-hint (défaut : target/release)
#   --keep     garde le dossier de travail
#
# Dépendances : qemu-system-x86_64, busybox (statique), cpio, gzip, gcc.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
kernel=""
bindir="$repo/target/release"
keep=0

while [ $# -gt 0 ]; do
	case "$1" in
	--kernel) kernel=$2; shift 2 ;;
	--bin-dir) bindir=$2; shift 2 ;;
	--keep) keep=1; shift ;;
	-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done

if [ -z "$kernel" ]; then
	kernel=$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sort -V | tail -1)
fi
[ -r "$kernel" ] || { echo "noyau introuvable (--kernel)" >&2; exit 2; }
for b in scx_rago rago-sched-hint; do
	[ -x "$bindir/$b" ] || { echo "$bindir/$b absent : cargo build --release" >&2; exit 2; }
done
for t in qemu-system-x86_64 busybox cpio gzip gcc; do
	command -v "$t" >/dev/null || { echo "outil manquant : $t" >&2; exit 2; }
done

work=$(mktemp -d)
# shellcheck disable=SC2317  # appelée par trap
cleanup() { if [ "$keep" = 1 ]; then echo "dossier gardé : $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT

root="$work/root"
mkdir -p "$root"/{bin,sbin,usr/bin,etc,proc,sys,dev,run,tmp,lib64,lib/x86_64-linux-gnu}

cp "$(command -v busybox)" "$root/bin/busybox"
cp "$bindir/scx_rago" "$bindir/rago-sched-hint" "$root/usr/bin/"
gcc -O2 -pthread -static -o "$root/usr/bin/fake_game" "$here/../fake_game.c" 2>/dev/null
cp "$here/../check_routing.sh" "$root/usr/bin/check_routing.sh"
cp "$here/vm_init.sh" "$root/init"
chmod 0755 "$root/init" "$root/usr/bin/"*

# Bibliothèques dynamiques des binaires Rust.
for b in "$root/usr/bin/scx_rago" "$root/usr/bin/rago-sched-hint"; do
	ldd "$b" | awk '/=>/ {print $3} $1 ~ /^\// {print $1}' | while read -r lib; do
		if [ -z "$lib" ] || [ ! -e "$lib" ]; then continue; fi
		mkdir -p "$root$(dirname "$lib")"
		cp -L "$lib" "$root$lib"
	done
done

# libbpf lit la config du noyau (externs __kconfig) : /boot/config-<version>.
kver=$(basename "$kernel"); kver=${kver#vmlinuz-}
if [ -r "/boot/config-$kver" ]; then
	mkdir -p "$root/boot"
	cp "/boot/config-$kver" "$root/boot/config-$kver"
fi

printf 'root:x:0:0:root:/root:/bin/sh\n' > "$root/etc/passwd"
printf 'root:x:0:\nrago:x:990:\n' > "$root/etc/group"

(cd "$root" && find . | cpio -o -H newc --quiet | gzip -1) > "$work/initrd.gz"

log="$work/console.log"
echo "== Démarrage de la VM ($(basename "$kernel"), 8 vCPU sur 2 sockets, émulation TCG : lent) =="
set +e
timeout 1500 qemu-system-x86_64 \
	-machine q35 -accel tcg,thread=multi -cpu max \
	-smp 8,sockets=2,cores=4,threads=1 -m 2048 \
	-kernel "$kernel" -initrd "$work/initrd.gz" \
	-append "console=ttyS0 panic=-1 rdinit=/init loglevel=4" \
	-nographic -no-reboot -monitor none -serial "file:$log"
rc=$?
set -e
grep -a "RAGO-" "$log" || true
if [ "$keep" = 1 ]; then cp "$log" "$here/last_vm_console.log"; fi

if [ $rc -ne 0 ] && [ $rc -ne 124 ]; then
	echo "qemu a échoué (code $rc)" >&2
fi
if ! grep -aq "RAGO-SUMMARY" "$log"; then
	echo "ÉCHEC : la VM n'a pas terminé le test (voir --keep)" >&2
	tail -50 "$log" >&2
	exit 1
fi
if grep -aq "RAGO-SUMMARY: FAIL" "$log"; then
	exit 1
fi
exit 0
