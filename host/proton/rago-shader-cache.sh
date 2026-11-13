#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — cache de shaders par GPU et pré-chauffage Fossilize (module M2).
# Marqueur : rago-proton-layer
#
# Chaque jeu lancé par rago-launch a son cache de pilote sous
#   RAGO_SHADER_CACHE_ROOT/<gpu>/<jeu>/   (défaut ~/.local/share/rago/shader-cache)
# où <gpu> = pilote-vendor-device (ex. amdgpu-1002-744c) : changer de carte ne
# mélange pas les caches, et le dossier peut vivre ailleurs (RAGO-LIB, M7).
# rago-launch y note l'environnement de cache réel du jeu (game.env) et où
# sont ses bases Fossilize (foz-dirs : celles que Steam télécharge ou capture,
# et celles de la couche Fossilize hors Steam).
#
# « prewarm » rejoue ces bases avec fossilize-replay dans le même
# environnement que le jeu : le pilote compile tout d'avance et le range dans
# le cache du jeu, au lieu de compiler en pleine partie (saccades). Une base
# déjà rejouée pour ce GPU et ce pilote n'est pas refaite ; une mise à jour du
# pilote (empreinte des ICD Vulkan) relance tout.
#
# Usage : rago-shader-cache <commande> [options]
#   gpu                        clé du GPU et empreinte du pilote
#   status                     jeux connus, bases, ce qui est pré-chauffé
#   prewarm [options]          rejoue les bases pas encore faites
#     --game CLE               un seul jeu (ex. steam-1091500, exe-game.exe)
#     --timeout S              arrête après S secondes (0 = sans limite)
#     --threads N              fils de compilation (défaut : moitié des CPU)
#     --wait-games             (défaut) pause tant qu'un jeu lancé par rago-launch tourne
#     --no-wait-games          ne se met jamais en pause (avant le lancement d'un jeu)
#     --dry-run                affiche ce qui serait rejoué
#
# Codes : 0 = fait (ou rien à faire), 1 = une base a échoué, 2 = usage,
# 4 = en attente : fossilize-replay introuvable (Steam fournit le sien dans
# ubuntu12_64 après son premier démarrage ; sinon paquet fossilize).
#
# Priorité : nice 19, E/S idle, SCHED_IDLE si chrt existe. Service utilisateur :
# rago-shader-prewarm.service (lancé par la session Rago).
set -uo pipefail

self=$(readlink -f "${BASH_SOURCE[0]}")
here=$(dirname "$self")
for lib in "${RAGO_PROTON_LIB:-}" "$here/../lib/rago_proton_lib.sh" /usr/lib/rago/rago_proton_lib.sh; do
	if [ -n "$lib" ] && [ -r "$lib" ]; then
		# shellcheck source-path=SCRIPTDIR source=../lib/rago_proton_lib.sh
		. "$lib"
		break
	fi
done
declare -F rago_pl_conf_get >/dev/null || { echo "rago-shader-cache : rago_proton_lib.sh introuvable" >&2; exit 2; }

log() { printf 'rago-shader-cache : %s\n' "$*" >&2; }
usage() { sed -n "3,/^set -uo/p" "$self" | sed -e "\$d" -e "s/^# \{0,1\}//"; }

SYS=${RAGO_SYSFS:-/sys}
ROOTFS=${RAGO_ROOTFS:-/}
CONF_SYS=${RAGO_PROTON_CONF_FILE:-$RAGO_PROTON_CONF}
CONF_USR="${XDG_CONFIG_HOME:-$HOME/.config}/rago/proton-layer.conf"
RT=${RAGO_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp/rago-$(id -u)}/rago}

CACHE_ROOT=$(rago_pl_setting RAGO_SHADER_CACHE_ROOT "" "$CONF_SYS" "$CONF_USR")
[ -n "$CACHE_ROOT" ] || CACHE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/rago/shader-cache"
THREADS=$(rago_pl_setting RAGO_SHADER_PREWARM_THREADS "" "$CONF_SYS" "$CONF_USR")
if [ -z "$THREADS" ]; then
	THREADS=$(( $(nproc 2>/dev/null || echo 2) / 2 ))
	[ "$THREADS" -ge 1 ] || THREADS=1
fi

