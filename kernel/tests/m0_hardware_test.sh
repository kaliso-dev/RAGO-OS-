#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test du module M0 sur VRAI matériel (machine démarrée sur le
# noyau Rago, rago-scx.service actif). Critères de la bible v7 :
#   uname = Rago ; SCHED_CLASS_EXT=y ; scx chargé ; cyclictest meilleur ;
#   boot Secure Boot ON ; jeu tagué -> bons cœurs (CCD X3D / P-cores).
#
# Usage :
#   sudo m0_hardware_test.sh [--baseline FICHIER] [--duration S] [--skip-cyclictest]
#   sudo m0_hardware_test.sh --save-baseline FICHIER [--duration S]
#
# « cyclictest meilleur » = meilleur que le noyau d'origine de la machine :
#   1. démarrer sur le noyau d'origine, lancer --save-baseline ~/m0-baseline.txt
#   2. démarrer sur le noyau Rago, lancer --baseline ~/m0-baseline.txt
# Deux mesures, chacune sous charge (tous les CPU occupés) :
#   rt    : cyclictest SCHED_FIFO (latence du noyau : préemption, HZ) ;
#   other : cyclictest SCHED_OTHER lancé via rago-sched-hint (latence de
#           réveil d'une tâche de jeu taguée sous scx_rago).
# Critère : Max <= Max de référence ET Avg <= Avg de référence + 5 %.
#
# Dépendances : rt-tests (cyclictest), mokutil, sbsigntools, gcc, rago-sched-hint.
# Sortie : lignes PASS / FAIL / INFO / SKIP, code 0 si aucun FAIL.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib/rago_kernel_lib.sh
. "$here/../lib/rago_kernel_lib.sh"
FRAG="$here/../config/rago-gaming.config"
MOK_DIR="${RAGO_MOK_DIR:-/etc/rago/secureboot}"
KERNEL_IMG="${RAGO_KERNEL_IMG:-/boot/vmlinuz-linux-rago}"

baseline=""
save_baseline=""
duration=60
skip_cyclic=0
while [ $# -gt 0 ]; do
	case "$1" in
	--baseline) baseline=$2; shift 2 ;;
	--save-baseline) save_baseline=$2; shift 2 ;;
	--duration) duration=$2; shift 2 ;;
	--skip-cyclictest) skip_cyclic=1; shift ;;
	-h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
info() { echo "INFO: $*"; }
skip() { echo "SKIP: $*"; }

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (cyclictest temps réel, sbverify, mokutil)" >&2; exit 2; }

work=$(mktemp -d)
pids=()
cleanup() {
	local p
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	rm -rf "$work"
}
trap cleanup EXIT

# Faux jeu et outil de mesure.
FAKE_GAME=$(command -v fake_game || true)
if [ -z "$FAKE_GAME" ]; then
	FAKE_GAME="$work/fake_game"
	gcc -O2 -pthread -o "$FAKE_GAME" "$here/fake_game.c" || { echo "gcc requis pour fake_game" >&2; exit 2; }
fi
CHECK="$here/check_routing.sh"

# Charge de fond : un thread de calcul par CPU, au nom « bg ».
start_load() {
	"$FAKE_GAME" -t "$(nproc)" -s 100000 -n bg > "$work/load.out" 2>&1 &
	pids+=($!)
	sleep 1
}
stop_load() {
	local p
	for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
	wait 2>/dev/null
	pids=()
}

# Mesure cyclictest -> « max avg » (pire Max, moyenne des Avg).
#   cyclic <rt|other>
cyclic() {
	local mode=$1 out
	local args=(-m -q -D "${duration}s" -i 1000 -d 0 -t "$(nproc)" -a)
	if [ "$mode" = rt ]; then
		out=$(cyclictest "${args[@]}" -p 90 2>&1)
	elif command -v rago-sched-hint >/dev/null && rago-sched-hint status >/dev/null 2>&1; then
		out=$(rago-sched-hint -q run --confine off -- cyclictest "${args[@]}" --policy=other -p 0 2>&1)
	else
		out=$(cyclictest "${args[@]}" --policy=other -p 0 2>&1)
	fi
	echo "$out" | awk '
		/Max:/ {
			for (i = 1; i <= NF; i++) {
				if ($i == "Max:") { if ($(i+1) > max) max = $(i+1) }
				if ($i == "Avg:") { sum += $(i+1); n++ }
			}
		}
		END { if (n == 0) { print "0 0"; exit 1 } printf "%d %d\n", max, sum / n }'
}

# --- Mode référence (noyau d'origine) ------------------------------------------
if [ -n "$save_baseline" ]; then
	command -v cyclictest >/dev/null || { echo "cyclictest absent (rt-tests)" >&2; exit 2; }
	info "référence sur $(uname -r) : 2 × ${duration}s sous charge"
	start_load
	rt=$(cyclic rt); other=$(cyclic other)
	stop_load
	{
		echo "# Rago M0 — référence cyclictest ($(date -u +%FT%TZ))"
		echo "kernel=$(uname -r)"
		echo "duration=$duration"
		echo "rt=$rt"
		echo "other=$other"
	} > "$save_baseline"
	info "rt (max avg µs) = $rt ; other = $other"
	info "référence écrite dans $save_baseline"
	exit 0
