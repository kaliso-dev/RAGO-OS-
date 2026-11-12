#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — /init de la VM de test de scx_rago (lancé par run_scx_vm_test.sh).
# Imprime des lignes « RAGO-PASS / RAGO-FAIL / RAGO-INFO » puis éteint la VM.
/bin/busybox --install -s /bin
export PATH=/usr/bin:/bin:/sbin

mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t tmpfs run /run
mount -t tmpfs tmp /tmp
mount -t bpf bpf /sys/fs/bpf 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null

fails=0
pass() { echo "RAGO-PASS: $*"; }
fail() { echo "RAGO-FAIL: $*"; fails=$((fails + 1)); }
info() { echo "RAGO-INFO: $*"; }
finish() {
	if [ "$fails" -eq 0 ]; then echo "RAGO-SUMMARY: PASS"; else echo "RAGO-SUMMARY: FAIL ($fails)"; fi
	sync
	poweroff -f
}

# root/ops vaut « rago » suivi éventuellement de la version (rago_0.1.0_...).
is_rago() {
	case "$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)" in rago*) return 0 ;; *) return 1 ;; esac
}

GAME=0-3   # socket 0 de la VM = « CCD à cache 3D »
BG=4-7

info "noyau $(uname -r), $(nproc) CPU, sched_ext=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo absent)"
[ -d /sys/kernel/sched_ext ] || { fail "noyau sans sched_ext"; finish; }

# --- 0. Contrôle : sans scx_rago, un jeu non tagué tourne partout -----------
fake_game -t 8 -s 900 -n bg > /run/bg.out 2>&1 &
sleep 1
BGPID=$(sed -n 's/^pid=//p' /run/bg.out)
fake_game -t 3 -s 14 -r > /run/ctl.out 2>&1 &
sleep 2
CPID=$(sed -n 's/^pid=//p' /run/ctl.out)
r=$(check_routing.sh "$CPID" "$GAME" 8)
info "contrôle EEVDF (jeu non tagué, sans scx_rago) : $r"
wait "$CPID" 2>/dev/null

# --- 1. Chargement de scx_rago ----------------------------------------------
scx_rago --performance --rago-topo x3d --rago-game-cpus "$GAME" > /run/scx.log 2>&1 &
SCX=$!
i=0
# L'état passe par « enabling » (vérification BPF, lente en émulation TCG).
while [ "$i" -lt 300 ]; do
	if [ "$(cat /sys/kernel/sched_ext/state)" = "enabled" ] && is_rago; then
		break
	fi
	kill -0 "$SCX" 2>/dev/null || break
	sleep 1; i=$((i + 1))
done
st=$(cat /sys/kernel/sched_ext/state); ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)
if [ "$st" = "enabled" ] && is_rago; then
	pass "scx_rago chargé (vérifieur BPF OK), sched_ext state=$st ops=$ops"
else
	fail "scx_rago non chargé (state=$st ops=$ops)"
	tail -40 /run/scx.log
	finish
fi
i=0
while [ ! -S /run/rago/sched-hint.sock ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
rago-sched-hint status | sed 's/^/RAGO-INFO: status: /'

# --- 2. Lancement d'un jeu via le launcher ----------------------------------
rago-sched-hint run --confine off -- fake_game -t 3 -s 600 -r -c > /run/game.out 2>&1 &
sleep 3
GPID=$(sed -n 's/^pid=//p' /run/game.out)
CHILD=$(sed -n 's/^child=//p' /run/game.out)
info "jeu pid=$GPID enfant=$CHILD"
for p in $GPID $CHILD; do
	for t in /proc/"$p"/task/*; do
		[ -r "$t/stat" ] && info "thread $(cat "$t/comm" 2>/dev/null) : $(cut -d' ' -f3 "$t/stat" 2>/dev/null) cpu=$(sed 's/.*) //' "$t/stat" | awk '{print $37}')"
	done
done
sed 's/^/RAGO-INFO: game.out: /' /run/game.out

list=$(rago-sched-hint list)
echo "$list" | sed 's/^/RAGO-INFO: list: /'
if echo "$list" | grep -q "^HINT tgid $GPID game 1 $GPID"; then
	pass "jeu tagué par le launcher avant exec (même PID)"
else
	fail "jeu non tagué"
fi
if [ -n "$CHILD" ] && echo "$list" | grep -q "^HINT tgid $CHILD game 2 $GPID"; then
	pass "processus enfant tagué par héritage au fork (BPF)"
else
	fail "héritage au fork absent"
fi

# --- 3. Routage : le jeu reste sur le « CCD X3D » malgré la charge de fond --
r=$(check_routing.sh "$GPID" "$GAME" 10)
pct=${r##*pct=}
info "jeu (tous threads, enfant inclus) : $r"
if [ "$pct" -ge 90 ]; then pass "routage X3D : ${pct}% des échantillons du jeu sur $GAME"; else fail "routage X3D : ${pct}% seulement sur $GAME"; fi

r=$(check_routing.sh "$GPID" "$GAME" 15 RenderThread)
pct=${r##*pct=}
info "thread de rendu : $r"
if [ "$pct" -ge 95 ]; then pass "thread de rendu sur $GAME (${pct}%)"; else fail "thread de rendu hors masque (${pct}%)"; fi

r=$(check_routing.sh "$BGPID" "$BG" 6)
info "fond pendant le jeu (préférence douce vers $BG) : $r"

st=$(rago-sched-hint status)
echo "$st" | grep -E "game_tasks|render_tasks|inherited|steal_blocked|tagged_lookups" | sed 's/^/RAGO-INFO: /'
rt=$(echo "$st" | sed -n 's/^render_tasks=//p')
if [ "${rt:-0}" -ge 1 ]; then pass "thread de rendu reconnu par son nom (render_tasks=$rt)"; else fail "aucun thread de rendu reconnu"; fi

# --- 4. Untag ----------------------------------------------------------------
rago-sched-hint untag --pid "$GPID" | sed 's/^/RAGO-INFO: untag: /'
if rago-sched-hint list | grep -q "tgid $GPID "; then fail "untag incomplet"; else pass "untag retire l'arbre"; fi

# --- 5. Filet : arrêt de scx_rago -> retour EEVDF, le jeu continue ------------
kill -INT "$SCX"
i=0
while [ "$(cat /sys/kernel/sched_ext/state)" != "disabled" ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
if [ "$(cat /sys/kernel/sched_ext/state)" = "disabled" ] && kill -0 "$GPID" 2>/dev/null; then
	pass "filet : scx_rago arrêté -> noyau revenu à EEVDF, jeu toujours vivant"
else
	fail "retour EEVDF"
fi
out=$(rago-sched-hint run -- true 2>&1); rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "filet EEVDF"; then
	pass "sans scx_rago, le launcher lance quand même le jeu"
else
	fail "lancement sans scx_rago (rc=$rc)"
fi
sed 's/\x1b\[[0-9;]*m//g' /run/scx.log | grep -E "WARN|ERROR|rror|exit|EXIT" | head -20 | cut -c1-240 | sed 's/^/RAGO-INFO: scx: /'
dmesg | grep -i -E "sched_ext|scx" | tail -10 | sed 's/^/RAGO-INFO: dmesg: /'
kill "$BGPID" "$GPID" 2>/dev/null
finish
