#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — couche native Proton (module M2).
#
# Installe et règle :
#   - Steam, gamemode, MangoHud, gamescope (paquets : commande deps) ;
#   - Proton-GE ÉPINGLÉ (host/proton/sources.lock, empreinte vérifiée) dans
#     /usr/share/steam/compatibilitytools.d/, proposé comme outil Steam par
#     défaut si le joueur n'en a pas choisi ;
#   - Heroic (Epic / GOG), version épinglée ; Lutris en option (--lutris) ;
#   - runtimes Proton EasyAntiCheat / BattlEye : Steam les installe avec le
#     premier jeu qui en a besoin ; rago-launch les donne aussi aux jeux hors
#     Steam (Heroic, Lutris) ;
#   - le hook de lancement /usr/bin/rago-launch : caches de shaders par GPU,
#     gamemode + MangoHud, puis rago-profiled launch (M14 : profil du jeu par-dessus
#     la base M1) qui passe par rago-sched-hint run (M0 : hint ordonnanceur) ;
#   - le pré-chauffage des shaders (/usr/bin/rago-shader-cache, Fossilize,
#     service utilisateur rago-shader-prewarm) ;
#   - la session plein écran console /usr/bin/rago-session (gamescope : VRR,
#     HDR, tearing en jeu, --rt) et son entrée de connexion ;
#   - /etc/gamemode.ini + règle polkit : gamemode ne touche ni au gouverneur
#     (M14/M1), ni aux cœurs (M0), ni au GPU (M9), ni au split lock (M1) ;
#   - /etc/MangoHud.conf (HUD compact : FPS, 1 % low, temps d'image).
#
# Usage : setup_proton_layer.sh [options] [commande]
#
# Commandes :
#   install     (défaut) installe et règle tout ; root
#   verify      vérifie ce qui est en place (code 0 = bon, 1 = échec)
#   status      comme verify
#   uninstall   retire tout ce que M2 a posé (garde les caches de shaders) ; root
#   deps        installe les paquets (pacman ou apt) ; root
#   lock        épingle Proton-GE et Heroic (accès GitHub ; écrit sources.lock)
#   user        côté joueur (sans root, Steam fermé) : hook dans Steam, Heroic,
#               Lutris, puis vérifications du compte ; --remove pour retirer
#
# Options d'install (mémorisées dans /etc/rago/proton-layer.conf) :
#   --no-proton-ge         ne pas installer Proton-GE
#   --default-proton ge|keep   ge (défaut) = Proton-GE épinglé par défaut dans
#                          Steam si le joueur n'a rien choisi ; keep = ne pas toucher
#   --no-heroic            ne pas installer / brancher Heroic
#   --lutris | --no-lutris Lutris (défaut : non)
#   --no-gamemode          rago-launch sans gamemode
#   --no-mangohud          rago-launch sans MangoHud
#   --no-session           pas de session gamescope
#   --no-rt                pas de cap_sys_nice sur gamescope (--rt sans effet)
#   --no-steam-hook        ne pas écrire rago-launch dans les options Steam
#   --shader-prewarm background|before|off   (défaut background)
#   --shader-cache-root DIR   (défaut ~/.local/share/rago/shader-cache ; M7 : RAGO-LIB)
#   --shader-cache-size TAILLE   par jeu (défaut 4G)
#   --proton-ge-file F     archive Proton-GE déjà téléchargée (vérifiée quand même)
#   --heroic-file F        paquet Heroic déjà téléchargé (vérifié quand même)
# Options de deps : --enable-32bit (active multilib / i386, nécessaire à Steam)
# Options de lock : --proton-ge GE-ProtonX-Y  --heroic vX.Y.Z (défaut : dernière)
# Options de user : --remove
# Générales :
#   --root DIR   installe dans une racine de test (implique --no-apply)
#   --no-apply   écrit les fichiers sans appliquer (pas de setcap, pas de paquet)
#   --dry-run    affiche les actions sans rien faire
#   -h, --help
#
# EN ATTENTE DE MATÉRIEL : affichage plein écran, VRR, HDR, tearing, --rt,
# FPS / 1 % low et effet du pré-chauffage ne se vérifient que sur la vraie machine.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib/rago_proton_lib.sh
. "$here/lib/rago_proton_lib.sh"

LOCK=${RAGO_PROTON_LOCK:-$here/proton/sources.lock} # RAGO_PROTON_LOCK : tests
SRC_LAUNCH="$here/proton/rago-launch.sh"
SRC_SHADER="$here/proton/rago-shader-cache.sh"
SRC_STEAMCFG="$here/proton/rago_steam_config.py"
SRC_SESSION="$here/gamescope/rago-session.sh"
SRC_DESKTOP="$here/gamescope/rago.desktop"
SRC_GAMEMODE="$here/gamemode/gamemode.ini"
SRC_POLKIT="$here/gamemode/40-rago-gamemode.rules"
SRC_MANGOHUD="$here/mangohud/MangoHud.conf"
SRC_UNIT="$here/systemd/user/rago-shader-prewarm.service"
SRC_PACHOOK="$here/pacman/rago-gamescope-cap.hook"
SRC_LIB="$here/lib/rago_proton_lib.sh"

P_CONF=$RAGO_PROTON_CONF
P_STATE=/var/lib/rago/proton-layer
P_CACHE=/var/cache/rago/proton-layer
P_LIB=/usr/lib/rago/rago_proton_lib.sh
P_LAUNCH=/usr/bin/rago-launch
P_SHADER=/usr/bin/rago-shader-cache
P_STEAMCFG=/usr/bin/rago-steam-config
P_SESSION=/usr/bin/rago-session
P_DESKTOP=/usr/share/wayland-sessions/rago.desktop
P_GAMEMODE=/etc/gamemode.ini
P_POLKIT=/etc/polkit-1/rules.d/40-rago-gamemode.rules
P_MANGOHUD=/etc/MangoHud.conf
P_UNIT=/usr/lib/systemd/user/rago-shader-prewarm.service
P_PACHOOK=/etc/pacman.d/hooks/rago-gamescope-cap.hook
P_COMPAT=/usr/share/steam/compatibilitytools.d
GE_MARK=.rago-proton-layer

