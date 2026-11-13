# SPDX-License-Identifier: GPL-2.0
# shellcheck shell=bash
#
# Rago OS — fonctions pures de la couche Proton (module M2).
#
# Aucune de ces fonctions ne change le système : elles lisent des fichiers ou
# des chaînes et écrivent sur la sortie standard. Utilisées par
# host/setup_proton_layer.sh, host/proton/rago-launch.sh,
# host/proton/rago-shader-cache.sh et host/gamescope/rago-session.sh ;
# testées par host/tests/test_proton_lib.sh.
#
# Installée dans /usr/lib/rago/rago_proton_lib.sh.

# Marqueur présent dans chaque fichier installé par M2 : un fichier qui le
# contient est « à nous » (pas de sauvegarde, suppression sans risque).
# shellcheck disable=SC2034  # utilisé par les scripts qui chargent ce fichier
RAGO_PROTON_MARKER="rago-proton-layer"

# Fichier des choix de M2 (lu par tous les outils, jamais exécuté).
# shellcheck disable=SC2034
RAGO_PROTON_CONF=/etc/rago/proton-layer.conf

# --- fichiers KEY=valeur (style shell, jamais exécutés) ------------------------------
#   rago_pl_conf_get <fichier> <CLE> [défaut]
rago_pl_conf_get() {
	local file=$1 key=$2 def=${3:-} line val
	line=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1)
	if [ -z "$line" ]; then echo "$def"; return 0; fi
	val=${line#*=}
	val=${val#\"}; val=${val%\"}
	val=${val#\'}; val=${val%\'}
	echo "$val"
}

# Remplace (ou ajoute) CLE="valeur" ; le reste du fichier est gardé tel quel.
#   rago_pl_conf_set <fichier> <CLE> <valeur>
rago_pl_conf_set() {
	local file=$1 key=$2 val=$3 tmp
	case "$val" in *'"'* | *$'\n'*) return 2 ;; esac
	tmp=$(mktemp "${file}.XXXXXX") || return 1
	if [ -f "$file" ]; then
		awk -v k="$key" -v v="$val" '
			BEGIN { done = 0 }
			$0 ~ "^[[:space:]]*" k "=" {
				if (!done) { print k "=\"" v "\""; done = 1 }
				next
			}
			{ print }
			END { if (!done) print k "=\"" v "\"" }
		' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
		chmod --reference="$file" "$tmp" 2>/dev/null || true
	else
		printf '%s="%s"\n' "$key" "$val" > "$tmp"
	fi
	mv "$tmp" "$file"
}

# Valeur oui/non -> 1 ou 0 (code 2 si illisible).
rago_pl_bool() {
	case "${1,,}" in
	1 | yes | oui | true | on) echo 1 ;;
	0 | no | non | false | off) echo 0 ;;
	*) return 2 ;;
	esac
}

# Réglage final : variable d'environnement > fichier utilisateur > fichier
# système > défaut. Les fichiers sont lus, jamais exécutés.
#   rago_pl_setting <CLE> <défaut> <fichier système> [fichier utilisateur]
rago_pl_setting() {
	local key=$1 def=$2 sys=$3 usr=${4:-} v
	if [ -n "${!key+x}" ]; then
		echo "${!key}"
		return 0
	fi
	v=$(rago_pl_conf_get "$sys" "$key" "$def")
	[ -n "$usr" ] && v=$(rago_pl_conf_get "$usr" "$key" "$v")
	echo "$v"
}

