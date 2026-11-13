#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — M14 : rago-profiled contre le VRAI noyau (root).
#
# Vérifie sur le noyau qui tourne (VM, conteneur microVM ou machine) ce que la
# fausse racine des tests Rust ne peut pas prouver :
#   - THP réellement changé puis remis (/sys/kernel/mm/transparent_hugepage) ;
#   - C-states : demande PM QoS réelle sur /dev/cpu_dma_latency, valeur
#     effective lue pendant le jeu, et retirée à la fin ;
#   - une demande déjà tenue par quelqu'un d'autre (comme tuned / M1) reste :
#     le noyau garde la plus stricte, un profil n'ajoute qu'une limite ;
#   - démon tué en plein jeu : le noyau retire SEUL la demande PM QoS, et le
#     démon relancé remet THP ;
#   - jeu sans profil : rien ne bouge.
# Le gouverneur est vérifié seulement si cpufreq existe (pas en VM).
#
# ATTENTION : change THP et les C-states de la machine pendant quelques
# secondes, puis remet tout. À lancer en root :
#   cargo build -p rago-profiled && sudo daemons/rago-profiled/tests/real_kernel_test.sh [--bin FICHIER]
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
bin="$repo/target/debug/rago-profiled"
[ "${1:-}" = "--bin" ] && bin=$2

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (écrit dans /sys, ouvre /dev/cpu_dma_latency)" >&2; exit 2; }
[ -x "$bin" ] || { echo "$bin absent : cargo build -p rago-profiled" >&2; exit 2; }
THP=/sys/kernel/mm/transparent_hugepage/enabled
QOS=/dev/cpu_dma_latency
[ -w "$THP" ] || { echo "$THP absent ou non modifiable : test impossible ici" >&2; exit 2; }
[ -c "$QOS" ] || { echo "$QOS absent : test impossible ici" >&2; exit 2; }

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS $*"; }
ko() { fail=$((fail + 1)); echo "FAIL $*"; }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else ko "$1 : attendu « $3 », obtenu « $2 »"; fi; }
thp() { sed -n 's/.*\[\(.*\)\].*/\1/p' "$THP"; }
qos() { od -An -t d4 -N4 "$QOS" | tr -d ' '; }

w=$(mktemp -d /tmp/rago-m14-real.XXXXXX)
chmod 0755 "$w"
mkdir -p "$w/profiles" "$w/run" "$w/hooks" "$w/out"
chmod 0755 "$w/hooks"
thp0=$(thp)
qos0=$(qos)
dpid=""
holder=""
cleanup() {
	[ -n "$dpid" ] && kill "$dpid" 2>/dev/null && wait "$dpid" 2>/dev/null
	[ -n "$holder" ] && kill "$holder" 2>/dev/null
	echo "$thp0" > "$THP" 2>/dev/null
	rm -rf "$w"
}
trap cleanup EXIT

cat > "$w/profiles/reel-poll.toml" <<'EOF'
schema = 1
id = "reel-poll"
name = "Test noyau : always + poll"
couche = "proton"
cpu_governor = "performance"
thp = "always"
cstates = "poll"
EOF
cat > "$w/profiles/reel-shallow.toml" <<'EOF'
schema = 1
id = "reel-shallow"
name = "Test noyau : shallow"
couche = "proton"
cstates = "shallow"
EOF
cat > "$w/profiles/reel-deep.toml" <<'EOF'
schema = 1
id = "reel-deep"
name = "Test noyau : deep"
couche = "proton"
cstates = "deep"
EOF

start_daemon() {
	"$bin" --socket "$w/run/p.sock" --profiles-dir "$w/profiles" daemon --group "" \
		--state-dir "$w/run" --hooks-dir "$w/hooks" >> "$w/out/daemon.log" 2>&1 &
	dpid=$!
	for _ in $(seq 100); do [ -S "$w/run/p.sock" ] && return 0; sleep 0.05; done
	echo "le démon ne démarre pas :" >&2
	cat "$w/out/daemon.log" >&2
	exit 1
}
P() { "$bin" --socket "$w/run/p.sock" --profiles-dir "$w/profiles" "$@"; }
# Jeu factice : relève THP et la latence PM QoS effective pendant qu'il tourne.
game() { printf '%s' "sh -c 'sed -n \"s/.*\\[\\(.*\\)\\].*/\\1/p\" $THP > $w/out/thp; od -An -t d4 -N4 $QOS | tr -d \" \" > $w/out/qos; $1'"; }
run_game() { # <id> <fin du script>
	eval "P launch --id $1 --no-sched-hint -- $(game "$2")" 2>> "$w/out/launch.log"
}