cmd=${1:-}
[ $# -gt 0 ] && shift
game_only="" timeout=0 wait_games=1 dry_run=0
while [ $# -gt 0 ]; do
	case "$1" in
	--game) game_only=${2:?--game attend une clé}; shift 2 ;;
	--timeout) timeout=${2:?--timeout attend des secondes}; shift 2 ;;
	--threads) THREADS=${2:?--threads attend un nombre}; shift 2 ;;
	--wait-games) wait_games=1; shift ;;
	--no-wait-games) wait_games=0; shift ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) log "option inconnue : $1 (--help)"; exit 2 ;;
	esac
done
case "$timeout$THREADS" in *[!0-9]*) log "--timeout / --threads : nombre entier attendu"; exit 2 ;; esac
case "$game_only" in */* | .*) log "--game : clé invalide : $game_only"; exit 2 ;; esac

gpu=$(rago_pl_gpu_key "$SYS" "$(rago_pl_gpu_selector "${RAGO_GPU:-}" "${DRI_PRIME:-}" "${__NV_PRIME_RENDER_OFFLOAD:-}")")
fp=$(rago_pl_driver_fingerprint "$ROOTFS" "$SYS")
gpudir="$CACHE_ROOT/$gpu"
steam_root=$(rago_pl_steam_root "$HOME" 2>/dev/null || true)

# Bases Fossilize d'un jeu (une par ligne).
game_dbs() {
	local g=$1 d f
	[ -r "$g/foz-dirs" ] || return 0
	while IFS= read -r d; do
		{ [ -n "$d" ] && [ -d "$d" ]; } || continue
		for f in "$d"/*.foz; do
			[ -s "$f" ] && echo "$f"
		done
	done < "$g/foz-dirs"
}

# Signature d'une base : empreinte du pilote, taille, date, chemin.
db_sig() { printf '%s %s %s\n' "$fp" "$(stat -c '%s %Y' "$1" 2>/dev/null || echo '? ?')" "$1"; }

games_list() {
	local g
	if [ -n "$game_only" ]; then
		echo "$gpudir/$game_only"
		return
	fi
	for g in "$gpudir"/*/; do
		[ -r "$g/game.env" ] && echo "${g%/}"
	done
}

cmd_gpu() {
	printf 'gpu %s\npilote %s\ncache %s\n' "$gpu" "$fp" "$gpudir"
	rago_pl_gpu_list "$SYS" | while IFS=$'\t' read -r n pci ven did drv bv; do
		printf '  %s %s %s:%s pilote %s%s\n' "$n" "$pci" "$ven" "$did" "$drv" "$([ "$bv" = 1 ] && echo " (principal)")"
	done
}

cmd_status() {
	local g n done_n db bin
	cmd_gpu
	if bin=$(rago_pl_fossilize_bin "$steam_root"); then
		printf 'fossilize-replay %s\n' "$bin"
	else
		printf 'fossilize-replay absent : pré-chauffage en attente (Steam fournit le sien après son premier démarrage)\n'
	fi
	while IFS= read -r g; do
		[ -d "$g" ] || continue
		n=0 done_n=0
		while IFS= read -r db; do
			[ -n "$db" ] || continue
			n=$((n + 1))
			grep -qxF "$(db_sig "$db")" "$g/prewarm.stamp" 2>/dev/null && done_n=$((done_n + 1))
		done < <(game_dbs "$g")
		printf '  %s : %d base(s) Fossilize, %d pré-chauffée(s) pour ce pilote, cache %s\n' \
			"${g##*/}" "$n" "$done_n" "$(du -sh "$g" 2>/dev/null | cut -f1)"
	done < <(games_list)
}

cur=""
paused=0
# Le maître fossilize-replay et ses processus de compilation (ses fils directs).
sig_replay() { # sig_replay <signal> <pid>
	if [ "$1" = STOP ]; then
		kill -STOP "$2" 2>/dev/null
		pkill -STOP -P "$2" 2>/dev/null
	else
		pkill "-$1" -P "$2" 2>/dev/null
		kill "-$1" "$2" 2>/dev/null
	fi
}
# shellcheck disable=SC2317  # appelée par trap
stop_replay() {
	if [ -n "$cur" ]; then
		sig_replay CONT "$cur"
		sig_replay TERM "$cur"
	fi
	exit 143
}