root=/
apply=1
dry_run=0
cmd=""
remove=0
enable_32bit=0
lock_ge="" lock_heroic=""
ge_file="" heroic_file=""
o_ge="" o_default="" o_heroic="" o_lutris="" o_gamemode="" o_mangohud="" o_session="" o_rt=""
o_hook="" o_prewarm="" o_croot="" o_csize=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n "3,/^set -euo/p" "$0" | sed -e "\$d" -e "s/^# \{0,1\}//"; }
val() { [ $# -ge 2 ] || die "$1 attend une valeur"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--no-proton-ge) o_ge=0; shift ;;
	--default-proton) val "$@"; o_default=$2; shift 2 ;;
	--no-heroic) o_heroic=0; shift ;;
	--lutris) o_lutris=1; shift ;;
	--no-lutris) o_lutris=0; shift ;;
	--no-gamemode) o_gamemode=0; shift ;;
	--no-mangohud) o_mangohud=0; shift ;;
	--no-session) o_session=0; shift ;;
	--no-rt) o_rt=0; shift ;;
	--no-steam-hook) o_hook=0; shift ;;
	--shader-prewarm) val "$@"; o_prewarm=$2; shift 2 ;;
	--shader-cache-root) val "$@"; o_croot=$2; shift 2 ;;
	--shader-cache-size) val "$@"; o_csize=$2; shift 2 ;;
	--proton-ge-file) val "$@"; ge_file=$2; shift 2 ;;
	--heroic-file) val "$@"; heroic_file=$2; shift 2 ;;
	--enable-32bit) enable_32bit=1; shift ;;
	--proton-ge) val "$@"; lock_ge=$2; shift 2 ;;
	--heroic) val "$@"; lock_heroic=$2; shift 2 ;;
	--remove) remove=1; shift ;;
	--root) val "$@"; root=$2; shift 2 ;;
	--no-apply) apply=0; shift ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) usage; exit 0 ;;
	install | verify | status | uninstall | deps | lock | user)
		[ -z "$cmd" ] || die "une seule commande à la fois ($cmd, $1)"
		cmd=$1; shift ;;
	*) die "option ou commande inconnue : $1 (--help)" ;;
	esac
done
cmd=${cmd:-install}

root=${root%/}
[ -z "$root" ] || [ -d "$root" ] || die "--root : dossier introuvable : $root"
[ -z "$root" ] || apply=0
R=$root

