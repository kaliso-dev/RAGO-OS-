#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — hook de lancement des jeux de la couche Proton (module M2).
# Marqueur : rago-proton-layer
#
# Option de lancement Steam (posée automatiquement par rago-steam-config) :
#     rago-launch %command%
# Heroic : enveloppe (« wrapper ») globale rago-launch. Lutris : préfixe de commande.
# À la main : rago-launch [--print] [--] <commande du jeu…>
#
# Ce qu'il fait, dans l'ordre :
#   1. caches de shaders du jeu par GPU (Mesa, NVIDIA, DXVK, vkd3d-proton) sous
#      RAGO_SHADER_CACHE_ROOT/<gpu>/<jeu>/, seulement pour les variables que
#      le lanceur (Steam, Proton) n'a pas déjà posées ; note l'environnement de
#      cache du jeu pour que rago-shader-cache pré-chauffe le même cache ;
#   2. jeux hors Steam : runtimes Proton EasyAntiCheat / BattlEye de Steam
#      (PROTON_EAC_RUNTIME, PROTON_BATTLEYE_RUNTIME) s'ils sont installés ;
#   3. pré-chauffage avant le jeu si RAGO_SHADER_PREWARM=before ; sinon le
#      pré-chauffage de fond se met en pause tant que le jeu tourne ;
#   4. lance le jeu par `rago-profiled launch` (M14 : profil du jeu par-dessus
#      la base M1, puis base remise ; il passe lui-même par `rago-sched-hint run`,
#      M0, pour taguer le jeu avant sa première instruction), avec gamemoderun
#      et MangoHud autour de la commande du jeu.
#   Sans rago-profiled : `rago-sched-hint run` seul ; sans les deux : le jeu
#   seul. Le jeu se lance toujours.
#
# Réglages (variable d'environnement > ~/.config/rago/proton-layer.conf >
# /etc/rago/proton-layer.conf) :
#   RAGO_GAMEMODE=1|0  RAGO_MANGOHUD=1|0  RAGO_SHADER_CACHE=1|0
#   RAGO_SHADER_CACHE_ROOT=DIR (défaut ~/.local/share/rago/shader-cache)
#   RAGO_SHADER_CACHE_SIZE=4G  RAGO_SHADER_PREWARM=background|before|off
#   RAGO_SHADER_PREWARM_TIMEOUT=120  RAGO_FOSSILIZE_CAPTURE=1|0
#   RAGO_PROFILE_ID=<id>   (force le profil M14, ex. RAGO_PROFILE_ID=counter-strike-2)
# Exemple : RAGO_MANGOHUD=0 rago-launch %command%
#
# --print : affiche l'environnement ajouté et la commande, sans rien lancer.
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
if ! declare -F rago_pl_conf_get >/dev/null; then
	echo "rago-launch : rago_proton_lib.sh introuvable, jeu lancé sans réglage Rago" >&2
	[ "${1:-}" = "--" ] && shift
	exec "$@"
fi

info() { [ "${RAGO_LAUNCH_QUIET:-0}" = 1 ] || printf 'rago-launch : %s\n' "$*" >&2; }
warn() { printf 'rago-launch : attention : %s\n' "$*" >&2; }

print=0
while [ $# -gt 0 ]; do
	case "$1" in
	--print) print=1; shift ;;
	-h | --help) sed -n "3,/^set -uo/p" "$self" | sed -e "\$d" -e "s/^# \{0,1\}//"; exit 0 ;;
	--) shift; break ;;
	*) break ;;
	esac
done
if [ $# -eq 0 ]; then
	echo "usage : rago-launch [--print] [--] <commande du jeu…> (Steam : rago-launch %command%)" >&2
	exit 2
fi

# Déjà sous rago-launch (Heroic + option Steam, ou écrit deux fois) : une fois suffit.
if [ "${RAGO_LAUNCH_ACTIVE:-}" = 1 ] && [ "$print" = 0 ]; then
	exec "$@"
fi

SYS=${RAGO_SYSFS:-/sys}
CONF_SYS=${RAGO_PROTON_CONF_FILE:-$RAGO_PROTON_CONF}
CONF_USR="${XDG_CONFIG_HOME:-$HOME/.config}/rago/proton-layer.conf"
RT=${RAGO_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp/rago-$(id -u)}/rago}
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/rago"

setting() { rago_pl_setting "$1" "$2" "$CONF_SYS" "$CONF_USR"; }
flag() { # flag <CLE> <défaut> -> 1|0
	local v
	v=$(setting "$1" "$2")
	rago_pl_bool "$v" 2>/dev/null || { warn "$1=$v illisible (1 ou 0) : défaut $2"; echo "$2"; }
}

