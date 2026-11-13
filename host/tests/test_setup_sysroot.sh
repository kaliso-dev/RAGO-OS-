#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests de host/setup_host_tuning.sh dans une fausse racine (M1).
#
# Sans root, sans matériel, sans toucher au système : fausse racine (--root),
# faux /sys et faux /proc (RAGO_SYSFS, RAGO_PROCFS) et commandes systemctl,
# tuned-adm, udevadm factices qui simulent les services. Vérifie :
# installation, sauvegarde / restauration des fichiers existants, édition de
# /etc/rago/kernel.conf, idempotence, changement d'options, application,
# verify (y compris qu'il détecte un réglage perdu), désinstallation complète.
#
# Usage : host/tests/test_setup_sysroot.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
setup="$here/../setup_host_tuning.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
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
yes_if() { if "$@"; then echo oui; else echo non; fi; }

# --- fausse machine ---------------------------------------------------------------------------
make_machine() {
	rm -rf "$T/root" "$T/sys" "$T/proc" "$T/units" "$T/calls" "$T/tuned-profile"
	R="$T/root" S="$T/sys" P="$T/proc" U="$T/units"
	mkdir -p "$R/etc/tuned" "$R/usr/lib/tuned/profiles" "$R/etc/rago" "$R/etc/sysctl.d" \
		"$R/usr/lib/systemd/system-generators" "$U"
	printf '#!/bin/sh\n' > "$R/usr/lib/systemd/system-generators/zram-generator"
	chmod +x "$R/usr/lib/systemd/system-generators/zram-generator"
	cat > "$R/etc/rago/kernel.conf" <<-'EOF'
	# Rago OS — options de démarrage du noyau Rago (lu par build_rago_kernel.sh).
	RAGO_CMDLINE="root=UUID=1234 rw quiet"
	RAGO_MITIGATIONS=auto
	RAGO_CMDLINE_EXTRA=""
	RAGO_ESP=/boot
	EOF
	cp "$R/etc/rago/kernel.conf" "$T/kernel.conf.orig"
	# Un 99-rago.conf de l'utilisateur, à sauvegarder puis restaurer.
	echo "vm.swappiness = 60 # à moi" > "$R/etc/sysctl.d/99-rago.conf"

	mk() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
	mk "$S/block/nvme0n1/queue/scheduler" "[none] mq-deadline kyber bfq"
	mk "$S/block/nvme0n1/queue/rotational" 0
	mk "$S/block/sda/queue/scheduler" "none [mq-deadline] kyber bfq"
	mk "$S/block/sda/queue/rotational" 0
	mk "$S/block/sdb/queue/scheduler" "none [mq-deadline] kyber bfq"
	mk "$S/block/sdb/queue/rotational" 1
	mk "$S/block/zram0/queue/scheduler" "none"
	mk "$S/block/zram0/queue/rotational" 0
	for c in 0 1 2 3; do mk "$S/devices/system/cpu/cpu$c/cpufreq/scaling_governor" powersave; done
	mk "$S/kernel/mm/transparent_hugepage/enabled" "always [madvise] never"
	mk "$S/module/zswap/parameters/enabled" Y

	mk "$P/sys/vm/max_map_count" 65530
	mk "$P/sys/vm/swappiness" 60
	mk "$P/sys/vm/page-cluster" 3
	mk "$P/sys/vm/stat_interval" 1
	mk "$P/sys/kernel/watchdog" 1
	mk "$P/sys/net/core/rmem_default" 212992
	mk "$P/sys/net/core/rmem_max" 212992
	mk "$P/sys/net/core/wmem_default" 212992
	mk "$P/sys/net/core/wmem_max" 212992
	mk "$P/sys/net/ipv4/tcp_rmem" $'4096\t131072\t6291456'
	mk "$P/sys/net/ipv4/tcp_wmem" $'4096\t16384\t4194304'
	mk "$P/sys/net/ipv4/udp_rmem_min" 4096
	mk "$P/sys/net/ipv4/udp_wmem_min" 4096
	mk "$P/sys/net/core/default_qdisc" pfifo_fast
	# kernel.split_lock_mitigate absent : CPU sans détection (clé facultative).
	mk "$P/cmdline" "root=UUID=1234 rw quiet"
	printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$P/swaps"

	# Services présents ; actifs au départ : power-profiles-daemon.
	for u in tuned irqbalance power-profiles-daemon systemd-sysctl; do touch "$U/$u.exists"; done
	touch "$U/power-profiles-daemon.active" "$U/power-profiles-daemon.enabled"
	echo balanced > "$T/tuned-profile"
	export RAGO_SYSFS=$S RAGO_PROCFS=$P RAGO_TEST_ROOT=$R RAGO_TEST_UNITS=$U \
		RAGO_TEST_CALLS="$T/calls" RAGO_TEST_TUNED="$T/tuned-profile"
}