# --- utilitaires ---------------------------------------------------------------------------
run() {
	if [ "$dry_run" = 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}
need_root() {
	[ "$dry_run" = 1 ] && return 0
	[ -n "$R" ] && return 0
	[ "$(id -u)" -eq 0 ] || die "« $1 » doit être lancé en root (sudo)"
}
have() { command -v "$1" >/dev/null 2>&1; }
state() { echo "$R$P_STATE/$1"; }
backup_path() { local p=${1#/}; echo "$(state backup)/${p//\//%}"; }
is_ours() { grep -qs "$RAGO_PROTON_MARKER" "$1"; }
manifest_add() {
	local m
	m=$(state manifest)
	grep -qxF "$1" "$m" 2>/dev/null || echo "$1" >> "$m"
}

# Écrit l'entrée standard dans <chemin> (atomique), en sauvegardant d'abord
# un fichier existant qui n'est pas à nous.
#   put_file <chemin cible sans racine> <mode>
put_file() {
	local p=$1 mode=$2 dst="$R$1" tmp b
	if [ "$dry_run" = 1 ]; then
		cat > /dev/null
		printf '[dry-run] écrire %s (%s)\n' "$dst" "$mode"
		return 0
	fi
	mkdir -p "$(dirname "$dst")"
	if [ -e "$dst" ] && ! is_ours "$dst"; then
		b=$(backup_path "$p")
		if [ ! -e "$b" ]; then
			mkdir -p "$(dirname "$b")"
			cp -a "$dst" "$b"
			log "sauvegarde de $p (remis à la désinstallation)"
		fi
	fi
	tmp=$(mktemp "$dst.rago.XXXXXX")
	if ! cat > "$tmp"; then rm -f "$tmp"; die "écriture impossible : $dst"; fi
	chmod "$mode" "$tmp"
	mv -f "$tmp" "$dst"
	manifest_add "$p"
}

remove_file() {
	local p=$1 dst="$R$1" b
	b=$(backup_path "$p")
	if [ -e "$dst" ] && ! is_ours "$dst"; then
		warn "$p ne vient pas de Rago (modifié à la main ?) : laissé en place"
		return 0
	fi
	if [ "$dry_run" = 1 ]; then printf '[dry-run] retirer %s\n' "$dst"; return 0; fi
	rm -f "$dst"
	if [ -e "$b" ]; then
		mv -f "$b" "$dst"
		log "remis : $p"
	fi
}

# --- réglages (défauts < /etc/rago/proton-layer.conf < options) ----------------------
load_settings() {
	local c="$R$P_CONF" k
	S_GE=$(rago_pl_conf_get "$c" RAGO_PROTON_GE 1)
	S_DEFAULT=$(rago_pl_conf_get "$c" RAGO_DEFAULT_PROTON ge)
	S_HEROIC=$(rago_pl_conf_get "$c" RAGO_HEROIC 1)
	S_LUTRIS=$(rago_pl_conf_get "$c" RAGO_LUTRIS 0)
	S_GAMEMODE=$(rago_pl_conf_get "$c" RAGO_GAMEMODE 1)
	S_MANGOHUD=$(rago_pl_conf_get "$c" RAGO_MANGOHUD 1)
	S_SESSION=$(rago_pl_conf_get "$c" RAGO_INSTALL_SESSION 1)
	S_RT=$(rago_pl_conf_get "$c" RAGO_SESSION_RT 1)
	S_HOOK=$(rago_pl_conf_get "$c" RAGO_STEAM_HOOK 1)
	S_PREWARM=$(rago_pl_conf_get "$c" RAGO_SHADER_PREWARM background)
	S_CROOT=$(rago_pl_conf_get "$c" RAGO_SHADER_CACHE_ROOT "")
	S_CSIZE=$(rago_pl_conf_get "$c" RAGO_SHADER_CACHE_SIZE 4G)
	S_GE_NAME=$(rago_pl_conf_get "$c" RAGO_PROTON_GE_NAME "")
	[ -n "$o_ge" ] && S_GE=$o_ge
	[ -n "$o_default" ] && S_DEFAULT=$o_default
	[ -n "$o_heroic" ] && S_HEROIC=$o_heroic
	[ -n "$o_lutris" ] && S_LUTRIS=$o_lutris
	[ -n "$o_gamemode" ] && S_GAMEMODE=$o_gamemode
	[ -n "$o_mangohud" ] && S_MANGOHUD=$o_mangohud
	[ -n "$o_session" ] && S_SESSION=$o_session
	[ -n "$o_rt" ] && S_RT=$o_rt
	[ -n "$o_hook" ] && S_HOOK=$o_hook
	[ -n "$o_prewarm" ] && S_PREWARM=$o_prewarm
	[ -n "$o_croot" ] && S_CROOT=$o_croot
	[ -n "$o_csize" ] && S_CSIZE=$o_csize
	for k in "$S_GE" "$S_HEROIC" "$S_LUTRIS" "$S_GAMEMODE" "$S_MANGOHUD" "$S_SESSION" "$S_RT" "$S_HOOK"; do
		case "$k" in 0 | 1) ;; *) die "valeur invalide dans $P_CONF : « $k » (0 ou 1)" ;; esac
	done
	case "$S_DEFAULT" in ge | keep) ;; *) die "--default-proton invalide : $S_DEFAULT (ge|keep)" ;; esac
	case "$S_PREWARM" in background | before | off) ;; *) die "--shader-prewarm invalide : $S_PREWARM (background|before|off)" ;; esac
	rago_pl_size_bytes "$S_CSIZE" >/dev/null || die "--shader-cache-size invalide : $S_CSIZE (ex. 4G, 500M)"
	case "$S_CROOT" in '' | /*) ;; *) die "--shader-cache-root : chemin absolu attendu ($S_CROOT)" ;; esac
	case "$S_CROOT" in *'"'* | *' '*) die "--shader-cache-root : pas d'espace ni de guillemet ($S_CROOT)" ;; esac
}

save_settings() {
	local c="$R$P_CONF"
	if [ "$dry_run" = 1 ]; then printf '[dry-run] écrire %s\n' "$c"; return 0; fi
	mkdir -p "$(dirname "$c")"
	if [ ! -f "$c" ]; then
		cat > "$c" <<-EOF
		# Rago OS — choix de la couche Proton (module M2). Marqueur : $RAGO_PROTON_MARKER
		# Relu par host/setup_proton_layer.sh, rago-launch, rago-session et
		# rago-shader-cache (jamais exécuté). Un joueur peut surcharger chaque clé
		# dans ~/.config/rago/proton-layer.conf, ou pour un jeu dans l'option de
		# lancement : RAGO_MANGOHUD=0 rago-launch %command%
		#   RAGO_PROTON_GE 1|0         RAGO_DEFAULT_PROTON ge|keep
		#   RAGO_HEROIC 1|0            RAGO_LUTRIS 1|0
		#   RAGO_GAMEMODE 1|0          RAGO_MANGOHUD 1|0
		#   RAGO_INSTALL_SESSION 1|0   RAGO_STEAM_HOOK 1|0
		#   RAGO_SHADER_PREWARM background|before|off
		#   RAGO_SHADER_CACHE_ROOT DIR (vide = ~/.local/share/rago/shader-cache)
		#   RAGO_SHADER_CACHE_SIZE 4G  (par jeu)
		# Session gamescope (vide = valeur par défaut) :
		#   RAGO_SESSION_VRR 1  RAGO_SESSION_HDR 1  RAGO_SESSION_HDR_ITM 0
		#   RAGO_SESSION_TEARING 1  RAGO_SESSION_RT 1  RAGO_SESSION_MANGOAPP 1
		#   RAGO_SESSION_WIDTH / RAGO_SESSION_HEIGHT / RAGO_SESSION_REFRESH (vide = natif)
		#   RAGO_SESSION_OUTPUT  RAGO_SESSION_VK_DEVICE  RAGO_SESSION_BACKEND
		#   RAGO_SESSION_STEAM_CMD "steam -gamepadui"  RAGO_SESSION_EXTRA_ARGS
		EOF
	fi
	rago_pl_conf_set "$c" RAGO_PROTON_GE "$S_GE"
	rago_pl_conf_set "$c" RAGO_DEFAULT_PROTON "$S_DEFAULT"
	rago_pl_conf_set "$c" RAGO_HEROIC "$S_HEROIC"
	rago_pl_conf_set "$c" RAGO_LUTRIS "$S_LUTRIS"
	rago_pl_conf_set "$c" RAGO_GAMEMODE "$S_GAMEMODE"
	rago_pl_conf_set "$c" RAGO_MANGOHUD "$S_MANGOHUD"
	rago_pl_conf_set "$c" RAGO_INSTALL_SESSION "$S_SESSION"
	rago_pl_conf_set "$c" RAGO_SESSION_RT "$S_RT"
	rago_pl_conf_set "$c" RAGO_STEAM_HOOK "$S_HOOK"
	rago_pl_conf_set "$c" RAGO_SHADER_PREWARM "$S_PREWARM"
	rago_pl_conf_set "$c" RAGO_SHADER_CACHE_ROOT "$S_CROOT"
	rago_pl_conf_set "$c" RAGO_SHADER_CACHE_SIZE "$S_CSIZE"
	rago_pl_conf_set "$c" RAGO_PROTON_GE_NAME "$S_GE_NAME"
}

pkg_manager() {
	if have pacman; then echo pacman; elif have apt-get; then echo apt; else echo ""; fi
}

# --- deps ----------------------------------------------------------------------------------
step_deps() {
	need_root deps
	[ -z "$R" ] || die "deps ne marche pas avec --root"
	load_settings
	local pm pkgs
	pm=$(pkg_manager)
	case "$pm" in
	pacman)
		if ! grep -qE '^[[:space:]]*\[multilib\]' /etc/pacman.conf; then
			[ "$enable_32bit" = 1 ] || die "le dépôt multilib (bibliothèques 32 bits de Steam) n'est pas activé : relancer avec --enable-32bit, ou décommenter [multilib] dans /etc/pacman.conf"
			log "activation du dépôt multilib dans /etc/pacman.conf"
			[ "$dry_run" = 1 ] || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
			run pacman -Sy
		fi
		pkgs="steam gamemode lib32-gamemode mangohud lib32-mangohud python polkit libcap curl tar vulkan-icd-loader lib32-vulkan-icd-loader"
		[ "$S_SESSION" = 1 ] && pkgs="$pkgs gamescope"
		[ "$S_LUTRIS" = 1 ] && pkgs="$pkgs lutris python-yaml"
		# shellcheck disable=SC2086
		run pacman -S --needed --noconfirm $pkgs
		;;
	apt)
		if ! dpkg --print-foreign-architectures | grep -qx i386; then
			[ "$enable_32bit" = 1 ] || die "l'architecture i386 (bibliothèques 32 bits de Steam) n'est pas activée : relancer avec --enable-32bit, ou : dpkg --add-architecture i386 && apt-get update"
			run dpkg --add-architecture i386
			run apt-get update
		fi
		pkgs="steam-installer gamemode mangohud python3 polkitd pkexec libcap2-bin curl tar ca-certificates"
		if [ "$S_SESSION" = 1 ]; then
			if apt-cache policy gamescope 2>/dev/null | grep -q 'Candidate: [0-9]'; then
				pkgs="$pkgs gamescope"
			else
				warn "gamescope n'est pas dans les dépôts de cette distribution : session plein écran impossible ici"
			fi
		fi
		[ "$S_LUTRIS" = 1 ] && pkgs="$pkgs lutris python3-yaml"
		# Steam demande d'accepter sa licence (debconf) : pas en silence.
		# shellcheck disable=SC2086
		run apt-get install -y $pkgs
		;;
	*) die "ni pacman ni apt-get : installer Steam, gamemode, MangoHud et gamescope à la main" ;;
	esac
	log "paquets installés ; ensuite : sudo $0 install"
}

# --- lock (épinglage, accès GitHub) --------------------------------------------------
gh_json() { # gh_json <dépôt> <tag ou vide>
	local api=${RAGO_GITHUB_API:-https://api.github.com} path
	if [ -n "$2" ]; then path="releases/tags/$2"; else path="releases/latest"; fi
	curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' "$api/repos/$1/$path"
}

# Champ d'une release : tag, ou URL du premier fichier dont le nom finit par <suffixe>.
json_field() { # json_field <tag|asset> [suffixe]  (JSON sur l'entrée standard)
	python3 -c '
import json, sys
d = json.load(sys.stdin)
if sys.argv[1] == "tag":
    print(d["tag_name"])
else:
    for a in d.get("assets", []):
        if a["name"].endswith(sys.argv[2]):
            print(a["browser_download_url"]); break
' "$@"
}

lock_set() { # lock_set <nom> <version> <url> <empreinte>
	local tmp
	tmp=$(mktemp "$LOCK.XXXXXX")
	awk -v n="$1" -v line="$1 $2 $3 $4" '$1 == n && $0 !~ /^#/ { print line; done = 1; next } { print } END { if (!done) print line }' "$LOCK" > "$tmp"
	mv "$tmp" "$LOCK"
	log "épinglé : $1 $2 ($4)"
}

step_lock() {
	have curl || die "curl absent"
	have python3 || die "python3 absent"
	local work j tag url sumurl f want got
	work=$(mktemp -d)
	trap 'rm -rf "$work"' RETURN
	# Proton-GE : archive vérifiée contre le .sha512sum publié avec la release.
	j=$(gh_json GloriousEggroll/proton-ge-custom "$lock_ge") || die "release Proton-GE introuvable (GitHub joignable ?)"
	tag=$(printf '%s' "$j" | json_field tag)
	url=$(printf '%s' "$j" | json_field asset ".tar.gz")
	sumurl=$(printf '%s' "$j" | json_field asset ".sha512sum")
	{ [ -n "$url" ] && [ -n "$sumurl" ]; } || die "release $tag : archive ou .sha512sum manquant"
	f="$work/${url##*/}"
	log "téléchargement de $tag"
	curl -fL --retry 3 -o "$f" "$url"
	want=$(curl -fsSL --retry 3 "$sumurl" | awk '{print $1; exit}')
	got=$(sha512sum "$f" | cut -d' ' -f1)
	[ "$want" = "$got" ] || die "$tag : sha512 différent du .sha512sum publié"
	[ "$dry_run" = 1 ] || lock_set proton-ge "$tag" "$url" "sha512:$got"
	# Heroic : paquets .pacman et .deb, empreinte calculée ici.
	j=$(gh_json Heroic-Games-Launcher/HeroicGamesLauncher "$lock_heroic") || die "release Heroic introuvable"
	tag=$(printf '%s' "$j" | json_field tag)
	for pair in "heroic-pacman:.pacman" "heroic-deb:amd64.deb"; do
		url=$(printf '%s' "$j" | json_field asset "${pair#*:}")
		[ -n "$url" ] || { warn "Heroic $tag : pas de fichier *${pair#*:}"; continue; }
		f="$work/${url##*/}"
		curl -fL --retry 3 -o "$f" "$url"
		[ "$dry_run" = 1 ] || lock_set "${pair%%:*}" "$tag" "$url" "sha256:$(sha256sum "$f" | cut -d' ' -f1)"
	done
	log "pense à committer $LOCK"
}