# --- identité du jeu ------------------------------------------------------------------
# Exécutable du jeu dans une commande de lancement :
#   1. le premier argument en .exe (Proton : « proton waitforexitandrun …/Jeu.exe ») ;
#   2. sinon l'argument qui suit le dernier « -- » (chaîne Steam :
#      « reaper SteamLaunch AppId=… -- steam-launch-wrapper -- …/jeu.x86_64 ») ;
#   3. sinon la commande elle-même.
# Résultat : nom de base en minuscules (même clé que rago-profiled, M14).
#   rago_pl_exe_key <commande…>
rago_pl_exe_key() {
	local a pick="" after="" seen=0
	[ $# -gt 0 ] || return 1
	for a in "$@"; do
		case "${a,,}" in
		*.exe) pick=$a; break ;;
		esac
	done
	if [ -z "$pick" ]; then
		for a in "$@"; do
			if [ "$seen" = 1 ] && [ -z "$after" ]; then
				case "$a" in --*) ;; *) after=$a ;; esac
			fi
			if [ "$a" = "--" ]; then seen=1; after=""; fi
		done
		pick=${after:-$1}
	fi
	pick=${pick##*/}
	pick=${pick##*\\}
	echo "${pick,,}"
}

# Clé du jeu pour ses caches : steam-<AppID> si Steam l'a posé, sinon
# exe-<exécutable> (caractères sûrs pour un nom de dossier).
#   rago_pl_game_key <appid ou vide> <commande…>
rago_pl_game_key() {
	local appid=$1 exe
	shift
	case "$appid" in
	'' | 0 | *[!0-9]*) ;;
	*) echo "steam-$appid"; return 0 ;;
	esac
	exe=$(rago_pl_exe_key "$@") || return 1
	exe=$(printf '%s' "$exe" | tr -c 'a-z0-9._-' '_')
	echo "exe-${exe:-jeu}"
}

# --- GPU ----------------------------------------------------------------------------------
# GPU voulu d'après l'environnement du jeu :
#   RAGO_GPU (cardN, vendor:device, pci-0000_03_00_0, dgpu, nvidia…) prime ;
#   puis DRI_PRIME (1 = GPU secondaire, ou vendor:device / pci-…) ;
#   puis __NV_PRIME_RENDER_OFFLOAD=1 (GPU NVIDIA) ; sinon vide (GPU principal).
#   rago_pl_gpu_selector <RAGO_GPU> <DRI_PRIME> <__NV_PRIME_RENDER_OFFLOAD>
rago_pl_gpu_selector() {
	if [ -n "$1" ]; then echo "$1"; return 0; fi
	case "$2" in
	'' | 0) ;;
	1) echo dgpu; return 0 ;;
	*) echo "$2"; return 0 ;;
	esac
	if [ "$3" = 1 ]; then echo nvidia; return 0; fi
	echo ""
}

# Cartes DRM d'un sysfs : une ligne « cardN<TAB>pci<TAB>vendor<TAB>device<TAB>pilote<TAB>boot_vga ».
#   rago_pl_gpu_list <sysfs>
rago_pl_gpu_list() {
	local sys=${1%/} c n dev pci ven did drv bv
	for c in "$sys"/class/drm/card[0-9]*; do
		[ -e "$c" ] || continue
		n=${c##*/}
		case "$n" in *-*) continue ;; esac # connecteurs (card0-HDMI-A-1)
		dev="$c/device"
		[ -r "$dev/vendor" ] || continue
		pci=$(readlink "$dev" 2>/dev/null); pci=${pci##*/}
		ven=$(cat "$dev/vendor"); ven=${ven#0x}
		did=$(cat "$dev/device" 2>/dev/null || echo 0000); did=${did#0x}
		drv=$(readlink "$dev/driver" 2>/dev/null); drv=${drv##*/}
		bv=$(cat "$dev/boot_vga" 2>/dev/null || echo 0)
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "${pci:-?}" "${ven,,}" "${did,,}" "${drv:-inconnu}" "$bv"
	done
}

# Clé du GPU (« pilote-vendor-device », ex. amdgpu-1002-744c) ; « aucun-gpu »
# s'il n'y a pas de carte (conteneur, VM sans GPU).
#   rago_pl_gpu_key <sysfs> [sélecteur]
rago_pl_gpu_key() {
	local sys=$1 sel=${2:-} list line pick="" n pci ven did drv bv want
	list=$(rago_pl_gpu_list "$sys")
	if [ -z "$list" ]; then echo aucun-gpu; return 0; fi
	while IFS=$'\t' read -r n pci ven did drv bv; do
		case "$sel" in
		'') [ "$bv" = 1 ] && { pick="$drv-$ven-$did"; break; } ;;
		dgpu) [ "$bv" != 1 ] && { pick="$drv-$ven-$did"; break; } ;;
		card[0-9]*) [ "$n" = "$sel" ] && { pick="$drv-$ven-$did"; break; } ;;
		pci-*)
			want=${sel#pci-}; want=${want//_/:}
			# pci-0000_03_00_0 -> 0000:03:00.0
			want="${want%:*}.${want##*:}"
			[ "$pci" = "$want" ] && { pick="$drv-$ven-$did"; break; } ;;
		*:*) [ "$ven:$did" = "${sel,,}" ] && { pick="$drv-$ven-$did"; break; } ;;
		*) [ "$drv" = "$sel" ] && { pick="$drv-$ven-$did"; break; } ;;
		esac
	done <<< "$list"
	if [ -z "$pick" ]; then
		# Sélecteur sans correspondance ou pas de boot_vga : première carte.
		line=${list%%$'\n'*}
		IFS=$'\t' read -r n pci ven did drv bv <<< "$line"
		pick="$drv-$ven-$did"
	fi
	echo "$pick"
}