# --- commandes factices -------------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# systemctl factice : état des unités dans $RAGO_TEST_UNITS/<nom>.{exists,active,enabled}
echo "systemctl $*" >> "$RAGO_TEST_CALLS"
U=$RAGO_TEST_UNITS; S=$RAGO_SYSFS; P=$RAGO_PROCFS; R=$RAGO_TEST_ROOT
q=0; now=0; args=()
for a in "$@"; do
	case "$a" in -q | --quiet) q=1 ;; --now) now=1 ;; *) args+=("$a") ;; esac
done
verb=${args[0]:-}; unit=${args[1]:-}; unit=${unit%.service}
apply_unit() {
	case "$1" in
	systemd-sysctl)
		# Applique /etc/sysctl.d/99-rago.conf de la fausse racine.
		grep -Ev '^[[:space:]]*($|#)' "$R/etc/sysctl.d/99-rago.conf" 2>/dev/null | while IFS='=' read -r k v; do
			k=$(echo $k); v=$(echo $v); opt=0
			case "$k" in -*) opt=1; k=${k#-} ;; esac
			f="$P/sys/${k//.//}"
			if [ -e "$f" ]; then echo "$v" > "$f"; elif [ "$opt" = 0 ]; then echo "clé inconnue $k" >&2; fi
		done ;;
	systemd-zram-setup@zram0)
		grep -q zram0 "$P/swaps" || printf '/dev/zram0\tpartition\t4194300\t0\t100\n' >> "$P/swaps" ;;
	tuned)
		# Le daemon réapplique le profil courant.
		if [ "$(cat "$RAGO_TEST_TUNED")" = rago-gaming ]; then tuned-adm profile rago-gaming --quiet-stub; fi ;;
	esac
}
case "$verb" in
cat) [ -e "$U/$unit.exists" ] ;;
is-active) [ -e "$U/$unit.active" ] ;;
is-enabled) [ -e "$U/$unit.enabled" ] ;;
daemon-reload) : ;;
enable) touch "$U/$unit.enabled"; [ "$now" = 1 ] && { touch "$U/$unit.active"; apply_unit "$unit"; }; : ;;
disable) rm -f "$U/$unit.enabled"; [ "$now" = 1 ] && rm -f "$U/$unit.active"; : ;;
start | restart) touch "$U/$unit.active"; apply_unit "$unit" ;;
stop)
	rm -f "$U/$unit.active"
	[ "$unit" = systemd-zram-setup@zram0 ] && sed -i '/zram0/d' "$P/swaps"; : ;;
*) echo "systemctl factice : verbe inconnu $verb" >&2; exit 1 ;;
esac
EOF
cat > "$T/bin/tuned-adm" <<'EOF'
#!/usr/bin/env bash
# tuned-adm factice : profil courant dans $RAGO_TEST_TUNED ; « profile rago-gaming »
# simule les effets du profil (gouverneur, THP, sysctl de tuned).
[ "${2:-}" = --quiet-stub ] || echo "tuned-adm $*" >> "$RAGO_TEST_CALLS"
S=$RAGO_SYSFS; P=$RAGO_PROCFS
case "$1" in
active)
	if [ -e "$RAGO_TEST_TUNED.down" ]; then echo "Cannot talk to TuneD daemon via DBus." >&2; exit 1; fi
	p=$(cat "$RAGO_TEST_TUNED")
	if [ -n "$p" ]; then echo "Current active profile: $p"; else echo "No current active profile."; fi ;;
profile)
	echo "$2" > "$RAGO_TEST_TUNED"
	if [ "$2" = rago-gaming ]; then
		for f in "$S"/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f"; done
		echo "always [madvise] never" > "$S/kernel/mm/transparent_hugepage/enabled"
		echo 60 > "$P/sys/vm/stat_interval"; echo 0 > "$P/sys/kernel/watchdog"
	else
		for f in "$S"/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo powersave > "$f"; done
		echo 1 > "$P/sys/vm/stat_interval"; echo 1 > "$P/sys/kernel/watchdog"
	fi ;;