# Fichier épinglé vérifié : depuis --*-file, le cache, ou téléchargé. Chemin sur la sortie.
fetch_pinned() { # fetch_pinned <nom> <fichier local ou vide>
	local name=$1 local_file=$2 ver url hash f
	read -r ver url hash < <(rago_pl_lock_get "$LOCK" "$name") || return 2
	if [ "$hash" = PENDING ] || [ "$ver" = PENDING ]; then return 3; fi
	if [ -n "$local_file" ]; then
		f=$local_file
	else
		f="$R$P_CACHE/${url##*/}"
		if [ ! -s "$f" ] || ! rago_pl_hash_ok "$f" "$hash"; then
			have curl || { warn "curl absent : impossible de télécharger $name"; return 4; }
			mkdir -p "$(dirname "$f")"
			log "téléchargement de $name $ver" >&2
			curl -fL --retry 3 -o "$f.part" "$url" >&2 || { rm -f "$f.part"; return 4; }
			mv -f "$f.part" "$f"
		fi
	fi
	rago_pl_hash_ok "$f" "$hash" || die "$name : empreinte différente de sources.lock ($f) — fichier refusé"
	echo "$f"
}

# --- install -------------------------------------------------------------------------------
install_files() {
	log "hook et outils : $P_LAUNCH, $P_SHADER, $P_STEAMCFG"
	put_file "$P_LIB" 0644 < "$SRC_LIB"
	put_file "$P_LAUNCH" 0755 < "$SRC_LAUNCH"
	put_file "$P_SHADER" 0755 < "$SRC_SHADER"
	put_file "$P_STEAMCFG" 0755 < "$SRC_STEAMCFG"
	put_file "$P_UNIT" 0644 < "$SRC_UNIT"
	log "gamemode : $P_GAMEMODE + règle polkit $P_POLKIT"
	put_file "$P_GAMEMODE" 0644 < "$SRC_GAMEMODE"
	put_file "$P_POLKIT" 0644 < "$SRC_POLKIT"
	log "MangoHud : $P_MANGOHUD"
	put_file "$P_MANGOHUD" 0644 < "$SRC_MANGOHUD"
	if [ "$S_SESSION" = 1 ]; then
		log "session gamescope : $P_SESSION, $P_DESKTOP"
		put_file "$P_SESSION" 0755 < "$SRC_SESSION"
		put_file "$P_DESKTOP" 0644 < "$SRC_DESKTOP"
		if [ "$S_RT" = 1 ] && { have pacman || [ -d "$R/etc/pacman.d" ]; }; then
			put_file "$P_PACHOOK" 0644 < "$SRC_PACHOOK"
		elif [ -e "$R$P_PACHOOK" ]; then
			remove_file "$P_PACHOOK"
		fi
	else
		local p
		for p in "$P_SESSION" "$P_DESKTOP" "$P_PACHOOK"; do
			[ -e "$R$p" ] && remove_file "$p"
		done
	fi
}