# Empreinte des pilotes Vulkan (change quand un pilote est mis à jour : le cache
# doit alors être pré-chauffé de nouveau). Lit les manifestes ICD et la taille /
# date de chaque bibliothèque, plus la version du module nvidia.
#   rago_pl_driver_fingerprint <racine> <sysfs>
rago_pl_driver_fingerprint() {
	local root=${1%/} sys=${2%/} j lib p d found
	{
		for j in "$root"/usr/share/vulkan/icd.d/*.json "$root"/etc/vulkan/icd.d/*.json; do
			[ -r "$j" ] || continue
			lib=$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$j" | head -1)
			found=""
			case "$lib" in
			/*) [ -e "$root$lib" ] && found="$root$lib" ;;
			?*)
				for d in /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu; do
					if [ -e "$root$d/$lib" ]; then found="$root$d/$lib"; break; fi
				done ;;
			esac
			if [ -n "$found" ]; then
				p=$(stat -L -c '%s %Y' "$found" 2>/dev/null || echo "? ?")
			else
				p="absent"
			fi
			printf '%s %s %s\n' "${j##*/}" "$lib" "$p"
		done
		[ -r "$sys/module/nvidia/version" ] && printf 'nvidia %s\n' "$(cat "$sys/module/nvidia/version")"
	} | sha256sum | cut -c1-16
}

# --- caches de shaders ----------------------------------------------------------------
# Taille lisible (500M, 4G, 1024) -> octets.
rago_pl_size_bytes() {
	local v=${1^^} n m=1
	case "$v" in
	*K) n=${v%K}; m=1024 ;;
	*M) n=${v%M}; m=$((1024 * 1024)) ;;
	*G) n=${v%G}; m=$((1024 * 1024 * 1024)) ;;
	*) n=$v ;;
	esac
	case "$n" in '' | *[!0-9]*) return 2 ;; esac
	echo $((n * m))
}

# Variables des caches de pilotes d'un jeu (une par ligne, CLE=valeur). Le
# lanceur ne les pose que si elles sont absentes : Steam ou Proton gardent la
# main sur les leurs.
#   rago_pl_cache_env <dossier du jeu> <taille>
rago_pl_cache_env() {
	local d=$1 size=$2 bytes
	bytes=$(rago_pl_size_bytes "$size") || return 2
	printf 'MESA_SHADER_CACHE_DIR=%s\n' "$d/mesa"
	printf 'MESA_SHADER_CACHE_MAX_SIZE=%s\n' "${size^^}"
	printf '__GL_SHADER_DISK_CACHE=1\n'
	printf '__GL_SHADER_DISK_CACHE_PATH=%s\n' "$d/nvidia"
	printf '__GL_SHADER_DISK_CACHE_SIZE=%s\n' "$bytes"
	printf '__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1\n'
	printf 'DXVK_STATE_CACHE_PATH=%s\n' "$d/dxvk"
	printf 'VKD3D_SHADER_CACHE_PATH=%s\n' "$d/vkd3d"
}