off) : > "$RAGO_TEST_TUNED" ;;
verify) [ "$(cat "$RAGO_TEST_TUNED")" = rago-gaming ] ;;
*) exit 1 ;;
esac
EOF
cat > "$T/bin/udevadm" <<'EOF'
#!/usr/bin/env bash
# udevadm factice : « trigger » applique la règle installée (NVMe : valeur de la règle).
echo "udevadm $*" >> "$RAGO_TEST_CALLS"
S=$RAGO_SYSFS; rules="$RAGO_TEST_ROOT/etc/udev/rules.d/60-rago-iosched.rules"
setq() { local f="$S/block/$1/queue/scheduler" l; l=$(sed 's/[][]//g' "$f"); echo "$l" | sed "s/\b$2\b/[$2]/" > "$f"; }
case "$1" in
trigger)
	[ -f "$rules" ] || exit 0
	nv=$(sed -n 's/.*nvme.*ATTR{queue\/scheduler}="\([^"]*\)".*/\1/p' "$rules")
	for d in "$S"/block/*; do
		n=${d##*/}; rot=$(cat "$d/queue/rotational")
		case "$n" in
		nvme*) setq "$n" "$nv" ;;
		sd*) if [ "$rot" = 0 ]; then setq "$n" mq-deadline; else setq "$n" bfq; fi ;;
		esac
	done ;;
*) : ;;
esac
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

run_setup() { "$setup" --root "$T/root" "$@" > "$T/out" 2>&1; }

# =========================== 1. fichiers seuls (--root) ===========================
make_machine
run_setup install
check "install --root : code" 0 $?
check "profil tuned (tuned >= 2.23)" oui "$(yes_if test -f "$R/etc/tuned/profiles/rago-gaming/tuned.conf")"
check "profil = celui du dépôt" oui "$(yes_if cmp -s "$here/../tuned/rago-gaming/tuned.conf" "$R/etc/tuned/profiles/rago-gaming/tuned.conf")"
check "variables : deep" "rago_force_latency=None" "$(grep '^rago_force_latency=' "$R/etc/tuned/rago-gaming-variables.conf")"
check "sysctl = celui du dépôt" oui "$(yes_if cmp -s "$here/../sysctl.d/99-rago.conf" "$R/etc/sysctl.d/99-rago.conf")"
check "sysctl utilisateur sauvegardé" "vm.swappiness = 60 # à moi" "$(cat "$R/var/lib/rago/host-tuning/backup/etc%sysctl.d%99-rago.conf")"
check "udev : NVMe none" 1 "$(grep -c 'KERNEL=="nvme\[0-9\]\*n\[0-9\]\*", ATTR{queue/scheduler}="none"' "$R/etc/udev/rules.d/60-rago-iosched.rules")"
check "udev : plus de @NVME_SCHED@" 0 "$(grep -c '@NVME_SCHED@' "$R/etc/udev/rules.d/60-rago-iosched.rules")"
check "zram installé" oui "$(yes_if test -f "$R/etc/systemd/zram-generator.conf.d/rago.conf")"
check "pas de drop-in irqbalance par défaut" non "$(yes_if test -e "$R/etc/systemd/system/irqbalance.service.d/rago.conf")"
check "kernel.conf : jetons" "threadirqs zswap.enabled=0" "$(grep '^RAGO_CMDLINE_EXTRA=' "$R/etc/rago/kernel.conf" | cut -d'"' -f2)"
check "kernel.conf : reste intact" "$(grep -v EXTRA "$T/kernel.conf.orig")" "$(grep -v EXTRA "$R/etc/rago/kernel.conf")"
check "host-tuning.conf écrit" deep "$(sed -n 's/^RAGO_CSTATES="\(.*\)"$/\1/p' "$R/etc/rago/host-tuning.conf")"
check "rien appliqué (--root)" non "$(yes_if test -s "$T/calls")"

