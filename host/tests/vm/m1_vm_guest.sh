#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — partie « invité » du test VM du module M1.
#
# Tourne dans la VM (service rago-m1-test, sortie sur /dev/ttyS0), lancé par
# host/tests/vm/run_m1_vm_test.sh. Deux démarrages :
#   étape 1 : install, vérifications réelles (tuned, sysctl, udev, zram,
#             irqbalance, C-states), changements d'options, uninstall complet
#             (retour à l'état d'avant), réinstallation, arrêt ;
#   étape 2 : redémarré avec threadirqs (comme le ferait l'entrée systemd-boot
#             de M0) : tout doit être revenu tout seul au démarrage, verify = 0.
# Chaque résultat est une ligne « RAGO-M1 PASS|FAIL|INFO ... ».
set -u

SETUP=/opt/rago-m1/host/setup_host_tuning.sh
ST=/var/lib/rago-m1-vm
KCONF=/etc/rago/kernel.conf
mkdir -p "$ST"
stage=$(cat "$ST/stage" 2>/dev/null || echo 1)

say()   { echo "RAGO-M1 $*"; }
check() { # check <nom> <attendu> <obtenu>
	if [ "$2" = "$3" ]; then say "PASS $1 ($3)"; else say "FAIL $1 : attendu « $2 », obtenu « $3 »"; fi
}
check_true() { # check_true <nom> <commande...>
	local n=$1
	shift
	if "$@"; then say "PASS $n"; else say "FAIL $n"; fi
}
show() { sed 's/^/RAGO-M1 LOG /'; }
sched() { sed 's/.*\[\(.*\)\].*/\1/' "/sys/block/$1/queue/scheduler"; }
sysc() { tr -s '\t ' ' ' < "/proc/sys/${1//.//}"; }
tuned_now() { tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: //p'; }
dma_latency() { od -An -t d4 -N4 /dev/cpu_dma_latency | tr -d ' '; }
zram_swaps() { grep -c '^/dev/zram' /proc/swaps; }
active() { if systemctl is-active -q "$1"; then echo actif; else echo inactif; fi; }

# Attente : tuned répond et udev a fini.
for _ in $(seq 1 180); do
	tuned-adm active >/dev/null 2>&1 && break
	sleep 1
done
udevadm settle --timeout=60
sleep 3

say "INFO étape $stage, noyau $(uname -r), ligne de commande : $(cat /proc/cmdline)"
for d in vda nvme0n1 sda sdb; do
	[ -e "/sys/block/$d" ] && say "INFO disque $d : rotational=$(cat /sys/block/$d/queue/rotational) ordonnanceur=$(cat /sys/block/$d/queue/scheduler)"
done

if [ "$stage" = 1 ]; then
	# --- état d'origine ------------------------------------------------------------------
	# power-profiles-daemon lancé d'abord s'il ne l'est pas : M1 doit l'arrêter puis le
	# remettre. Sur Ubuntu il arrête tuned (Conflicts=) : l'état d'origine est pris après.
	if ! systemctl is-active -q power-profiles-daemon && systemctl cat power-profiles-daemon >/dev/null 2>&1; then
		systemctl start power-profiles-daemon
		sleep 2
		say "INFO power-profiles-daemon lancé pour le test : $(active power-profiles-daemon)"
	fi
	b_tuned=$(cat /etc/tuned/active_profile); b_tuned_on=$(active tuned)
	b_nvme=$(sched nvme0n1); b_sda=$(sched sda); b_sdb=$(sched sdb)
	b_map=$(sysc vm.max_map_count); b_swap=$(sysc vm.swappiness); b_qdisc=$(sysc net.core.default_qdisc)
	b_ppd=$(active power-profiles-daemon); b_irqb=$(active irqbalance); b_zram=$(zram_swaps)
	b_zswap=$(cat /sys/module/zswap/parameters/enabled)
	say "INFO avant : tuned=$b_tuned ($b_tuned_on) nvme=$b_nvme sda=$b_sda sdb=$b_sdb max_map_count=$b_map swappiness=$b_swap qdisc=$b_qdisc ppd=$b_ppd irqbalance=$b_irqb zram=$b_zram zswap=$b_zswap"

	# kernel.conf comme l'écrit M0 (build_rago_kernel.sh write_default_conf).
	mkdir -p /etc/rago
	cat > "$KCONF" <<-'EOF'
	# Rago OS — options de démarrage du noyau Rago (lu par build_rago_kernel.sh).
	RAGO_CMDLINE="root=/dev/vda rw"
	RAGO_MITIGATIONS=auto
	RAGO_CMDLINE_EXTRA=""
	RAGO_ESP=/boot
	EOF
	cp "$KCONF" "$ST/kernel.conf.orig"

	# --- installation --------------------------------------------------------------------
	"$SETUP" install > "$ST/install.log" 2>&1
	check "install : code retour" 0 $?
	show < "$ST/install.log"
	"$SETUP" verify > "$ST/verify.log" 2>&1
	check "verify : seulement redémarrage en attente (threadirqs)" 3 $?
	show < "$ST/verify.log"

	check "tuned-adm active" rago-gaming "$(tuned_now)"
	check_true "tuned-adm verify" tuned-adm verify
	check "THP" madvise "$(sed 's/.*\[\(.*\)\].*/\1/' /sys/kernel/mm/transparent_hugepage/enabled)"
	check "vm.max_map_count" 2147483642 "$(sysc vm.max_map_count)"
	check "vm.swappiness" 10 "$(sysc vm.swappiness)"
	check "vm.page-cluster" 0 "$(sysc vm.page-cluster)"
	check "vm.stat_interval (tuned)" 60 "$(sysc vm.stat_interval)"
	check "kernel.watchdog (tuned)" 0 "$(sysc kernel.watchdog)"
	check "net.core.default_qdisc" fq_codel "$(sysc net.core.default_qdisc)"
	check "net.core.rmem_max" 16777216 "$(sysc net.core.rmem_max)"
	check "net.ipv4.tcp_rmem" "4096 1048576 16777216" "$(sysc net.ipv4.tcp_rmem)"
	check "E/S nvme0n1 (NVMe)" none "$(sched nvme0n1)"
	check "E/S sda (SSD SATA)" mq-deadline "$(sched sda)"
	check "E/S sdb (HDD)" bfq "$(sched sdb)"
	check "swap zram" 1 "$(zram_swaps)"
	check "priorité zram" 100 "$(awk '/^\/dev\/zram0/ {print $5}' /proc/swaps)"
	check "zswap coupé" N "$(cat /sys/module/zswap/parameters/enabled)"
	check "irqbalance" actif "$(active irqbalance)"
	check "power-profiles-daemon arrêté" inactif "$(active power-profiles-daemon)"
	check "C-states deep : cpu_dma_latency" 2000000000 "$(dma_latency)"
	check "kernel.conf : jetons M1" 'RAGO_CMDLINE_EXTRA="threadirqs zswap.enabled=0"' "$(grep '^RAGO_CMDLINE_EXTRA=' "$KCONF")"

	# --- options -------------------------------------------------------------------------
	"$SETUP" install --cstates shallow > "$ST/o.log" 2>&1
	check "install --cstates shallow" 0 $?
	v=$(dma_latency)
	check_true "C-states shallow : 0 < cpu_dma_latency ($v) < 2000000000" test "$v" -gt 0 -a "$v" -lt 2000000000
	"$SETUP" install --cstates poll > "$ST/o.log" 2>&1
	check "C-states poll : cpu_dma_latency" 0 "$(dma_latency)"
	"$SETUP" install --cstates deep --nvme-scheduler mq-deadline > "$ST/o.log" 2>&1
	check "C-states deep à nouveau" 2000000000 "$(dma_latency)"
	check "E/S nvme0n1 --nvme-scheduler mq-deadline" mq-deadline "$(sched nvme0n1)"
	"$SETUP" install --nvme-scheduler none --irq-ban 0 > "$ST/o.log" 2>&1
	check "E/S nvme0n1 retour à none" none "$(sched nvme0n1)"
	check "irqbalance : CPU 0 évité" "IRQBALANCE_BANNED_CPULIST=0" "$(systemctl show -p Environment --value irqbalance)"
	check "irqbalance relancé" actif "$(active irqbalance)"
	"$SETUP" install --irq-ban none > "$ST/o.log" 2>&1

	# --- désinstallation : retour à l'état d'origine ---------------------------------------
	"$SETUP" uninstall > "$ST/uninstall.log" 2>&1
	check "uninstall : code retour" 0 $?
	show < "$ST/uninstall.log"
	check "uninstall : profil tuned d'origine" "$b_tuned" "$(cat /etc/tuned/active_profile)"
	check "uninstall : service tuned comme avant" "$b_tuned_on" "$(active tuned)"
	check "uninstall : nvme0n1" "$b_nvme" "$(sched nvme0n1)"
	check "uninstall : sda" "$b_sda" "$(sched sda)"
	check "uninstall : sdb" "$b_sdb" "$(sched sdb)"
	check "uninstall : max_map_count" "$b_map" "$(sysc vm.max_map_count)"
	check "uninstall : swappiness" "$b_swap" "$(sysc vm.swappiness)"
	check "uninstall : qdisc" "$b_qdisc" "$(sysc net.core.default_qdisc)"
	check "uninstall : zram" "$b_zram" "$(zram_swaps)"
	check "uninstall : zswap" "$b_zswap" "$(cat /sys/module/zswap/parameters/enabled)"
	check "uninstall : power-profiles-daemon" "$b_ppd" "$(active power-profiles-daemon)"
	check_true "uninstall : kernel.conf d'origine" cmp -s "$ST/kernel.conf.orig" "$KCONF"
	left=$(grep -rls rago-host-tuning /etc 2>/dev/null | tr '\n' ' ')
	check "uninstall : aucun fichier Rago dans /etc" "" "$left"

	# --- réinstallation pour l'étape 2 ------------------------------------------------------
	"$SETUP" install > "$ST/install2.log" 2>&1
	check "réinstallation" 0 $?
	echo 2 > "$ST/stage"
	sync
	say "DONE étape 1"
	systemctl poweroff
	exit 0
fi

if [ "$stage" = 2 ]; then
	"$SETUP" verify > "$ST/verify2.log" 2>&1
	check "verify après redémarrage : tout actif" 0 $?
	show < "$ST/verify2.log"
	check "tuned au démarrage" rago-gaming "$(tuned_now)"
	check "E/S nvme0n1 au démarrage (udev)" none "$(sched nvme0n1)"
	check "E/S sda au démarrage (udev)" mq-deadline "$(sched sda)"
	check "E/S sdb au démarrage (udev)" bfq "$(sched sdb)"
	check "max_map_count au démarrage" 2147483642 "$(sysc vm.max_map_count)"
	check "zram au démarrage" 1 "$(zram_swaps)"
	check "zswap coupé au démarrage" N "$(cat /sys/module/zswap/parameters/enabled)"
	check "power-profiles-daemon reste arrêté" inactif "$(active power-profiles-daemon)"
	n_irq=$(pgrep -c '^irq/' || true)
	check_true "threadirqs : threads d'IRQ présents ($n_irq)" test "$n_irq" -gt 0
	check "pas de CPU isolé" "" "$(cat /sys/devices/system/cpu/isolated)"
	check "pas de nohz_full" "" "$(sed 's/^(null)$//' /sys/devices/system/cpu/nohz_full 2>/dev/null)"
	"$SETUP" uninstall > "$ST/uninstall2.log" 2>&1
	check "uninstall final" 0 $?
	echo 3 > "$ST/stage"
	sync
	say "DONE étape 2"
	systemctl poweroff
	exit 0
fi

say "INFO rien à faire (étape $stage)"
systemctl poweroff