# Variables qui changent ce que le pilote compile ou où il le range : ce sont
# celles que le pré-chauffage doit reproduire pour remplir le même cache que le
# jeu. Code 0 si <CLE> en fait partie.
rago_pl_cache_var() {
	case "$1" in
	MESA_* | __GL_* | RADV_* | ANV_* | NVK_* | DRI_PRIME | __NV_PRIME_RENDER_OFFLOAD | \
		__VK_LAYER_NV_optimus | VK_ICD_FILENAMES | VK_DRIVER_FILES | \
		STEAM_COMPAT_SHADER_PATH | DXVK_STATE_CACHE_PATH | VKD3D_SHADER_CACHE_PATH) return 0 ;;
	*) return 1 ;;
	esac
}

# --- jeux en cours (pause du pré-chauffage) -----------------------------------------
# Date de départ d'un processus (champ 22 de /proc/PID/stat ; le nom peut
# contenir des espaces et des parenthèses, on coupe après la dernière « ) »).
#   rago_pl_proc_starttime <pid> <procfs>
rago_pl_proc_starttime() {
	local s
	s=$(cat "${2%/}/$1/stat" 2>/dev/null) || return 1
	s=${s##*) }
	# Après « ) » : champ 3 (état) … champ 22 (starttime) = 20e mot.
	# shellcheck disable=SC2086
	set -- $s
	[ $# -ge 20 ] || return 1
	echo "${20}"
}

# Un jeu lancé par rago-launch tourne-t-il encore ? Chaque jeu laisse un
# fichier <dossier>/<pid> contenant la date de départ du processus : un PID
# mort ou réutilisé ne compte pas.
#   rago_pl_games_active <dossier> <procfs>
rago_pl_games_active() {
	local dir=$1 proc=$2 f pid want got
	for f in "$dir"/*; do
		[ -f "$f" ] || continue
		pid=${f##*/}
		case "$pid" in '' | *[!0-9]*) continue ;; esac
		want=$(head -1 "$f" 2>/dev/null)
		got=$(rago_pl_proc_starttime "$pid" "$proc") || continue
		[ "$got" = "$want" ] && return 0
	done
	return 1
}

# --- Steam ----------------------------------------------------------------------------
# Dossier racine de Steam d'un utilisateur (vide si absent). Steam d'Arch :
# ~/.local/share/Steam ; steam-installer de Debian/Ubuntu :
# ~/.steam/debian-installation ; ~/.steam/root pointe vers le bon.
#   rago_pl_steam_root <home>
rago_pl_steam_root() {
	local h=${1%/} d
	for d in "$h/.steam/root" "$h/.local/share/Steam" "$h/.steam/debian-installation" "$h/.steam/steam"; do
		if [ -d "$d/steamapps" ] || [ -e "$d/steam.sh" ] || [ -d "$d/ubuntu12_32" ]; then
			(cd "$d" && pwd -P)
			return 0
		fi
	done
	return 1
}

# fossilize-replay à utiliser : RAGO_FOSSILIZE_REPLAY, celui du système, sinon
# celui que Steam fournit (ubuntu12_64/fossilize_replay).
#   rago_pl_fossilize_bin <racine Steam ou vide>
rago_pl_fossilize_bin() {
	local b
	if [ -n "${RAGO_FOSSILIZE_REPLAY:-}" ]; then
		[ -x "$RAGO_FOSSILIZE_REPLAY" ] && { echo "$RAGO_FOSSILIZE_REPLAY"; return 0; }
		return 1
	fi
	for b in fossilize-replay fossilize_replay; do
		command -v "$b" 2>/dev/null && return 0
	done
	if [ -n "${1:-}" ] && [ -x "$1/ubuntu12_64/fossilize_replay" ]; then
		echo "$1/ubuntu12_64/fossilize_replay"
		return 0
	fi
	return 1
}