# Idempotence.
snap() { (cd "$R" && find . -type f ! -path './var/*' -print0 | sort -z | xargs -0 sha256sum); }
snap > "$T/snap1"
run_setup install
snap > "$T/snap2"
check "2e install identique" oui "$(yes_if cmp -s "$T/snap1" "$T/snap2")"
check "manifeste sans doublon" "$(sort -u "$R/var/lib/rago/host-tuning/manifest" | wc -l)" "$(wc -l < "$R/var/lib/rago/host-tuning/manifest")"

# Changement d'options, puis mémorisation.
run_setup install --cstates shallow --nvme-scheduler mq-deadline --no-zram --irq-ban 0-1
check "options : code" 0 $?
check "variables : shallow" "rago_force_latency=cstate.id_no_zero:1|3" "$(grep '^rago_force_latency=' "$R/etc/tuned/rago-gaming-variables.conf")"
check "udev : NVMe mq-deadline" 1 "$(grep -c 'nvme.*scheduler}="mq-deadline"' "$R/etc/udev/rules.d/60-rago-iosched.rules")"
check "zram retiré" non "$(yes_if test -e "$R/etc/systemd/zram-generator.conf.d/rago.conf")"
check "kernel.conf : zswap retiré, threadirqs gardé" "threadirqs" "$(grep '^RAGO_CMDLINE_EXTRA=' "$R/etc/rago/kernel.conf" | cut -d'"' -f2)"
check "irqbalance : CPU évités" "Environment=IRQBALANCE_BANNED_CPULIST=0-1" "$(grep '^Environment' "$R/etc/systemd/system/irqbalance.service.d/rago.conf")"
run_setup install
check "options mémorisées" "rago_force_latency=cstate.id_no_zero:1|3" "$(grep '^rago_force_latency=' "$R/etc/tuned/rago-gaming-variables.conf")"
run_setup install --cstates deep --nvme-scheduler none --zram --irq-ban none
check "retour aux défauts : drop-in irqbalance retiré" non "$(yes_if test -e "$R/etc/systemd/system/irqbalance.service.d/rago.conf")"
check "retour aux défauts : jetons" "threadirqs zswap.enabled=0" "$(grep '^RAGO_CMDLINE_EXTRA=' "$R/etc/rago/kernel.conf" | cut -d'"' -f2)"

# Options invalides : refusées, rien d'écrit.
for bad in "--cstates turbo" "--nvme-scheduler bfq" "--irq-ban 7-3" "--irq-ban abc" "--frobnicate"; do
	snap > "$T/snapA"
	# shellcheck disable=SC2086  # découpage voulu
	run_setup install $bad
	rc=$?
	snap > "$T/snapB"
	check "refus de « $bad »" "1 oui" "$rc $(yes_if cmp -s "$T/snapA" "$T/snapB")"
done

# --dry-run : rien ne change.
snap > "$T/snapA"
run_setup --dry-run install --cstates poll
snap > "$T/snapB"
check "dry-run : rien d'écrit" oui "$(yes_if cmp -s "$T/snapA" "$T/snapB")"
check "dry-run : annonce les écritures" oui "$(yes_if grep -q '^\[dry-run\] écrire' "$T/out")"

# Désinstallation (fichiers).
run_setup uninstall
check "uninstall : code" 0 $?
check "sysctl utilisateur restauré" "vm.swappiness = 60 # à moi" "$(cat "$R/etc/sysctl.d/99-rago.conf")"
check "kernel.conf identique à l'origine" oui "$(yes_if cmp -s "$T/kernel.conf.orig" "$R/etc/rago/kernel.conf")"
check "plus aucun fichier Rago" "" "$(grep -rl rago-host-tuning "$R/etc" 2>/dev/null)"
check "état retiré" non "$(yes_if test -e "$R/var/lib/rago/host-tuning")"
check "profil tuned retiré" non "$(yes_if test -e "$R/etc/tuned/profiles/rago-gaming")"
run_setup uninstall
check "2e uninstall : rien à faire" 0 $?

