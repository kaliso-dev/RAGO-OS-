#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests unitaires de host/lib/rago_host_lib.sh (module M1).
# Sans root, sans matériel. Usage : host/tests/test_host_lib.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib/rago_host_lib.sh
. "$here/../lib/rago_host_lib.sh"

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

# --- C-states -------------------------------------------------------------------------
check "deep" "None" "$(rago_cstates_latency deep)"
check "shallow" "cstate.id_no_zero:1|3" "$(rago_cstates_latency shallow)"
check "poll" "0" "$(rago_cstates_latency poll)"
check_rc "mode inconnu" 2 rago_cstates_latency turbo
check_rc "deep : défaut noyau" 0 rago_cstates_check deep 2000000000
check_rc "deep : limite posée" 1 rago_cstates_check deep 1
check_rc "shallow : C1" 0 rago_cstates_check shallow 1
check_rc "shallow : sans limite" 1 rago_cstates_check shallow 2000000000
check_rc "poll : 0" 0 rago_cstates_check poll 0
check_rc "poll : 1" 1 rago_cstates_check poll 1
check_rc "valeur vide" 2 rago_cstates_check deep ""

check_rc "nvme none" 0 rago_valid_nvme_sched none
check_rc "nvme mq-deadline" 0 rago_valid_nvme_sched mq-deadline
check_rc "nvme bfq refusé" 1 rago_valid_nvme_sched bfq

# --- dossier des profils tuned ------------------------------------------------------------
mkdir -p "$tmp/r1/etc/tuned" "$tmp/r2/usr/lib/tuned/profiles" "$tmp/r3/etc/tuned"
check "tuned ancien" /etc/tuned "$(rago_tuned_profile_dir "$tmp/r1")"
check "tuned >= 2.23" /etc/tuned/profiles "$(rago_tuned_profile_dir "$tmp/r2")"
check "racine /" /etc/tuned/profiles "$(rago_tuned_profile_dir "$tmp/r2/")"
printf '# x\nprofile_dirs = /usr/lib/tuned/profiles,/etc/tuned/mes-profils\n' > "$tmp/r3/etc/tuned/tuned-main.conf"
check "profile_dirs" /etc/tuned/mes-profils "$(rago_tuned_profile_dir "$tmp/r3")"
printf 'profile_dirs=/usr/lib/tuned\n' > "$tmp/r3/etc/tuned/tuned-main.conf"
check "profile_dirs sans /etc" /etc/tuned "$(rago_tuned_profile_dir "$tmp/r3")"

check "tuned-adm active" rago-gaming "$(printf 'Current active profile: rago-gaming\nOther\n' | rago_tuned_active_from_output)"
check "tuned-adm sans profil" "" "$(printf 'No current active profile.\n' | rago_tuned_active_from_output)"

# --- fichiers KEY=valeur -------------------------------------------------------------------
cat > "$tmp/k.conf" <<'EOF'
# commentaire RAGO_CMDLINE_EXTRA="piège"
RAGO_CMDLINE="root=UUID=abc rw quiet"
RAGO_MITIGATIONS=auto
RAGO_CMDLINE_EXTRA=""
RAGO_ESP=/boot
EOF
chmod 0640 "$tmp/k.conf"
check "conf_get" "root=UUID=abc rw quiet" "$(rago_conf_get "$tmp/k.conf" RAGO_CMDLINE)"
check "conf_get sans guillemets" auto "$(rago_conf_get "$tmp/k.conf" RAGO_MITIGATIONS)"
check "conf_get absent -> défaut" x "$(rago_conf_get "$tmp/k.conf" NOPE x)"
check "conf_get fichier absent" d "$(rago_conf_get "$tmp/none.conf" K d)"
rago_conf_set "$tmp/k.conf" RAGO_CMDLINE_EXTRA "threadirqs zswap.enabled=0"
check "conf_set remplace" "threadirqs zswap.enabled=0" "$(rago_conf_get "$tmp/k.conf" RAGO_CMDLINE_EXTRA)"
check "conf_set garde le reste" 5 "$(wc -l < "$tmp/k.conf")"
check "conf_set garde le commentaire" '# commentaire RAGO_CMDLINE_EXTRA="piège"' "$(head -1 "$tmp/k.conf")"
check "conf_set garde les droits" 640 "$(stat -c %a "$tmp/k.conf")"
rago_conf_set "$tmp/k.conf" NOUVELLE "1"
check "conf_set ajoute" 1 "$(rago_conf_get "$tmp/k.conf" NOUVELLE)"
rago_conf_set "$tmp/neuf.conf" A "b c"
check "conf_set crée" 'A="b c"' "$(cat "$tmp/neuf.conf")"
check_rc "conf_set refuse un guillemet" 2 rago_conf_set "$tmp/k.conf" X 'a"b'
check "pas de fichier temporaire laissé" 0 "$(find "$tmp" -name 'k.conf.*' | wc -l)"