# --- versions épinglées (host/proton/sources.lock) --------------------------------
# Format d'une ligne : <nom> <version> <url> <empreinte>
#   empreinte = sha512:<hex> | sha256:<hex> | PENDING (jamais vérifiée)
#   rago_pl_lock_get <fichier> <nom>   -> « version url empreinte »
rago_pl_lock_get() {
	awk -v n="$2" '$1 == n && $0 !~ /^[[:space:]]*#/ { print $2, $3, $4; found = 1; exit } END { exit !found }' "$1"
}

# Le fichier a-t-il l'empreinte attendue ? (code 2 : empreinte PENDING ou illisible)
#   rago_pl_hash_ok <fichier> <empreinte>
rago_pl_hash_ok() {
	local f=$1 spec=$2 algo want got
	algo=${spec%%:*}
	want=${spec#*:}
	case "$algo" in
	sha512) got=$(sha512sum "$f" | cut -d' ' -f1) ;;
	sha256) got=$(sha256sum "$f" | cut -d' ' -f1) ;;
	*) return 2 ;;
	esac
	case "$want" in '' | *[!0-9a-f]*) return 2 ;; esac
	[ "$got" = "$want" ]
}

# Nom interne d'un outil de compatibilité Steam (clé sous « compat_tools » de
# compatibilitytool.vdf) : c'est ce nom que Steam mémorise.
#   rago_pl_compat_tool_name <compatibilitytool.vdf>
rago_pl_compat_tool_name() {
	awk '
		BEGIN { depth = 0; in_tools = 0 }
		{
			line = $0
			while (length(line) > 0) {
				if (match(line, /^[[:space:]]+/)) { line = substr(line, RLENGTH + 1); continue }
				if (substr(line, 1, 2) == "//") break
				c = substr(line, 1, 1)
				if (c == "{") { depth++; line = substr(line, 2); continue }
				if (c == "}") { depth--; if (in_tools && depth < tools_depth) in_tools = 0; line = substr(line, 2); continue }
				if (c == "\"") {
					rest = substr(line, 2); i = index(rest, "\"")
					tok = substr(rest, 1, i - 1); line = substr(rest, i + 1)
				} else {
					match(line, /^[^[:space:]{}]+/); tok = substr(line, 1, RLENGTH); line = substr(line, RLENGTH + 1)
				}
				if (tolower(tok) == "compat_tools") { in_tools = 1; tools_depth = depth + 1; want_key = 1; continue }
				if (in_tools && depth == tools_depth && want_key) { print tok; exit }
			}
		}
	' "$1"
}