echo "== base : THP $thp0, latence PM QoS $qos0 µs"
start_daemon

echo "== 1. profil always + poll"
run_game reel-poll true
check "THP pendant le jeu" "$(cat "$w/out/thp")" always
check "latence effective pendant le jeu (poll)" "$(cat "$w/out/qos")" 0
check "THP après le jeu" "$(thp)" "$thp0"
check "latence après le jeu" "$(qos)" "$qos0"
if [ -e "$w/run/applied.json" ]; then ko "fichier d'état resté"; else ok "fichier d'état supprimé"; fi
if [ -d /sys/devices/system/cpu/cpufreq/policy0 ]; then
	g=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)
	ok "cpufreq présent (gouverneur après le jeu : $g)"
else
	ok "cpufreq absent ici : gouverneur non vérifiable (attendu en VM)"
fi

echo "== 2. profil shallow : latence de l'état C1 (repli 3 µs)"
c1=$(cat /sys/devices/system/cpu/cpu0/cpuidle/state1/latency 2>/dev/null || echo 0)
[ "$c1" -gt 0 ] 2>/dev/null || c1=3
run_game reel-shallow true
check "latence effective pendant le jeu (shallow)" "$(cat "$w/out/qos")" "$c1"
check "latence après le jeu" "$(qos)" "$qos0"

echo "== 3. une demande déjà tenue (comme tuned / M1 en shallow) reste la plus stricte"
python3 -c "
import os, struct, time, sys
fd = os.open('$QOS', os.O_WRONLY); os.write(fd, struct.pack('i', 5))
open('$w/out/holder-ready', 'w').close()
time.sleep(60)
" &
holder=$!
for _ in $(seq 100); do [ -e "$w/out/holder-ready" ] && break; sleep 0.05; done
check "base tenue par un autre (5 µs)" "$(qos)" 5
run_game reel-deep true
check "profil deep : la base plus stricte reste" "$(cat "$w/out/qos")" 5
run_game reel-poll true
check "profil poll : la limite du jeu s'ajoute" "$(cat "$w/out/qos")" 0
check "après le jeu : la base de l'autre est intacte" "$(qos)" 5
kill "$holder"; wait "$holder" 2>/dev/null; holder=""
check "base de l'autre retirée" "$(qos)" "$qos0"

echo "== 4. démon tué en plein jeu"
eval "P launch --id reel-poll --no-sched-hint -- $(game 'exec sleep 30')" 2>> "$w/out/launch.log" &
lpid=$!
for _ in $(seq 200); do [ "$(thp)" = always ] && [ "$(qos)" = 0 ] && break; sleep 0.05; done
check "profil appliqué" "$(thp)/$(qos)" "always/0"
kill -9 "$dpid"; wait "$dpid" 2>/dev/null; dpid=""
sleep 0.2
check "PM QoS retirée seule par le noyau à la mort du démon" "$(qos)" "$qos0"
check "THP encore surchargé (le démon n'a rien pu remettre)" "$(thp)" always
start_daemon
check "THP remis par le démon relancé (reprise)" "$(thp)" "$thp0"
if grep -q reprise "$w/out/daemon.log"; then ok "reprise journalisée"; else ko "reprise absente du journal"; fi
pkill -KILL -f "sleep 30" 2>/dev/null
wait "$lpid" 2>/dev/null

echo "== 5. jeu sans profil"
run_game inconnu true
check "THP inchangé" "$(cat "$w/out/thp")" "$thp0"
check "latence inchangée" "$(cat "$w/out/qos")" "$qos0"

echo "== 6. arrêt propre (SIGTERM) en plein jeu"
eval "P launch --id reel-poll --no-sched-hint -- $(game 'exec sleep 30')" 2>> "$w/out/launch.log" &
lpid=$!
for _ in $(seq 200); do [ "$(thp)" = always ] && break; sleep 0.05; done
kill -TERM "$dpid"; wait "$dpid"; rc=$?; dpid=""
check "démon arrêté proprement" "$rc" 0
check "THP remis à l'arrêt" "$(thp)" "$thp0"
check "latence remise à l'arrêt" "$(qos)" "$qos0"
pkill -KILL -f "sleep 30" 2>/dev/null
wait "$lpid" 2>/dev/null

echo "$pass/$((pass + fail)) PASS"
[ "$fail" -eq 0 ] || { echo "--- journal du démon"; cat "$w/out/daemon.log"; echo "--- launcher"; cat "$w/out/launch.log"; }
[ "$fail" -eq 0 ]