fi

# --- 1. Noyau Rago ------------------------------------------------------------------
case "$(uname -r)" in
*-rago*) pass "noyau Rago démarré ($(uname -r))" ;;
*) fail "noyau courant $(uname -r) : pas le noyau Rago" ;;
esac
info "x86-64 de ce CPU : v$(rago_detect_x86_level /proc/cpuinfo)"

# --- 2. Configuration ------------------------------------------------------------------
if [ -r /proc/config.gz ]; then
	zcat /proc/config.gz > "$work/config"
	if [ "$(rago_cfg_get "$work/config" SCHED_CLASS_EXT)" = y ]; then
		pass "CONFIG_SCHED_CLASS_EXT=y"
	else
		fail "CONFIG_SCHED_CLASS_EXT absent"
	fi
	if out=$(rago_cfg_verify "$work/config" "$FRAG"); then
		pass "toutes les options de rago-gaming.config sont actives"
	else
		fail "options manquantes : $(echo "$out" | grep MISSING | cut -d' ' -f2 | tr '\n' ' ')"
	fi
	info "CONFIG_X86_64_VERSION=$(rago_cfg_get "$work/config" X86_64_VERSION)"
else
	fail "/proc/config.gz absent (CONFIG_IKCONFIG_PROC)"
fi
if grep -qw "mitigations=off" /proc/cmdline; then
	info "mitigations=off actif (option choisie dans /etc/rago/kernel.conf)"
else
	info "mitigations : défaut du noyau"
fi

# --- 3. Secure Boot --------------------------------------------------------------------
if command -v mokutil >/dev/null; then
	sb=$(mokutil --sb-state 2>&1)
	if echo "$sb" | grep -q "SecureBoot enabled"; then
		pass "Secure Boot activé et noyau Rago démarré : la chaîne signée est acceptée"
	else
		fail "Secure Boot non actif ($sb)"
	fi
	if [ -f "$MOK_DIR/MOK.cer" ]; then
		if mokutil --test-key "$MOK_DIR/MOK.cer" 2>&1 | grep -q "already enrolled"; then
			pass "clé MOK Rago inscrite"
		else
			fail "clé MOK Rago non inscrite (build_rago_kernel.sh mok-enroll)"
		fi
	else
		fail "clé MOK absente ($MOK_DIR/MOK.cer)"
	fi
else
	fail "mokutil absent"
fi
if rago_ab_mode "${RAGO_UPDATE_CONF:-/etc/rago/update.conf}"; then
	# Mode A/B (M4) : le noyau est embarqué dans l'UKI signée du slot démarré.
	esp=$(rago_conf_get "${RAGO_KERNEL_CONF:-/etc/rago/kernel.conf}" RAGO_ESP /boot)
	sel=$(od -An -v -t u1 -j 4 /sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f 2>/dev/null |
		awk '{ for (i = 1; i <= NF; i++) b[c++] = $i } END { for (i = 0; i + 1 < c; i += 2) { if (b[i] == 0 && b[i + 1] == 0) break; if (b[i + 1] == 0) printf "%c", b[i] } }')
	uki="$esp/EFI/Linux/$sel"
	if [ -z "$sel" ] || [ ! -f "$uki" ]; then
		fail "mode A/B : UKI démarrée introuvable (${sel:-LoaderEntrySelected absente}) : rago-update status"
	elif command -v sbverify >/dev/null && [ -f "$MOK_DIR/MOK.crt" ] && sbverify --cert "$MOK_DIR/MOK.crt" "$uki" >/dev/null 2>&1; then
		pass "mode A/B : UKI démarrée $sel signée par la clé MOK (sbverify)"
	else
		fail "mode A/B : UKI $sel non signée par la clé MOK (ou sbverify / MOK.crt manquant)"
	fi
elif command -v sbverify >/dev/null && [ -f "$MOK_DIR/MOK.crt" ] && [ -f "$KERNEL_IMG" ]; then
	if sbverify --cert "$MOK_DIR/MOK.crt" "$KERNEL_IMG" >/dev/null 2>&1; then
		pass "$KERNEL_IMG signé par la clé MOK (sbverify)"
	else
		fail "$KERNEL_IMG non signé par la clé MOK"
	fi
else
	fail "sbverify, MOK.crt ou $KERNEL_IMG manquant"
fi
lockdown=$(cat /sys/kernel/security/lockdown 2>/dev/null || echo "?")
info "lockdown : $lockdown (attendu : [none], nécessaire à l'hibernation du Fast OS Switch)"

