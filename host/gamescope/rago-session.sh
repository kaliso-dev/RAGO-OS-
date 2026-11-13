#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — session de jeu plein écran façon console (module M2).
# Marqueur : rago-proton-layer
#
# Lancée par le gestionnaire de connexion (/usr/share/wayland-sessions/rago.desktop) :
# gamescope prend l'écran (pas de bureau), Steam démarre dedans en mode
# Big Picture. Réglages de l'écran :
#   VRR (--adaptive-sync), HDR (--hdr-enabled, + --hdr-itm-enabled en option),
#   tearing autorisé en jeu (--immediate-flips), ordonnancement temps réel du
#   compositeur (--rt : gamescope a besoin de cap_sys_nice, posé par
#   setup_proton_layer.sh), HUD mangoapp réglé depuis le menu rapide de Steam.
# Avant Steam (Steam fermé, il réécrit sa configuration en quittant) :
#   - rago-steam-config sync : hook rago-launch dans les options de lancement
#     de chaque jeu installé, Proton-GE épinglé par défaut si le joueur n'a
#     rien choisi, chemins des runtimes EAC / BattlEye ;
#   - Heroic : enveloppe rago-launch (si Heroic est configuré) ;
#   - pré-chauffage des shaders en fond (rago-shader-prewarm.service, pause
#     automatique pendant les jeux).
#
# Réglages (env > ~/.config/rago/proton-layer.conf > /etc/rago/proton-layer.conf) :
#   RAGO_SESSION_WIDTH / _HEIGHT / _REFRESH   vide = mode natif de l'écran
#   RAGO_SESSION_VRR=1  RAGO_SESSION_HDR=1  RAGO_SESSION_HDR_ITM=0
#   RAGO_SESSION_TEARING=1  RAGO_SESSION_RT=1  RAGO_SESSION_MANGOAPP=1
#   RAGO_SESSION_OUTPUT=DP-1,HDMI-A-1  RAGO_SESSION_VK_DEVICE=1002:744c
#   RAGO_SESSION_BACKEND=drm|sdl|wayland|headless (vide = auto)
#   RAGO_SESSION_STEAM_CMD="steam -gamepadui"   RAGO_SESSION_EXTRA_ARGS="…"
#
# Usage : rago-session [--print] [--nested] [--no-sync]
#   --print    affiche l'environnement et la commande gamescope, sans rien lancer
#   --nested   dans une fenêtre plein écran d'un bureau (pour essayer)
#   --no-sync  ne touche pas à la configuration de Steam / Heroic
#
# EN ATTENTE DE MATÉRIEL : VRR, HDR, tearing, --rt et les FPS ne se vérifient
# que sur un vrai écran avec un vrai GPU (jamais testé par Claude).
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
declare -F rago_pl_conf_get >/dev/null || { echo "rago-session : rago_proton_lib.sh introuvable" >&2; exit 1; }
rago_pl_path_games /usr/games # steam et gamescope dans /usr/games (Debian / Ubuntu)

print=0 nested=0 sync=1
while [ $# -gt 0 ]; do
	case "$1" in
	--print) print=1; shift ;;
	--nested) nested=1; shift ;;
	--no-sync) sync=0; shift ;;
	-h | --help) sed -n "3,/^set -uo/p" "$self" | sed -e "\$d" -e "s/^# \{0,1\}//"; exit 0 ;;
	*) echo "rago-session : option inconnue : $1 (--help)" >&2; exit 2 ;;
	esac
done

CONF_SYS=${RAGO_PROTON_CONF_FILE:-$RAGO_PROTON_CONF}
CONF_USR="${XDG_CONFIG_HOME:-$HOME/.config}/rago/proton-layer.conf"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/rago"
RT=${RAGO_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp/rago-$(id -u)}/rago}
LOG="$STATE/session.log"

log() { printf 'rago-session : %s\n' "$*" >&2; }
setting() { rago_pl_setting "$1" "$2" "$CONF_SYS" "$CONF_USR"; }
flag() {
	local v
	v=$(setting "$1" "$2")
	rago_pl_bool "$v" 2>/dev/null || { log "$1=$v illisible (1 ou 0) : défaut $2"; echo "$2"; }
}

# Réglages lus une fois, puis exportés pour rago_pl_gamescope_args.
RAGO_SESSION_VRR=$(flag RAGO_SESSION_VRR 1)
RAGO_SESSION_HDR=$(flag RAGO_SESSION_HDR 1)
RAGO_SESSION_HDR_ITM=$(flag RAGO_SESSION_HDR_ITM 0)
RAGO_SESSION_TEARING=$(flag RAGO_SESSION_TEARING 1)
RAGO_SESSION_RT=$(flag RAGO_SESSION_RT 1)
RAGO_SESSION_MANGOAPP=$(flag RAGO_SESSION_MANGOAPP 1)
RAGO_SESSION_WIDTH=$(setting RAGO_SESSION_WIDTH "")
RAGO_SESSION_HEIGHT=$(setting RAGO_SESSION_HEIGHT "")
RAGO_SESSION_REFRESH=$(setting RAGO_SESSION_REFRESH "")
RAGO_SESSION_OUTPUT=$(setting RAGO_SESSION_OUTPUT "")
RAGO_SESSION_VK_DEVICE=$(setting RAGO_SESSION_VK_DEVICE "")
RAGO_SESSION_BACKEND=$(setting RAGO_SESSION_BACKEND "")
RAGO_SESSION_STEAM_CMD=$(setting RAGO_SESSION_STEAM_CMD "steam -gamepadui")
RAGO_SESSION_EXTRA_ARGS=$(setting RAGO_SESSION_EXTRA_ARGS "")
RAGO_SESSION_NESTED=$nested
for v in WIDTH HEIGHT REFRESH; do
	n="RAGO_SESSION_$v"
	case "${!n}" in '' | *[!0-9]*) [ -z "${!n}" ] || { log "$n=${!n} : nombre attendu, ignoré"; printf -v "$n" ''; } ;; esac