GAMEMODE=$(flag RAGO_GAMEMODE 1)
MANGOHUD_ON=$(flag RAGO_MANGOHUD 1)
SHADER=$(flag RAGO_SHADER_CACHE 1)
CAPTURE=$(flag RAGO_FOSSILIZE_CAPTURE 1)
PREWARM=$(setting RAGO_SHADER_PREWARM background)
PREWARM_TIMEOUT=$(setting RAGO_SHADER_PREWARM_TIMEOUT 120)
CACHE_SIZE=$(setting RAGO_SHADER_CACHE_SIZE 4G)
CACHE_ROOT=$(setting RAGO_SHADER_CACHE_ROOT "")
[ -n "$CACHE_ROOT" ] || CACHE_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/rago/shader-cache"

declare -a added_env=()
put_env() { # put_env <CLE> <valeur> : seulement si absente
	if [ -z "${!1+x}" ]; then
		export "$1=$2"
		added_env+=("$1=$2")
	fi
}

appid=${SteamAppId:-}
case "$appid" in '' | *[!0-9]*) appid="" ;; esac
[ "$appid" = 0 ] && appid=""
exe=$(rago_pl_exe_key "$@")
game=$(rago_pl_game_key "$appid" "$@")

# --- 1. caches de shaders par GPU -----------------------------------------------------
steam_root=$(rago_pl_steam_root "$HOME" 2>/dev/null || true)
gpu=""
gdir=""
if [ "$SHADER" = 1 ]; then
	gpu=$(rago_pl_gpu_key "$SYS" "$(rago_pl_gpu_selector "${RAGO_GPU:-}" "${DRI_PRIME:-}" "${__NV_PRIME_RENDER_OFFLOAD:-}")")
	gdir="$CACHE_ROOT/$gpu/$game"
	if cache_env=$(rago_pl_cache_env "$gdir" "$CACHE_SIZE"); then
		while IFS='=' read -r k v; do put_env "$k" "$v"; done <<< "$cache_env"
	else
		warn "RAGO_SHADER_CACHE_SIZE=$CACHE_SIZE illisible : caches laissés au pilote"
	fi
	# Capture Fossilize hors Steam (Steam capture déjà les siens) si la couche
	# Vulkan de Fossilize est installée.
	if [ "$CAPTURE" = 1 ] && [ -z "$appid" ]; then
		for j in ${RAGO_VK_LAYER_DIRS:-/usr/share/vulkan/explicit_layer.d /etc/vulkan/explicit_layer.d}; do
			compgen -G "$j/*ossilize*.json" >/dev/null || continue
			put_env FOSSILIZE_DUMP_PATH "$gdir/fossilize/rago"
			if [ -z "${VK_LOADER_LAYERS_ENABLE:-}" ]; then
				put_env VK_LOADER_LAYERS_ENABLE "VK_LAYER_fossilize"
			fi
			break
		done
	fi
	if [ "$print" = 0 ]; then
		mkdir -p "$gdir/mesa" "$gdir/nvidia" "$gdir/dxvk" "$gdir/vkd3d" "$gdir/fossilize" 2>/dev/null ||
			warn "dossier de cache impossible à créer : $gdir"
		# Ce que le pré-chauffage doit reproduire : l'environnement de cache
		# réel du jeu (posé par Steam / Proton ou par nous) et ses bases Fossilize.
		{
			printf '# Rago OS — environnement de cache du jeu %s (rago-launch, %s)\n' "$game" "$RAGO_PROTON_MARKER"
			printf 'RAGO_GAME=%s\nRAGO_EXE=%s\n' "$game" "$exe"
			while IFS='=' read -r k v; do
				[ -n "$k" ] || continue
				rago_pl_cache_var "$k" || continue
				case "$v" in *$'\n'*) continue ;; esac
				printf '%s=%s\n' "$k" "$v"
			done < <(env)
		} > "$gdir/game.env.tmp" 2>/dev/null && mv -f "$gdir/game.env.tmp" "$gdir/game.env" 2>/dev/null
		{
			echo "$gdir/fossilize"
			if [ -n "${STEAM_COMPAT_SHADER_PATH:-}" ]; then
				echo "$STEAM_COMPAT_SHADER_PATH/fozpipelinesv6"
			elif [ -n "$appid" ] && [ -n "$steam_root" ]; then
				# Bibliothèques Steam : la racine plus les « path » de libraryfolders.vdf.
				{
					echo "$steam_root"
					sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$steam_root/steamapps/libraryfolders.vdf" 2>/dev/null
				} | while IFS= read -r lib; do
					[ -d "$lib/steamapps/shadercache/$appid" ] && echo "$lib/steamapps/shadercache/$appid/fozpipelinesv6"
				done
			fi
		} | awk '!seen[$0]++' > "$gdir/foz-dirs" 2>/dev/null
	fi