# --- ligne de commande ----------------------------------------------------------------------
check_rc "has" 0 rago_cmdline_has "quiet threadirqs rw" threadirqs
check_rc "has : pas de sous-chaîne" 1 rago_cmdline_has "nothreadirqs" threadirqs
check "add" "quiet threadirqs zswap.enabled=0" "$(rago_cmdline_add "quiet" threadirqs zswap.enabled=0)"
check "add sans doublon" "threadirqs quiet" "$(rago_cmdline_add "threadirqs quiet" threadirqs)"
check "add sur vide" "threadirqs" "$(rago_cmdline_add "" threadirqs)"
check "remove" "quiet rw" "$(rago_cmdline_remove "quiet threadirqs rw threadirqs" threadirqs)"
check "remove plusieurs" "" "$(rago_cmdline_remove "threadirqs zswap.enabled=0" threadirqs zswap.enabled=0)"
check "isolation" "isolcpus=2-7 nohz_full=2-7" "$(rago_cmdline_isolation "root=/dev/x isolcpus=2-7 quiet nohz_full=2-7")"
check "pas d'isolation" "" "$(rago_cmdline_isolation "root=/dev/x threadirqs")"

# --- ordonnanceur d'E/S ----------------------------------------------------------------------
check "sched courant" mq-deadline "$(rago_sched_current "none [mq-deadline] kyber bfq")"
check "sched none" none "$(rago_sched_current "[none] mq-deadline")"
check_rc "sched sans crochets" 1 rago_sched_current "none mq-deadline"
check_rc "bfq dispo" 0 rago_sched_available "none [mq-deadline] kyber bfq" bfq
check_rc "courant dispo" 0 rago_sched_available "none [mq-deadline]" mq-deadline
check_rc "bfq absent" 1 rago_sched_available "[none] mq-deadline" bfq

check "nvme -> choix" none "$(rago_expected_sched nvme0n1 0 none)"
check "nvme -> mq-deadline" mq-deadline "$(rago_expected_sched nvme1n2 0 mq-deadline)"
check_rc "partition nvme ignorée" 1 rago_expected_sched nvme0n1p2 0 none
check "ssd sata" mq-deadline "$(rago_expected_sched sda 0 none)"
check "hdd" bfq "$(rago_expected_sched sdb 1 none)"
check "emmc" mq-deadline "$(rago_expected_sched mmcblk0 0 none)"
check "virtio ssd" mq-deadline "$(rago_expected_sched vda 0 none)"
check_rc "virtio rotatif ignoré" 1 rago_expected_sched vda 1 none
check_rc "partition sata ignorée" 1 rago_expected_sched sda1 0 none
check_rc "partition emmc ignorée" 1 rago_expected_sched mmcblk0p1 0 none
check_rc "emmc boot ignorée" 1 rago_expected_sched mmcblk0boot0 0 none
check_rc "zram ignoré" 1 rago_expected_sched zram0 0 none
check_rc "loop ignoré" 1 rago_expected_sched loop0 0 none
check_rc "dm ignoré" 1 rago_expected_sched dm-0 0 none

# --- listes de CPU ---------------------------------------------------------------------------
for l in 0 0-7 0-7,16-23 3,5,7; do check_rc "cpulist $l" 0 rago_cpulist_valid "$l"; done
for l in "" a 7-3 0- -3 0,,1 ,1 "1," "0 1" 0-1-2; do check_rc "cpulist invalide '$l'" 1 rago_cpulist_valid "$l"; done

# --- sysctl ----------------------------------------------------------------------------------
cat > "$tmp/s.conf" <<'EOF'
# commentaire
; autre commentaire