# Rejoue une base dans l'environnement du jeu. Code du rejeu.
replay() { # replay <dossier du jeu> <base> <binaire> <secondes restantes ou 0>
	local g=$1 db=$2 bin=$3 left=$4 pid rc start now k v
	local -a pre=(nice -n 19)
	command -v ionice >/dev/null && pre+=(ionice -c 3)
	command -v chrt >/dev/null && pre+=(chrt --idle 0)
	(
		# Même environnement de cache que le jeu : on retire le nôtre, on
		# remet le sien (valeurs littérales, jamais évaluées).
		while IFS='=' read -r k v; do
			rago_pl_cache_var "$k" && unset "$k"
		done < <(env)
		while IFS='=' read -r k v; do
			case "$k" in '' | \#* | RAGO_*) continue ;; esac
			rago_pl_cache_var "$k" && export "$k=$v"
		done < "$g/game.env"
		exec "${pre[@]}" "$bin" --master-process --quiet-slave --num-threads "$THREADS" "$db"
	) </dev/null &
	# nice, ionice et chrt font exec : $! est le maître fossilize-replay.
	pid=$!
	cur=$pid
	start=$(date +%s)
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$wait_games" = 1 ] && rago_pl_games_active "$RT/games" /proc; then
			if [ "$paused" = 0 ]; then
				log "jeu en cours : pré-chauffage en pause"
				sig_replay STOP "$pid"
				paused=1
			fi
		elif [ "$paused" = 1 ]; then
			log "plus de jeu en cours : reprise"
			sig_replay CONT "$pid"
			paused=0
		fi
		now=$(date +%s)
		if [ "$left" -gt 0 ] && [ $((now - start)) -ge "$left" ]; then
			log "délai atteint : arrêt du rejeu de ${db##*/}"
			sig_replay CONT "$pid"
			sig_replay TERM "$pid"
			wait "$pid" 2>/dev/null
			cur=""
			return 124
		fi
		sleep 1
	done
	wait "$pid"
	rc=$?
	cur=""
	paused=0
	return "$rc"
}

cmd_prewarm() {
	local bin g db sig rc=0 r t0 left n_done=0 n_skip=0 n_fail=0 lock
	if ! bin=$(rago_pl_fossilize_bin "$steam_root"); then
		log "en attente : fossilize-replay introuvable (Steam fournit le sien dans ubuntu12_64 après son premier démarrage ; sinon paquet fossilize)"
		return 4
	fi
	mkdir -p "$RT" 2>/dev/null
	lock="$RT/shader-prewarm.lock"
	if [ "$dry_run" = 0 ] && command -v flock >/dev/null; then
		exec 9>"$lock"
		if ! flock -n 9; then
			log "un pré-chauffage tourne déjà"
			return 0
		fi
	fi
	trap stop_replay TERM INT HUP
	t0=$(date +%s)
	while IFS= read -r g; do
		[ -r "$g/game.env" ] || { log "${g##*/} : jamais lancé par rago-launch sur ce GPU ($gpu)"; continue; }
		while IFS= read -r db; do
			[ -n "$db" ] || continue
			sig=$(db_sig "$db")
			if grep -qxF "$sig" "$g/prewarm.stamp" 2>/dev/null; then
				n_skip=$((n_skip + 1))
				continue
			fi
			if [ "$dry_run" = 1 ]; then
				printf 'rejouer %s (%s)\n' "$db" "${g##*/}"
				continue
			fi
			left=0
			if [ "$timeout" -gt 0 ]; then
				left=$((timeout - ($(date +%s) - t0)))
				[ "$left" -gt 0 ] || { log "délai atteint"; break 2; }
			fi
			log "${g##*/} : rejeu de ${db##*/} ($THREADS fils, $bin)"
			replay "$g" "$db" "$bin" "$left"
			r=$?
			if [ "$r" = 0 ]; then
				n_done=$((n_done + 1))
				{ grep -vF " $db" "$g/prewarm.stamp" 2>/dev/null; echo "$sig"; } > "$g/prewarm.stamp.tmp" &&
					mv -f "$g/prewarm.stamp.tmp" "$g/prewarm.stamp"
			elif [ "$r" = 124 ]; then
				break 2
			else
				n_fail=$((n_fail + 1))
				rc=1
				log "${g##*/} : ${db##*/} a échoué (code $r) ; refait au prochain passage"
			fi
		done < <(game_dbs "$g")
	done < <(games_list)
	trap - TERM INT HUP
	[ "$dry_run" = 1 ] || log "fini : $n_done rejouée(s), $n_skip déjà faite(s), $n_fail échec(s) (gpu $gpu, pilote $fp)"
	return "$rc"
}

case "$cmd" in
gpu) cmd_gpu ;;
status) cmd_status ;;
prewarm) cmd_prewarm ;;
-h | --help | help) usage ;;
'') usage; exit 2 ;;
*) log "commande inconnue : $cmd (--help)"; exit 2 ;;
esac