fi

# --- 2. runtimes anti-triche Proton pour les jeux hors Steam --------------------------
if [ -z "$appid" ]; then
	for pair in "PROTON_EAC_RUNTIME:Proton EasyAntiCheat Runtime" "PROTON_BATTLEYE_RUNTIME:Proton BattlEye Runtime"; do
		var=${pair%%:*}
		name=${pair#*:}
		[ -n "${!var:-}" ] && continue
		dir=$(rago_pl_conf_get "$STATE/proton-runtimes.env" "$var" "")
		if [ -z "$dir" ] && [ -n "$steam_root" ]; then dir="$steam_root/steamapps/common/$name"; fi
		[ -n "$dir" ] && [ -d "$dir" ] && put_env "$var" "$dir"
	done
fi

# --- 3. MangoHud et gamemode autour du jeu --------------------------------------------
declare -a wrap=()
if [ "$GAMEMODE" = 1 ]; then
	case ":${LD_PRELOAD:-}:" in
	*libgamemodeauto*) ;; # déjà là (gamemoderun écrit dans l'option de lancement)
	*)
		if gm=$(command -v gamemoderun 2>/dev/null); then
			wrap+=("$gm")
		else
			info "gamemoderun absent : jeu lancé sans gamemode"
		fi ;;
	esac
fi
if [ "$MANGOHUD_ON" = 1 ]; then
	if [ "${RAGO_SESSION_MANGOAPP:-0}" = 1 ]; then
		: # session gamescope : mangoapp affiche le HUD (menu rapide de Steam)
	elif [ "${MANGOHUD:-0}" = 1 ] || [[ "${LD_PRELOAD:-}" == *MangoHud* ]]; then
		:
	elif mh=$(command -v mangohud 2>/dev/null); then
		# Réglage du HUD : ~/.config/MangoHud/ du joueur, sinon /etc/MangoHud.conf (Rago).
		wrap+=("$mh")
	else
		info "mangohud absent : jeu lancé sans HUD"
	fi
fi

# --- 4. profil M14 + hint M0 ------------------------------------------------------------
declare -a chain=()
profiled=${RAGO_PROFILED_BIN:-$(command -v rago-profiled 2>/dev/null || true)}
hint=${RAGO_SCHED_HINT_BIN:-$(command -v rago-sched-hint 2>/dev/null || true)}
if [ -n "$profiled" ] && [ -x "$profiled" ]; then
	chain=("$profiled" launch --exe "$exe")
	[ -n "${RAGO_PROFILE_ID:-}" ] && chain+=(--id "$RAGO_PROFILE_ID")
	chain+=(--)
elif [ -n "$hint" ] && [ -x "$hint" ]; then
	info "rago-profiled (M14) absent : pas de profil, hint ordonnanceur seul"
	chain=("$hint" run --)
else
	info "ni rago-profiled (M14) ni rago-sched-hint (M0) : jeu lancé sans profil ni hint"
fi

export RAGO_LAUNCH_ACTIVE=1
added_env+=("RAGO_LAUNCH_ACTIVE=1")

if [ "$print" = 1 ]; then
	printf 'game:%s\nexe:%s\ngpu:%s\ncache:%s\n' "$game" "$exe" "${gpu:--}" "${gdir:--}"
	for e in "${added_env[@]}"; do printf 'env:%s\n' "$e"; done
	for a in "${chain[@]}" "${wrap[@]}" "$@"; do printf 'argv:%s\n' "$a"; done
	exit 0
fi

# Pré-chauffage avant le jeu (RAGO_SHADER_PREWARM=before), borné dans le temps.
if [ "$SHADER" = 1 ] && [ "$PREWARM" = before ]; then
	sc=$(command -v rago-shader-cache 2>/dev/null || echo "$here/rago-shader-cache.sh")
	if [ -x "$sc" ]; then
		info "pré-chauffage des shaders de $game (au plus ${PREWARM_TIMEOUT} s)"
		"$sc" prewarm --game "$game" --timeout "$PREWARM_TIMEOUT" --no-wait-games >&2 || true
	fi
fi

# Jeu en cours : le pré-chauffage de fond se met en pause tant que ce PID vit
# (après exec, ce PID est celui de rago-profiled launch, puis du jeu).
if mkdir -p "$RT/games" 2>/dev/null; then
	rago_pl_proc_starttime $$ /proc > "$RT/games/$$" 2>/dev/null || rm -f "$RT/games/$$"
fi

info "jeu $game (gpu ${gpu:-?}) : ${chain[0]:-direct}"
exec "${chain[@]}" "${wrap[@]}" "$@"