done
STEAM_HOOK=$(flag RAGO_STEAM_HOOK 1)
HEROIC=$(flag RAGO_HEROIC 1)
DEFAULT_PROTON=$(setting RAGO_DEFAULT_PROTON ge)
GE_NAME=$(setting RAGO_PROTON_GE_NAME "")
PREWARM=$(setting RAGO_SHADER_PREWARM background)
GAMESCOPE=${RAGO_GAMESCOPE_BIN:-$(command -v gamescope 2>/dev/null || true)}

if [ -z "$GAMESCOPE" ]; then
	log "gamescope absent : sudo host/setup_proton_layer.sh deps"
	[ "$print" = 1 ] || exit 1
	GAMESCOPE=gamescope
fi
if [ "$RAGO_SESSION_MANGOAPP" = 1 ] && ! command -v mangoapp >/dev/null 2>&1; then
	log "mangoapp absent (paquet mangohud) : session sans HUD"
	RAGO_SESSION_MANGOAPP=0
fi
if [ "$RAGO_SESSION_RT" = 1 ] && command -v getcap >/dev/null 2>&1 && [ -e "$GAMESCOPE" ]; then
	case "$(getcap "$GAMESCOPE" 2>/dev/null)" in
	*cap_sys_nice*) ;;
	*) log "gamescope sans cap_sys_nice : --rt et la file GPU prioritaire sans effet (sudo host/setup_proton_layer.sh install)" ;;
	esac
fi
steam_bin=${RAGO_SESSION_STEAM_CMD%% *}
if ! command -v "$steam_bin" >/dev/null 2>&1; then
	log "$steam_bin absent : sudo host/setup_proton_layer.sh deps"
	[ "$print" = 1 ] || exit 1
fi
export RAGO_SESSION_VRR RAGO_SESSION_HDR RAGO_SESSION_HDR_ITM RAGO_SESSION_TEARING RAGO_SESSION_RT \
	RAGO_SESSION_MANGOAPP RAGO_SESSION_WIDTH RAGO_SESSION_HEIGHT RAGO_SESSION_REFRESH RAGO_SESSION_OUTPUT \
	RAGO_SESSION_VK_DEVICE RAGO_SESSION_BACKEND RAGO_SESSION_STEAM_CMD RAGO_SESSION_EXTRA_ARGS RAGO_SESSION_NESTED

mapfile -t args < <(rago_pl_gamescope_args)
mapfile -t envs < <(rago_pl_session_env)
# Steam règle le HUD de mangoapp en réécrivant ce fichier (menu rapide) ;
# « no_display » au départ, comme une session SteamOS.
if [ "$RAGO_SESSION_MANGOAPP" = 1 ] && [ -z "${MANGOHUD_CONFIGFILE:-}" ]; then
	envs+=("MANGOHUD_CONFIGFILE=$RT/mangoapp.conf")
fi

if [ "$print" = 1 ]; then
	for e in "${envs[@]}"; do printf 'env:%s\n' "$e"; done
	for a in "$GAMESCOPE" "${args[@]}"; do printf 'argv:%s\n' "$a"; done
	exit 0
fi

mkdir -p "$STATE" "$RT" 2>/dev/null
{
	printf '\n=== %s session Rago (gamescope %s) ===\n' "$(date '+%F %T')" "$GAMESCOPE"
	if [ "$sync" = 1 ] && [ "$STEAM_HOOK" = 1 ] && command -v rago-steam-config >/dev/null; then
		set --
		if [ "$DEFAULT_PROTON" = ge ] && [ -n "$GE_NAME" ]; then set -- --default-tool "$GE_NAME"; fi
		rago-steam-config sync "$@" || printf 'rago-steam-config sync : code %s\n' "$?"
	fi
	if [ "$sync" = 1 ] && [ "$HEROIC" = 1 ] && command -v rago-steam-config >/dev/null &&
		[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/heroic/config.json" ]; then
		rago-steam-config heroic || true
	fi
} >> "$LOG" 2>&1

for e in "${envs[@]}"; do export "${e?}"; done
if [ "$RAGO_SESSION_MANGOAPP" = 1 ] && [ "${MANGOHUD_CONFIGFILE:-}" = "$RT/mangoapp.conf" ]; then
	echo no_display > "$MANGOHUD_CONFIGFILE"
fi

if [ "$PREWARM" = background ] && command -v rago-shader-cache >/dev/null; then
	if ! systemctl --user start rago-shader-prewarm.service >/dev/null 2>&1; then
		nohup setsid rago-shader-cache prewarm --wait-games >> "$LOG" 2>&1 < /dev/null &
	fi
fi

log "gamescope ${args[*]}"
exec "$GAMESCOPE" "${args[@]}"