install_proton_ge() {
	local f rc=0 ver url hash dst tmp name
	[ "$S_GE" = 1 ] || { log "Proton-GE : non demandé (--no-proton-ge)"; return 0; }
	read -r ver url hash < <(rago_pl_lock_get "$LOCK" proton-ge) || die "proton-ge absent de $LOCK"
	dst="$R$P_COMPAT/$ver"
	if [ "$hash" != PENDING ] && [ -f "$dst/$GE_MARK" ] && grep -qxF "sha=$hash" "$dst/$GE_MARK"; then
		S_GE_NAME=$(rago_pl_conf_get "$dst/$GE_MARK" name "$S_GE_NAME")
		log "Proton-GE $ver déjà installé ($S_GE_NAME)"
		return 0
	fi
	f=$(fetch_pinned proton-ge "$ge_file") || rc=$?
	case "$rc" in
	0) ;;
	3) warn "Proton-GE pas encore épinglé dans host/proton/sources.lock (PENDING) : sauté. Un mainteneur avec accès GitHub : $0 lock"; return 0 ;;
	*) warn "Proton-GE : téléchargement impossible (code $rc) : sauté ; relancer install avec le réseau, ou --proton-ge-file"; return 0 ;;
	esac
	if [ -e "$dst" ] && [ ! -f "$dst/$GE_MARK" ]; then
		warn "$P_COMPAT/$ver existe déjà sans marque Rago (installé à la main ?) : laissé tel quel"
		return 0
	fi
	if [ "$dry_run" = 1 ]; then printf '[dry-run] extraire %s dans %s\n' "$f" "$R$P_COMPAT"; return 0; fi
	mkdir -p "$R$P_COMPAT"
	tmp=$(mktemp -d "$R$P_COMPAT/.rago-tmp.XXXXXX")
	tar -xzf "$f" -C "$tmp" || { rm -rf "$tmp"; die "archive Proton-GE illisible : $f"; }
	[ -f "$tmp/$ver/compatibilitytool.vdf" ] || { rm -rf "$tmp"; die "archive Proton-GE inattendue : $ver/compatibilitytool.vdf absent"; }
	name=$(rago_pl_compat_tool_name "$tmp/$ver/compatibilitytool.vdf")
	[ -n "$name" ] || { rm -rf "$tmp"; die "nom de l'outil introuvable dans compatibilitytool.vdf"; }
	printf '# Rago OS — Proton-GE épinglé (%s)\nversion=%s\nname=%s\nsha=%s\n' "$RAGO_PROTON_MARKER" "$ver" "$name" "$hash" > "$tmp/$ver/$GE_MARK"
	rm -rf "$dst"
	mv "$tmp/$ver" "$dst"
	rm -rf "$tmp"
	chmod -R go-w "$dst"
	S_GE_NAME=$name
	log "Proton-GE $ver installé dans $P_COMPAT (outil Steam « $name »)"
}