# --- session gamescope -------------------------------------------------------------
# Arguments de gamescope pour la session, un par ligne, d'après les variables
# RAGO_SESSION_* (déjà lues) :
#   WIDTH HEIGHT REFRESH (vides = mode natif de l'écran), VRR HDR HDR_ITM
#   TEARING RT MANGOAPP (0/1), OUTPUT (connecteurs préférés), VK_DEVICE
#   (vendor:device), BACKEND (drm, sdl, wayland, headless ; vide = auto),
#   NESTED (1 = fenêtre plein écran dans un bureau, pour essayer), EXTRA_ARGS.
# Puis « -- » et la commande de Steam (RAGO_SESSION_STEAM_CMD).
rago_pl_gamescope_args() {
	local a
	echo "-e" # intégration Steam (focus, overlay, réglages de la session)
	echo "--xwayland-count"; echo 2
	[ -n "${RAGO_SESSION_WIDTH:-}" ] && { echo "-W"; echo "$RAGO_SESSION_WIDTH"; }
	[ -n "${RAGO_SESSION_HEIGHT:-}" ] && { echo "-H"; echo "$RAGO_SESSION_HEIGHT"; }
	[ -n "${RAGO_SESSION_REFRESH:-}" ] && { echo "-r"; echo "$RAGO_SESSION_REFRESH"; }
	[ "${RAGO_SESSION_VRR:-1}" = 1 ] && echo "--adaptive-sync"
	[ "${RAGO_SESSION_HDR:-1}" = 1 ] && echo "--hdr-enabled"
	[ "${RAGO_SESSION_HDR:-1}" = 1 ] && [ "${RAGO_SESSION_HDR_ITM:-0}" = 1 ] && echo "--hdr-itm-enable"
	[ "${RAGO_SESSION_TEARING:-1}" = 1 ] && echo "--immediate-flips"
	[ "${RAGO_SESSION_RT:-1}" = 1 ] && echo "--rt"
	[ "${RAGO_SESSION_MANGOAPP:-1}" = 1 ] && echo "--mangoapp"
	[ -n "${RAGO_SESSION_OUTPUT:-}" ] && { echo "-O"; echo "$RAGO_SESSION_OUTPUT"; }
	[ -n "${RAGO_SESSION_VK_DEVICE:-}" ] && { echo "--prefer-vk-device"; echo "$RAGO_SESSION_VK_DEVICE"; }
	[ -n "${RAGO_SESSION_BACKEND:-}" ] && { echo "--backend"; echo "$RAGO_SESSION_BACKEND"; }
	[ "${RAGO_SESSION_NESTED:-0}" = 1 ] && echo "-f"
	# shellcheck disable=SC2086  # découpage voulu : options libres de l'utilisateur
	for a in ${RAGO_SESSION_EXTRA_ARGS:-}; do echo "$a"; done
	echo "--"
	# shellcheck disable=SC2086
	for a in ${RAGO_SESSION_STEAM_CMD:-steam -gamepadui}; do echo "$a"; done
}

# Environnement de Steam dans la session (une variable par ligne). Les
# variables STEAM_GAMESCOPE_* disent à Steam ce que la session sait faire
# (réglages VRR / HDR / tearing visibles dans le menu rapide).
rago_pl_session_env() {
	echo "RAGO_SESSION=1"
	echo "XDG_CURRENT_DESKTOP=gamescope"
	echo "SRT_URLOPEN_PREFER_STEAM=1"
	echo "STEAM_MULTIPLE_XWAYLANDS=1"
	echo "STEAM_ENABLE_VOLUME_HANDLER=1"
	echo "STEAM_GAMESCOPE_NIS_SUPPORTED=1"
	echo "STEAM_GAMESCOPE_FANCY_SCALING_SUPPORT=1"
	echo "STEAM_GAMESCOPE_COLOR_MANAGED=1"
	echo "STEAM_GAMESCOPE_VIRTUAL_WHITE=1"
	echo "ENABLE_GAMESCOPE_WSI=1"
	echo "vk_xwayland_wait_ready=false"
	if [ "${RAGO_SESSION_VRR:-1}" = 1 ]; then
		echo "STEAM_GAMESCOPE_VRR_SUPPORTED=1"
	fi
	if [ "${RAGO_SESSION_HDR:-1}" = 1 ]; then
		echo "STEAM_GAMESCOPE_HDR_SUPPORTED=1"
		echo "DXVK_HDR=1"
	fi
	if [ "${RAGO_SESSION_TEARING:-1}" = 1 ]; then
		echo "STEAM_GAMESCOPE_TEARING_SUPPORTED=1"
		echo "STEAM_GAMESCOPE_HAS_TEARING_SUPPORT=1"
	fi
	if [ "${RAGO_SESSION_MANGOAPP:-1}" = 1 ]; then
		echo "RAGO_SESSION_MANGOAPP=1"
		echo "STEAM_USE_MANGOAPP=1"
		echo "STEAM_MANGOAPP_PRESETS_SUPPORTED=1"
		echo "STEAM_DISABLE_MANGOAPP_ATOM_WORKAROUND=1"
	fi
}