# --- 4. scx_rago -----------------------------------------------------------------------
state=$(cat /sys/kernel/sched_ext/state 2>/dev/null || echo absent)
ops=$(cat /sys/kernel/sched_ext/root/ops 2>/dev/null || true)
if [ "$state" = enabled ] && [ "${ops#rago}" != "$ops" ]; then
	pass "scx_rago chargé (sched_ext=$state, ops=$ops)"
else
	fail "scx_rago non chargé (sched_ext=$state, ops=${ops:--})"
fi
if systemctl is-active --quiet rago-scx.service; then
	pass "rago-scx.service actif"
else
	fail "rago-scx.service inactif"
fi
if st=$(rago-sched-hint status 2>&1); then
	pass "canal launcher joignable"
	while IFS= read -r l; do info "status: $l"; done <<< "$st"
else
	fail "rago-sched-hint status : $st"
fi

# --- 5. cyclictest ---------------------------------------------------------------------
if [ "$skip_cyclic" = 1 ]; then
	skip "cyclictest (--skip-cyclictest)"
elif ! command -v cyclictest >/dev/null; then
	fail "cyclictest absent (paquet rt-tests)"
else
	info "cyclictest : 2 × ${duration}s sous charge"
	start_load
	rt=$(cyclic rt); other=$(cyclic other)
	stop_load
	info "Rago : rt (max avg µs) = $rt ; other = $other"
	if [ -z "$baseline" ]; then
		skip "comparaison cyclictest : pas de --baseline (voir l'en-tête)"
	elif [ ! -r "$baseline" ]; then
		fail "référence illisible : $baseline"
	else
		info "référence : $(sed -n 's/^kernel=//p' "$baseline")"
		for m in rt other; do
			read -r bmax bavg <<< "$(sed -n "s/^$m=//p" "$baseline")"
			if [ "$m" = rt ]; then read -r rmax ravg <<< "$rt"; else read -r rmax ravg <<< "$other"; fi
			if [ "$rmax" -le "$bmax" ] && [ $((ravg * 100)) -le $((bavg * 105)) ]; then
				pass "cyclictest $m : max ${rmax}µs <= ${bmax}µs, avg ${ravg}µs (réf ${bavg}µs)"
			else
				fail "cyclictest $m : max ${rmax}µs (réf ${bmax}µs), avg ${ravg}µs (réf ${bavg}µs)"
			fi
		done
	fi
fi

# --- 6. Routage X3D / P-E ------------------------------------------------------------------
topo=$(echo "${st:-}" | sed -n 's/^topo=//p')
game=$(echo "${st:-}" | sed -n 's/^game=//p')
[ -n "$topo" ] || { topo=$(rago-sched-hint topology | sed -n 's/^topo=//p'); game=$(rago-sched-hint topology | sed -n 's/^game=//p'); }
info "topologie : $topo, cœurs jeu : ${game:--}"
case "$topo" in
x3d|hybrid)
	start_load
	nthr=$(echo "$game" | tr ',' '\n' | awk -F- '{ n += ($2 == "" ? 1 : $2 - $1 + 1) } END { print (n > 2 ? n - 1 : 1) }')
	rago-sched-hint run -- "$FAKE_GAME" -t "$nthr" -s 100000 -r -c > "$work/game.out" 2>&1 &
	pids+=($!)
	sleep 3
	gpid=$(sed -n 's/^pid=//p' "$work/game.out")
	if [ -z "$gpid" ]; then
		fail "le faux jeu n'a pas démarré : $(cat "$work/game.out")"
	else
		if rago-sched-hint list | grep -q "^HINT tgid $gpid game"; then
			pass "jeu tagué par le launcher (pid $gpid)"
		else
			fail "jeu non tagué"
		fi
		# X3D : affinité dure + routage BPF -> quasi 100 %. Hybride : préférence
		# BPF (le jeu peut déborder sur les E-cores si les P-cores sont pleins).
		want=95; [ "$topo" = hybrid ] && want=80
		r=$("$CHECK" "$gpid" "$game" 20)
		pct=${r##*pct=}
		if [ "$pct" -ge "$want" ]; then pass "routage $topo : jeu ${pct}% sur $game ($r)"; else fail "routage $topo : jeu ${pct}% sur $game, attendu >= ${want}% ($r)"; fi
		r=$("$CHECK" "$gpid" "$game" 20 RenderThread)
		pct=${r##*pct=}
		if [ "$pct" -ge 95 ]; then pass "thread de rendu ${pct}% sur $game ($r)"; else fail "thread de rendu ${pct}% sur $game, attendu >= 95% ($r)"; fi
	fi
	stop_load
	;;
*)
	skip "routage : CPU symétrique (ni X3D ni hybride), seul le boost de criticité s'applique"
	;;
esac

echo
if [ "$fails" -eq 0 ]; then echo "M0 : PASS"; else echo "M0 : FAIL ($fails)"; fi
[ "$fails" -eq 0 ]