install_heroic() {
	local pm name f rc=0
	[ "$S_HEROIC" = 1 ] || return 0
	if have heroic && [ -z "$heroic_file" ]; then log "Heroic déjà installé ($(command -v heroic))"; return 0; fi
	if [ "$apply" = 0 ]; then log "Heroic : installation du paquet sautée (--no-apply / --root)"; return 0; fi
	pm=$(pkg_manager)
	case "$pm" in pacman) name=heroic-pacman ;; apt) name=heroic-deb ;; *) warn "Heroic : ni pacman ni apt : à installer à la main"; return 0 ;; esac
	f=$(fetch_pinned "$name" "$heroic_file") || rc=$?
	case "$rc" in
	0) ;;
	3) warn "Heroic pas encore épinglé dans host/proton/sources.lock (PENDING) : sauté. Un mainteneur avec accès GitHub : $0 lock"; return 0 ;;
	*) warn "Heroic : téléchargement impossible (code $rc) : sauté"; return 0 ;;
	esac
	log "installation de Heroic ($f)"
	case "$pm" in
	pacman) run pacman -U --needed --noconfirm "$f" ;;
	apt) run apt-get install -y "$f" ;;
	esac
}

gamescope_bin() { command -v gamescope 2>/dev/null || true; }

apply_gamescope_cap() {
	local g prev
	[ "$S_SESSION" = 1 ] || return 0
	g=$(gamescope_bin)
	if [ -z "$g" ]; then warn "gamescope absent : session plein écran impossible (sudo $0 deps)"; return 0; fi
	if [ "$S_RT" = 0 ]; then
		restore_gamescope_cap
		return 0
	fi
	have setcap || { warn "setcap absent (libcap) : --rt sans effet"; return 0; }
	g=$(readlink -f "$g")
	prev=$(getcap "$g" 2>/dev/null | sed 's/^[^ ]* //; s/^= *//')
	case "$prev" in *cap_sys_nice*) log "gamescope a déjà cap_sys_nice"; return 0 ;; esac
	if [ "$dry_run" = 0 ] && [ ! -e "$(state gamescope-caps)" ]; then
		printf '%s\t%s\n' "$g" "$prev" > "$(state gamescope-caps)"
	fi
	log "cap_sys_nice sur $g (--rt et file GPU prioritaire de la session)"
	run setcap cap_sys_nice=eip "$g"
}

restore_gamescope_cap() {
	local f g prev
	f=$(state gamescope-caps)
	[ -e "$f" ] || return 0
	IFS=$'\t' read -r g prev < "$f"
	if [ -e "$g" ] && have setcap; then
		if [ -n "$prev" ]; then run setcap "$prev" "$g"; else run setcap -r "$g" 2>/dev/null || true; fi
		log "capacités de gamescope remises comme avant"
	fi
	[ "$dry_run" = 1 ] || rm -f "$f"
}

step_install() {
	need_root install
	load_settings
	[ "$dry_run" = 1 ] || mkdir -p "$(state backup)"
	have python3 || [ "$apply" = 0 ] || warn "python3 absent : rago-steam-config (hook Steam) ne marchera pas (sudo $0 deps)"
	install_files
	install_proton_ge
	install_heroic
	save_settings
	if [ "$apply" = 0 ]; then
		log "fichiers écrits dans ${R:-/} (rien appliqué : --no-apply / --root)"
		return 0
	fi
	apply_gamescope_cap
	log "installation terminée ; vérification :"
	local rc=0
	step_verify || rc=$?
	if [ "$rc" = 0 ]; then log "tout est en place"; else warn "certains éléments manquent (voir ci-dessus)"; fi
	log "côté joueur (Steam fermé, sans sudo) : $0 user — la session Rago le refait à chaque démarrage"
	return 0
}

# --- uninstall -----------------------------------------------------------------------------
# Retire le hook des options Steam / Heroic / Lutris de chaque joueur (sinon
# ses jeux chercheraient un rago-launch disparu). Steam doit être fermé.
unhook_users() {
	local st home u rc
	[ -z "$R" ] || { log "fausse racine : comptes des joueurs non touchés"; return 0; }
	for st in /home/*/.local/state/rago/steam-hook.json /root/.local/state/rago/steam-hook.json; do
		[ -f "$st" ] || continue
		home=${st%/.local/state/rago/steam-hook.json}
		u=$(stat -c %U "$home")
		log "retrait du hook pour $u"
		rc=0
		if [ "$dry_run" = 1 ]; then printf '[dry-run] %s user --remove (en %s)\n' "$0" "$u"; continue; fi
		runuser -u "$u" -- env HOME="$home" python3 "$SRC_STEAMCFG" unsync || rc=$?
		[ "$rc" = 5 ] && die "Steam tourne pour $u : le fermer, puis relancer uninstall"
		runuser -u "$u" -- env HOME="$home" python3 "$SRC_STEAMCFG" heroic --remove >/dev/null 2>&1 || true
		runuser -u "$u" -- env HOME="$home" python3 "$SRC_STEAMCFG" lutris --remove >/dev/null 2>&1 || true
	done
}

step_uninstall() {
	need_root uninstall
	local st="$R$P_STATE" p d
	if [ ! -d "$st" ] && [ ! -e "$R$P_CONF" ]; then
		log "rien à désinstaller (pas d'état dans $P_STATE)"
		return 0
	fi
	load_settings
	unhook_users
	if [ "$apply" = 1 ]; then restore_gamescope_cap; fi
	{
		cat "$(state manifest)" 2>/dev/null || true
		printf '%s\n' "$P_LIB" "$P_LAUNCH" "$P_SHADER" "$P_STEAMCFG" "$P_UNIT" "$P_GAMEMODE" "$P_POLKIT" \
			"$P_MANGOHUD" "$P_SESSION" "$P_DESKTOP" "$P_PACHOOK"
	} | sort -u | while read -r p; do
		[ -n "$p" ] || continue
		if [ -e "$R$p" ] || [ -e "$(backup_path "$p")" ]; then remove_file "$p"; fi
	done
	for d in "$R$P_COMPAT"/*/; do
		[ -f "$d$GE_MARK" ] || continue
		log "retrait de Proton-GE ${d%/}"
		run rm -rf "${d%/}"
	done
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] retirer %s, %s et %s\n' "$R$P_CONF" "$st" "$R$P_CACHE"
	else
		rmdir "$R/usr/lib/rago" "$R/usr/share/wayland-sessions" "$R/etc/pacman.d/hooks" 2>/dev/null || true
		rm -f "$R$P_CONF"
		rm -rf "$st" "$R$P_CACHE"
	fi
	log "désinstallation terminée (caches de shaders gardés dans ~/.local/share/rago/shader-cache ; paquets gardés)"
}