vm.swappiness = 10
net.ipv4.tcp_rmem =   4096	1048576   16777216
-kernel.split_lock_mitigate=0
net/core/default_qdisc = fq_codel
EOF
check "sysctl entrées" "$(printf 'vm.swappiness\t10\t0\nnet.ipv4.tcp_rmem\t4096 1048576 16777216\t0\nkernel.split_lock_mitigate\t0\t1\nnet/core/default_qdisc\tfq_codel\t0')" "$(rago_sysctl_entries "$tmp/s.conf")"
check "sysctl chemin" net/ipv4/tcp_rmem "$(rago_sysctl_path net.ipv4.tcp_rmem)"
check "sysctl chemin avec /" net/core/default_qdisc "$(rago_sysctl_path net/core/default_qdisc)"
check "norm_ws" "4096 87380 6291456" "$(rago_norm_ws "$(printf '4096\t87380\t6291456')")"

# Le vrai fichier du dépôt : chaque clé obligatoire existe-t-elle sur ce noyau ?
while IFS=$'\t' read -r k _ opt; do
	if [ "$opt" = 0 ]; then
		check_rc "clé $k connue du noyau courant" 0 test -e "/proc/sys/$(rago_sysctl_path "$k")"
	fi
done < <(rago_sysctl_entries "$here/../sysctl.d/99-rago.conf")
check "99-rago.conf : 13 réglages" 13 "$(rago_sysctl_entries "$here/../sysctl.d/99-rago.conf" | wc -l)"

# --- temps de trame --------------------------------------------------------------------------
# 1000 trames : 990 à 10 ms (100 FPS), 9 à 20 ms, 1 à 50 ms.
{
	echo "os,cpu,gpu,ram,kernel,driver,cpuscheduler"
	echo "Arch,Ryzen,RX,32GB,6.18,mesa,scx_rago"
	echo "fps,frametime,cpu_load,gpu_load,elapsed"
	for i in $(seq 1 990); do echo "100,10.0,50,90,$i"; done
	for i in $(seq 1 9); do echo "50,20.0,50,90,$i"; done
	echo "20,50.0,50,90,1000"
} > "$tmp/mh.csv"
# moyenne = 1000 trames / (9900 + 180 + 50) ms = 98.7 FPS ;
# 1 % low = 10e plus long = 20 ms -> 50 FPS ; 0,1 % low = le plus long = 50 ms -> 20 FPS.
check "frametime stats" "1000 98.7 50.0 20.0" "$(rago_frametime_stats "$tmp/mh.csv")"
printf 'fps,frametime\n' > "$tmp/court.csv"
for i in $(seq 1 50); do echo "100,10" >> "$tmp/court.csv"; done
check_rc "trop court" 1 rago_frametime_stats "$tmp/court.csv"
printf 'fps,elapsed\n1,2\n' > "$tmp/sans.csv"
check_rc "sans colonne frametime" 1 rago_frametime_stats "$tmp/sans.csv"
# Colonne frametime pas en 2e position, espaces autour du nom.
{
	echo "fps, cpu_load , frametime"
	for i in $(seq 1 200); do echo "60,10,16.0"; done
} > "$tmp/ordre.csv"
check "frametime colonne 3" "200 62.5 62.5 62.5" "$(rago_frametime_stats "$tmp/ordre.csv")"
check "delta +" "+10.0" "$(rago_pct_delta 50 55)"
check "delta -" "-2.0" "$(rago_pct_delta 100 98)"
check_rc "delta base 0" 1 rago_pct_delta 0 5

# Outil de comparaison (critère matériel « 1 % low »).
cmp_tool="$here/m1_frametime_compare.sh"
{ echo "fps,frametime"; for i in $(seq 1 1000); do echo "100,10"; done; for i in $(seq 1 20); do echo "40,25"; done; } > "$tmp/avant.csv"
{ echo "fps,frametime"; for i in $(seq 1 1000); do echo "100,10"; done; for i in $(seq 1 20); do echo "55,18"; done; } > "$tmp/apres.csv"
check_rc "comparaison : mieux après" 0 "$cmp_tool" "$tmp/avant.csv" "$tmp/apres.csv"
check_rc "comparaison : régression" 1 "$cmp_tool" "$tmp/apres.csv" "$tmp/avant.csv"
check_rc "comparaison : régression tolérée à 30 %" 0 "$cmp_tool" --tolerance 30 "$tmp/apres.csv" "$tmp/avant.csv"
check_rc "comparaison : journal illisible" 2 "$cmp_tool" "$tmp/avant.csv" "$tmp/sans.csv"
check "comparaison : 1 % low affiché" "1 % low            40.0       55.6     +39.0%" "$("$cmp_tool" "$tmp/avant.csv" "$tmp/apres.csv" | grep '^1 % low')"

printf '%d tests OK, %d échec(s)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