# Jeton déjà présent avant Rago : jamais retiré.
make_machine
sed -i 's/^RAGO_CMDLINE_EXTRA=""/RAGO_CMDLINE_EXTRA="threadirqs"/' "$R/etc/rago/kernel.conf"
cp "$R/etc/rago/kernel.conf" "$T/kernel.conf.orig"
run_setup install
check "jeton existant + ajout" "threadirqs zswap.enabled=0" "$(grep '^RAGO_CMDLINE_EXTRA=' "$R/etc/rago/kernel.conf" | cut -d'"' -f2)"
run_setup install --no-threadirqs
check "--no-threadirqs ne retire pas un jeton de l'utilisateur" "threadirqs zswap.enabled=0" "$(grep '^RAGO_CMDLINE_EXTRA=' "$R/etc/rago/kernel.conf" | cut -d'"' -f2)"
run_setup uninstall
check "uninstall garde le jeton de l'utilisateur" oui "$(yes_if cmp -s "$T/kernel.conf.orig" "$R/etc/rago/kernel.conf")"

# Sans noyau Rago (pas de kernel.conf) : avertit, ne crée rien.
make_machine
rm "$R/etc/rago/kernel.conf"
run_setup install
check "sans kernel.conf : code" 0 $?
check "sans kernel.conf : pas créé" non "$(yes_if test -e "$R/etc/rago/kernel.conf")"
check "sans kernel.conf : avertissement" oui "$(yes_if grep -q 'kernel.conf absent' "$T/out")"

# Ancien tuned (pas de /usr/lib/tuned/profiles) : profil dans /etc/tuned.
make_machine
rm -r "$R/usr/lib/tuned"
run_setup install
check "tuned ancien : /etc/tuned/rago-gaming" oui "$(yes_if test -f "$R/etc/tuned/rago-gaming/tuned.conf")"
run_setup uninstall
check "tuned ancien : retiré" non "$(yes_if test -e "$R/etc/tuned/rago-gaming")"

# =========================== 2. application simulée ===========================
make_machine
export RAGO_TEST_APPLY=1
run_setup install
check "install appliqué : code" 0 $?
check "ppd arrêté" non "$(yes_if test -e "$U/power-profiles-daemon.active")"
check "tuned actif, profil rago-gaming" "oui rago-gaming" "$(yes_if test -e "$U/tuned.active") $(cat "$T/tuned-profile")"
check "irqbalance activé" oui "$(yes_if test -e "$U/irqbalance.active")"
check "profil précédent mémorisé" balanced "$(cat "$R/var/lib/rago/host-tuning/previous-tuned-profile")"
check "sysctl appliqué" 2147483642 "$(cat "$P/sys/vm/max_map_count")"
check "E/S : HDD bfq" bfq "$(sed 's/.*\[\(.*\)\].*/\1/' "$S/block/sdb/queue/scheduler")"
check "zram actif" 1 "$(grep -c '^/dev/zram0' "$P/swaps")"
check "zswap coupé" N "$(cat "$S/module/zswap/parameters/enabled")"
RAGO_VERIFY_LIVE=1 "$setup" --root "$R" verify > "$T/verify" 2>&1
check "verify : redémarrage en attente (threadirqs)" 3 $?
check "verify : 0 échec" oui "$(yes_if grep -q ' 0 échec' "$T/verify")"
check "verify : C-states ignorés (faux /sys)" oui "$(yes_if grep -q 'IGNORÉ.*C-states' "$T/verify")"
check "verify : split_lock facultatif ignoré" oui "$(yes_if grep -q 'IGNORÉ.*split_lock' "$T/verify")"

echo "root=UUID=1234 rw quiet threadirqs zswap.enabled=0" > "$P/cmdline"
RAGO_VERIFY_LIVE=1 "$setup" --root "$R" verify > "$T/verify" 2>&1
check "verify après redémarrage : tout OK" 0 $?

echo powersave > "$S/devices/system/cpu/cpu2/cpufreq/scaling_governor"
RAGO_VERIFY_LIVE=1 "$setup" --root "$R" verify > "$T/verify" 2>&1
check "verify détecte un gouverneur perdu" 1 $?
check "verify nomme le CPU" oui "$(yes_if grep -q 'cpu2=powersave' "$T/verify")"
echo performance > "$S/devices/system/cpu/cpu2/cpufreq/scaling_governor"

echo 65530 > "$P/sys/vm/max_map_count"
RAGO_VERIFY_LIVE=1 "$setup" --root "$R" verify > "$T/verify" 2>&1
check "verify détecte un sysctl perdu" 1 $?
echo 2147483642 > "$P/sys/vm/max_map_count"

