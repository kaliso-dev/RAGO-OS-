#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test du module M2 dans un conteneur chroot jetable, avec les VRAIS
# paquets d'Ubuntu 25.10 (pas de matériel, pas de VM).
#
# Installe une base Ubuntu « questing » (debootstrap), y copie host/ et
# profiles/, puis lance host/tests/chroot/m2_chroot_guest.sh dans le chroot :
#   - setup_proton_layer.sh deps --enable-32bit (vrai apt : Steam, gamemode,
#     MangoHud, gamescope, polkit), install, verify, user, uninstall, réinstall ;
#   - chaque option produite pour gamescope existe dans gamescope --help ;
#   - rago-session en joueur : commande gamescope, cap_sys_nice vu par le vrai
#     gamescope, environnement de Steam ; gamescope --backend headless essayé
#     (il exige un GPU avec VK_EXT_physical_device_drm : le Vulkan logiciel
#     lavapipe ne l'a pas, la session elle-même reste EN ATTENTE DE MATÉRIEL) ;
#   - vrai polkitd : la règle Rago refuse à gamemode le gouverneur, les cœurs,
#     le GPU et les sysctl (preuve : sans la règle, la même demande passe) ;
#   - vrai gamemoded + vraie chaîne rago-launch -> rago-profiled launch (M14)
#     -> rago-sched-hint run (M0) -> gamemoderun -> mangohud -> jeu factice ;
#   - MangoHud lit /etc/MangoHud.conf (vrai calque Vulkan sur lavapipe).
# Chaque résultat est une ligne « RAGO-M2 PASS|FAIL|INFO ... ».
#
# Limites (EN ATTENTE DE MATÉRIEL) : pas d'écran ni de GPU (VRR, HDR, tearing,
# --rt, FPS non mesurables) ; base Ubuntu et non Arch / base Rago ; pas de
# systemd dans le chroot (service de pré-chauffage non démarré) ; Proton-GE et
# Heroic pas encore épinglés (sources.lock PENDING) ; Steam n'est jamais
# vraiment démarré (il se télécharge au premier lancement).
#
# Usage (root : debootstrap, chroot, mount) :
#   run_m2_chroot_test.sh [--rootfs DIR] [--keep]
#   --rootfs DIR   base Ubuntu 25.10 déjà prête (copiée, pas modifiée) ;
#                  sinon debootstrap (~280 Mo, ~2 min)
#   --keep         garde le dossier de travail
# Les paquets téléchargés font ~1 Go (Steam tire les bibliothèques i386).
# Binaires M14 / M0 : cargo build -p rago-profiled -p rago-sched-hint avant
# (copiés dans le chroot pour la chaîne de lancement ; sinon testée sans eux).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
rootfs=""
keep=0
MIRROR=${RAGO_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
SUITE=${RAGO_UBUNTU_SUITE:-questing}
TIMEOUT=${RAGO_CHROOT_TIMEOUT:-3600}

while [ $# -gt 0 ]; do
	case "$1" in
	--rootfs) rootfs=$2; shift 2 ;;
	--keep) keep=1; shift ;;
	-h | --help) sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (debootstrap, chroot, mount)" >&2; exit 2; }
for t in debootstrap chroot mount umount; do
	command -v "$t" >/dev/null || { echo "outil manquant : $t" >&2; exit 2; }
done

work=$(mktemp -d /var/tmp/rago-m2-chroot.XXXXXX)
R="$work/root"
# shellcheck disable=SC2317  # appelée par trap
cleanup() {
	local p
	# Processus restés dans le chroot (gamemoded, polkitd, dbus).
	for p in /proc/[0-9]*; do
		[ "$(readlink "$p/root" 2>/dev/null)" = "$R" ] && kill -9 "${p#/proc/}" 2>/dev/null
	done
	sleep 1
	umount -R "$R/dev" 2>/dev/null || true
	for m in run dev/shm sys proc; do umount "$R/$m" 2>/dev/null || true; done
	if [ "$keep" = 1 ]; then echo "dossier gardé : $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

if [ -n "$rootfs" ]; then
	[ -x "$rootfs/bin/bash" ] || { echo "$rootfs : pas une base Ubuntu" >&2; exit 2; }
	echo "==> copie de la base $rootfs"
	cp -a "$rootfs" "$R"
else
	echo "==> debootstrap Ubuntu $SUITE dans $R"
	debootstrap --variant=minbase --include=ca-certificates,procps,debconf \
		--components=main,universe,multiverse "$SUITE" "$R" "$MIRROR" > "$work/debootstrap.log" 2>&1 ||
		{ tail -20 "$work/debootstrap.log"; exit 1; }
fi
printf 'deb %s %s main universe multiverse\ndeb %s %s-updates main universe multiverse\n' \
	"$MIRROR" "$SUITE" "$MIRROR" "$SUITE" > "$R/etc/apt/sources.list"
rm -f "$R/etc/apt/sources.list.d/"*.sources 2>/dev/null || true
rm -f "$R/etc/resolv.conf"
cp /etc/resolv.conf "$R/etc/resolv.conf" 2>/dev/null || true
# Pas de services démarrés par les paquets (pas de systemd ici).
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"
chmod +x "$R/usr/sbin/policy-rc.d"

echo "==> copie de host/ et profiles/"
mkdir -p "$R/opt/rago"
cp -a "$repo/host" "$repo/profiles" "$R/opt/rago/"
for b in rago-profiled rago-sched-hint; do
	for d in release debug; do
		if [ -x "$repo/target/$d/$b" ]; then
			install -m 0755 "$repo/target/$d/$b" "$R/usr/local/bin/$b"
			echo "    $b copié depuis target/$d (M14 / M0 s'installent par leurs propres scripts)"
			break
		fi
	done
done

mount -t proc proc "$R/proc"
mount --bind /sys "$R/sys"
mount -o remount,bind,ro "$R/sys" # rien du test ne doit toucher la vraie machine
mount --rbind /dev "$R/dev"
mount --make-rslave "$R/dev"
mount -t tmpfs -o mode=1777 tmpfs "$R/dev/shm"
mount -t tmpfs -o mode=0755 tmpfs "$R/run"
# Un paquet (systemd-resolved) peut faire de resolv.conf un lien vers /run.
mkdir -p "$R/run/systemd/resolve"
cp /etc/resolv.conf "$R/run/systemd/resolve/stub-resolv.conf" 2>/dev/null || true

echo "==> test dans le chroot (journal : $work/guest.log)"
rc=0
timeout "$TIMEOUT" chroot "$R" /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root TERM=dumb LANG=C.UTF-8 bash /opt/rago/host/tests/chroot/m2_chroot_guest.sh \
	> "$work/guest.log" 2>&1 || rc=$?
grep '^RAGO-M2 ' "$work/guest.log" || true
pass=$(grep -c '^RAGO-M2 PASS' "$work/guest.log" || true)
fail=$(grep -c '^RAGO-M2 FAIL' "$work/guest.log" || true)
echo "==> $pass PASS, $fail FAIL (code du script invité : $rc)"
if [ "$fail" -ne 0 ] || ! grep -q '^RAGO-M2 FIN' "$work/guest.log"; then
	echo "==> ÉCHEC — fin du journal :"
	tail -40 "$work/guest.log"
	keep=1
	exit 1
fi