# --- verify --------------------------------------------------------------------------------
n_ok=0 n_fail=0 n_warn=0 n_hw=0 n_skip=0
ok()   { n_ok=$((n_ok + 1));     printf '  [ OK ]        %s\n' "$*"; }
ko()   { n_fail=$((n_fail + 1)); printf '  [ ÉCHEC ]     %s\n' "$*"; }
att()  { n_warn=$((n_warn + 1)); printf '  [ ATTENTION ] %s\n' "$*"; }
hw()   { n_hw=$((n_hw + 1));     printf '  [ MATÉRIEL ]  %s\n' "$*"; }
skip() { n_skip=$((n_skip + 1)); printf '  [ IGNORÉ ]    %s\n' "$*"; }

# Valeur d'une clé d'un fichier ini de gamemode : ini_get <fichier> <section> <clé>
ini_get() {
	awk -v s="$2" -v k="$3" '
		/^[[:space:]]*[;#]/ { next }
		/^[[:space:]]*\[/ { gsub(/[][[:space:]]/, ""); sec = $0; next }
		sec == s { line = $0; sub(/[[:space:]]*[;#].*$/, "", line)
			if (line ~ "^[[:space:]]*" k "[[:space:]]*=") { sub(/^[^=]*=[[:space:]]*/, "", line); v = line } }
		END { if (v != "") print v }
	' "$1" 2>/dev/null
}

verify_files() {
	local p
	for p in "$P_LIB" "$P_LAUNCH" "$P_SHADER" "$P_STEAMCFG" "$P_UNIT" "$P_GAMEMODE" "$P_POLKIT" "$P_MANGOHUD"; do
		if is_ours "$R$p"; then ok "fichier $p"; else ko "fichier $p absent ou pas de Rago"; fi
	done
	if [ "$S_SESSION" = 1 ]; then
		for p in "$P_SESSION" "$P_DESKTOP"; do
			if is_ours "$R$p"; then ok "fichier $p"; else ko "fichier $p absent ou pas de Rago"; fi
		done
	fi
	local f="$R$P_GAMEMODE" v want k
	for want in "cpu pin_cores no" "cpu park_cores no" "general renice 0" "general softrealtime off" \
		"general disable_splitlock 0" "general igpu_power_threshold -1"; do
		read -r s k v <<< "$want"
		if [ "$(ini_get "$f" "$s" "$k")" = "$v" ]; then ok "gamemode [$s] $k=$v"; else ko "gamemode [$s] $k ≠ $v dans $P_GAMEMODE"; fi
	done
	if grep -qs 'governor-helper' "$R$P_POLKIT" && grep -qs 'polkit.Result.NO' "$R$P_POLKIT"; then
		ok "polkit : gamemode n'a pas le droit de changer le gouverneur (M14/M1 restent maîtres)"
	else
		ko "règle polkit $P_POLKIT incomplète"
	fi
}

verify_live() {
	local g caps name ver url hash d
	if have steam; then ok "Steam installé ($(command -v steam))"; else ko "Steam absent (sudo $0 deps)"; fi
	if have python3; then ok "python3 (rago-steam-config)"; else ko "python3 absent : hook Steam impossible"; fi
	if have gamemoderun; then ok "gamemode ($(command -v gamemoderun))"; else ko "gamemode absent (sudo $0 deps)"; fi
	if have pkaction; then
		if pkaction --action-id com.feralinteractive.GameMode.governor-helper >/dev/null 2>&1; then
			ok "polkit connaît l'action gouverneur de gamemode (la règle Rago s'applique)"
		else
			att "action polkit de gamemode introuvable (gamemode trop ancien ?)"
		fi
	fi
	if have mangohud; then ok "MangoHud ($(command -v mangohud))"; else ko "MangoHud absent (sudo $0 deps)"; fi
	read -r ver url hash < <(rago_pl_lock_get "$LOCK" proton-ge) || true
	if [ "$S_GE" = 0 ]; then
		skip "Proton-GE non demandé"
	elif [ "${hash:-PENDING}" = PENDING ]; then
		att "Proton-GE pas encore épinglé (sources.lock PENDING) : Steam garde son Proton ; mainteneur : $0 lock"
	elif [ -f "$R$P_COMPAT/$ver/$GE_MARK" ] && grep -qxF "sha=$hash" "$R$P_COMPAT/$ver/$GE_MARK"; then
		name=$(rago_pl_conf_get "$R$P_COMPAT/$ver/$GE_MARK" name "?")
		ok "Proton-GE $ver épinglé (outil Steam « $name »)"
	else
		ko "Proton-GE $ver absent de $P_COMPAT (relancer install)"
	fi
	if [ "$S_HEROIC" = 1 ]; then
		if have heroic; then ok "Heroic ($(command -v heroic))"
		else
			read -r ver url hash < <(rago_pl_lock_get "$LOCK" heroic-pacman) || true
			att "Heroic absent$([ "${hash:-PENDING}" = PENDING ] && echo " (pas encore épinglé)")"
		fi
	fi
	if [ "$S_LUTRIS" = 1 ]; then
		if have lutris; then ok "Lutris ($(command -v lutris))"; else ko "Lutris demandé mais absent (sudo $0 --lutris deps)"; fi
	fi
	if [ "$S_SESSION" = 1 ]; then
		g=$(gamescope_bin)
		if [ -n "$g" ]; then
			ok "gamescope ($g)"
			if have mangoapp; then ok "mangoapp (HUD de la session)"; else att "mangoapp absent : session sans HUD"; fi
			if [ "$S_RT" = 1 ]; then
				caps=$(getcap "$(readlink -f "$g")" 2>/dev/null || true)
				case "$caps" in *cap_sys_nice*) ok "gamescope a cap_sys_nice (--rt)" ;; *) ko "gamescope sans cap_sys_nice (relancer install)" ;; esac
			fi
		else
			ko "gamescope absent : pas de session plein écran (sudo $0 deps)"
		fi
	fi
	# Accroches M14 et M0.
	if have rago-profiled; then
		ok "rago-profiled (M14) : profil appliqué au lancement"
		if [ -S /run/rago-profiled/profiled.sock ]; then ok "démon rago-profiled actif"
		else att "démon rago-profiled arrêté : jeux lancés sans profil (systemctl start rago-profiled)"; fi
	else
		att "rago-profiled (M14) absent : jeux lancés sans profil (daemons/rago-profiled/install.sh)"
	fi
	if have rago-sched-hint; then ok "rago-sched-hint (M0) : hint ordonnanceur"; else att "rago-sched-hint (M0) absent : jeux lancés sans hint"; fi
	if have fossilize-replay || have fossilize_replay; then
		ok "fossilize-replay (pré-chauffage)"
	else
		att "fossilize-replay absent : pré-chauffage en attente (Steam fournit le sien après son premier démarrage)"
	fi
	for d in "Mode plein écran, VRR, HDR, tearing en jeu et --rt de la session gamescope" \
		"FPS, 1 % low et saccades de compilation de shaders avec / sans pré-chauffage" \
		"jeu EAC / BattlEye compatible Linux lancé par Proton"; do
		hw "$d : à vérifier sur la vraie machine (jamais testé)"
	done
}

step_verify() {
	load_settings
	n_ok=0 n_fail=0 n_warn=0 n_hw=0 n_skip=0
	printf 'Rago OS — vérification de la couche Proton (M2)\n'
	verify_files
	if [ "$apply" = 1 ] || [ "${RAGO_VERIFY_LIVE:-0}" = 1 ]; then verify_live; fi
	printf 'Bilan : %d OK, %d échec(s), %d attention, %d à vérifier sur matériel, %d ignoré(s)\n' \
		"$n_ok" "$n_fail" "$n_warn" "$n_hw" "$n_skip"
	[ "$n_fail" -eq 0 ]
}

# --- user (côté joueur) --------------------------------------------------------------------
step_user() {
	[ "$(id -u)" -ne 0 ] || [ "${RAGO_ALLOW_ROOT_USER:-0}" = 1 ] || die "« user » se lance en joueur, sans sudo (Steam fermé)"
	local cfg py rc g k v
	R=""
	load_settings
	py=(python3 "$SRC_STEAMCFG")
	[ -x "$P_STEAMCFG" ] && py=("$P_STEAMCFG")
	n_ok=0 n_fail=0 n_warn=0 n_hw=0 n_skip=0
	if [ "$remove" = 1 ]; then
		"${py[@]}" unsync || true
		"${py[@]}" heroic --remove || true
		"${py[@]}" lutris --remove || true
		log "hook retiré de Steam / Heroic / Lutris"
		return 0
	fi
	printf 'Rago OS — couche Proton, côté joueur (%s)\n' "$(id -un)"
	if [ "$S_HOOK" = 1 ]; then
		rc=0
		if [ "$S_DEFAULT" = ge ] && [ -n "$S_GE_NAME" ]; then
			"${py[@]}" sync --default-tool "$S_GE_NAME" || rc=$?
		else
			"${py[@]}" sync || rc=$?
		fi
		case "$rc" in
		0) ok "Steam : hook rago-launch dans les options de lancement" ;;
		3) att "Steam jamais démarré : le démarrer une fois et se connecter, puis relancer" ;;
		5) ko "Steam tourne : le fermer puis relancer (il réécrit sa configuration en quittant)" ;;
		*) ko "rago-steam-config sync : code $rc" ;;
		esac
		"${py[@]}" status || true
	else
		skip "hook Steam désactivé (RAGO_STEAM_HOOK=0) : option de lancement à la main : rago-launch %command%"
	fi
	if [ "$S_HEROIC" = 1 ]; then
		rc=0; "${py[@]}" heroic || rc=$?
		case "$rc" in 0) ok "Heroic : enveloppe rago-launch" ;; 3) att "Heroic jamais démarré : relancer après" ;; *) ko "Heroic : code $rc (le fermer ?)" ;; esac
	fi
	if [ "$S_LUTRIS" = 1 ]; then
		rc=0; "${py[@]}" lutris || rc=$?
		case "$rc" in 0) ok "Lutris : préfixe rago-launch" ;; 3) att "Lutris : à brancher plus tard (voir ci-dessus)" ;; *) ko "Lutris : code $rc" ;; esac
	fi
	cfg="${XDG_CONFIG_HOME:-$HOME/.config}/gamemode.ini"
	if [ -f "$cfg" ]; then
		for k in "cpu pin_cores" "cpu park_cores" "general renice" "general softrealtime" "general disable_splitlock"; do
			# shellcheck disable=SC2086
			v=$(ini_get "$cfg" $k)
			[ -n "$v" ] && att "$cfg change « $k=$v » : peut se battre avec M0 / M1 (supprimer la ligne)"
		done
	fi
	g="${XDG_CONFIG_HOME:-$HOME/.config}/MangoHud/MangoHud.conf"
	[ -f "$g" ] && ok "MangoHud : réglage du joueur ($g) prioritaire sur /etc/MangoHud.conf"
	printf 'Bilan : %d OK, %d échec(s), %d attention, %d ignoré(s)\n' "$n_ok" "$n_fail" "$n_warn" "$n_skip"
	[ "$n_fail" -eq 0 ]
}

case "$cmd" in
install) step_install ;;
verify | status) step_verify ;;
uninstall) step_uninstall ;;
deps) step_deps ;;
lock) step_lock ;;
user) step_user ;;
esac