echo "root=UUID=1234 rw threadirqs zswap.enabled=0 isolcpus=2-3" > "$P/cmdline"
RAGO_VERIFY_LIVE=1 "$setup" --root "$R" verify > "$T/verify" 2>&1
check "verify signale une isolation de cœurs" oui "$(yes_if grep -q 'ATTENTION.*isolcpus=2-3' "$T/verify")"
echo "root=UUID=1234 rw quiet threadirqs zswap.enabled=0" > "$P/cmdline"

touch "$U/power-profiles-daemon.active"
RAGO_VERIFY_LIVE=1 "$setup" --root "$R" verify > "$T/verify" 2>&1
check "verify détecte power-profiles-daemon" 1 $?
rm "$U/power-profiles-daemon.active"

# Réinstallation : ne réécrase pas l'état d'origine mémorisé.
run_setup install --nvme-scheduler mq-deadline
check "réinstall : NVMe mq-deadline appliqué" mq-deadline "$(sed 's/.*\[\(.*\)\].*/\1/' "$S/block/nvme0n1/queue/scheduler")"
check "réinstall : profil d'origine gardé" balanced "$(cat "$R/var/lib/rago/host-tuning/previous-tuned-profile")"
check "réinstall : sysctl d'origine gardés" "vm.max_map_count	65530" "$(grep max_map_count "$R/var/lib/rago/host-tuning/sysctl-before")"

run_setup uninstall
check "uninstall appliqué : code" 0 $?
check "tuned revenu à balanced" balanced "$(cat "$T/tuned-profile")"
check "tuned désactivé comme avant" non "$(yes_if test -e "$U/tuned.enabled")"
check "ppd remis en marche" oui "$(yes_if test -e "$U/power-profiles-daemon.active")"
check "irqbalance désactivé comme avant" non "$(yes_if test -e "$U/irqbalance.enabled")"
check "sysctl remis : max_map_count" 65530 "$(cat "$P/sys/vm/max_map_count")"
check "sysctl remis : tcp_rmem" "4096 131072 6291456" "$(cat "$P/sys/net/ipv4/tcp_rmem")"
check "sysctl remis : qdisc" pfifo_fast "$(cat "$P/sys/net/core/default_qdisc")"
check "E/S remises : HDD" mq-deadline "$(sed 's/.*\[\(.*\)\].*/\1/' "$S/block/sdb/queue/scheduler")"
check "E/S remises : NVMe" none "$(sed 's/.*\[\(.*\)\].*/\1/' "$S/block/nvme0n1/queue/scheduler")"
check "zram arrêté" 0 "$(grep -c '^/dev/zram0' "$P/swaps")"
check "zswap remis" Y "$(cat "$S/module/zswap/parameters/enabled")"
check "sysctl utilisateur restauré" "vm.swappiness = 60 # à moi" "$(cat "$R/etc/sysctl.d/99-rago.conf")"

# Daemon tuned arrêté (par power-profiles-daemon) : profil lu dans active_profile.
make_machine
touch "$T/tuned-profile.down"
echo virtual-guest > "$R/etc/tuned/active_profile"
run_setup install
rm -f "$T/tuned-profile.down"
check "daemon arrêté : profil d'origine lu dans active_profile" virtual-guest "$(cat "$R/var/lib/rago/host-tuning/previous-tuned-profile")"
check "daemon arrêté : état « inactif » mémorisé" 0 "$(cat "$R/var/lib/rago/host-tuning/tuned-was-active")"
touch "$U/tuned.enabled"  # était activé mais arrêté
echo 1 > "$R/var/lib/rago/host-tuning/tuned-was-enabled"
run_setup uninstall
check "daemon arrêté : profil d'origine remis" virtual-guest "$(cat "$T/tuned-profile")"
check "daemon arrêté : tuned de nouveau arrêté" non "$(yes_if test -e "$U/tuned.active")"
check "daemon arrêté : tuned toujours activé" oui "$(yes_if test -e "$U/tuned.enabled")"

# tuned absent : install refuse proprement.
make_machine
mv "$T/bin/tuned-adm" "$T/tuned-adm.off"
PATH="$T/bin:/usr/bin:/bin" run_setup install
check "sans tuned-adm : refus" 1 $?
check "sans tuned-adm : message deps" oui "$(yes_if grep -q 'outils manquants.*tuned-adm' "$T/out")"
mv "$T/tuned-adm.off" "$T/bin/tuned-adm"
unset RAGO_TEST_APPLY

printf '%d tests OK, %d échec(s)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
