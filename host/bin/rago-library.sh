#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — bibliothèque partagée (module M7), côté Linux.
#
# RAGO-LIB est une partition NTFS partagée avec le micro-Windows (M5) : Linux
# la monte avec le pilote noyau ntfs3 (jamais ntfs-3g / FUSE, jamais l'option
# « force »), Windows la lit et l'écrit en natif. Les deux OS n'y accèdent
# JAMAIS en même temps : NTFS n'a aucun verrou entre deux systèmes, c'est le
# switch (un seul OS actif, M6) qui le garantit, et ce script ne monte
# RAGO-LIB en écriture que si Windows est éteint ; au moindre doute, lecture
# seule. Les jeux Windows s'installent TOUJOURS dans Windows, par les clients
# officiels (Steam, Epic Games Launcher, Riot Client) ; Linux gère, liste et
# déclenche (requêtes écrites dans RAGO-COMM, la partition FAT32 de M5).
#
# Usage (root) :
#   rago-library status [--json]              Windows éteint proprement ? requêtes, résultats
#   rago-library list [--json]                jeux de RAGO-LIB (montée en lecture seule le temps de lire)
#   rago-library mount [--rw | --ro]          monte RAGO-LIB sur /run/rago/lib
#                                             (sans option : écriture si permise, sinon lecture seule)
#   rago-library umount                       démonte RAGO-LIB (à faire avant de passer sous Windows)
#   rago-library install steam|epic|riot ID [--name NOM]
#   rago-library launch  steam|epic|riot ID [--name NOM]
#                                             requête pour le prochain démarrage du micro-Windows
#   rago-library cancel ID_REQUÊTE            retire une requête pas encore prise par Windows
#   rago-library forget ID_REQUÊTE            efface le résultat d'une requête finie
#   rago-library confirm-windows-off [--yes]  certifier que Windows est éteint (après un arrêt brutal)
#   rago-library check                        n'écrit rien : pilote ntfs3, partition, réglages, garde
#
# Identifiants : steam = numéro d'application (730) ; epic = AppName (ou
# espace:article:AppName) ; riot = valorant ou league_of_legends.
#
# Écriture permise seulement si (1) RAGO-COMM dit que Windows s'est arrêté
# proprement et a mis RAGO-LIB hors ligne (ou le joueur l'a certifié), ET
# (2) le volume NTFS est propre sur le disque (bit « sale » éteint, journal
# $LogFile vide ou propre, pas de cache de veille prolongée de Windows).
# Hibernation de Linux refusée tant qu'un volume NTFS est monté (unité
# rago-library-sleep-guard.service) : Windows pourrait démarrer pendant ce
# temps (switch de M6).
#
# Codes de sortie : 0 fait ; 1 erreur ; 2 commande ou entrée refusée ;
# 3 écriture refusée (doute) — « mount » sans option a quand même monté en
# lecture seule.
#
# Réglages : /etc/rago/rago-library.conf (host/rago-library.conf) ; RAGO-COMM :
# /etc/rago/rago-comm.conf (M5). Installation : host/setup_library.sh.
set -euo pipefail

self=$(readlink -f "$0")
here=$(dirname "$self")
# Installé : /usr/lib/rago/{rago-library.sh,rago_library.py} ; dépôt : host/bin et host/lib.
if [ -f "$here/rago_library.py" ]; then helper="$here/rago_library.py"; else helper="$here/../lib/rago_library.py"; fi
CONF=${RAGO_LIBRARY_CONF:-/etc/rago/rago-library.conf}
PY=${RAGO_PYTHON:-python3}

die() { printf 'rago-library : %s\n' "$*" >&2; exit 1; }
refuse() { printf 'rago-library : refusé : %s\n' "$*" >&2; exit 2; }
say() { printf '%s\n' "$*"; }
warn() { printf 'rago-library : avertissement : %s\n' "$*" >&2; }
need_root() { [ "$(id -u)" -eq 0 ] || die "« $1 » demande root (montage, lecture du disque, RAGO-COMM)"; }
helper() { "$PY" -I "$helper" "$@"; }

# --- réglages ---------------------------------------------------------------------------------
RAGO_LIB_DEVICE=/dev/disk/by-label/RAGO-LIB
RAGO_LIB_DIR=/run/rago/lib
RAGO_LIB_FSTYPE=ntfs3
RAGO_LIB_OPTIONS=uid=0,gid=0,umask=022,iocharset=utf8,windows_names,nosuid,nodev,noexec,noatime
RAGO_LIB_REQUIRE_NTFS=1

load_conf() {
	local f=$CONF n=0 line k v
	[ -e "$f" ] || return 0
	# Lu par root : un fichier modifiable par d'autres ferait monter n'importe quoi.
	if [ "$(stat -c %u "$f")" != 0 ] && [ "$(stat -c %u "$f")" != "$(id -u)" ]; then die "$f doit appartenir à root"; fi
	[ $((8#$(stat -c %a "$f") & 8#022)) = 0 ] || die "$f ne doit pas être modifiable par le groupe ou les autres"
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		line=${line#"${line%%[![:space:]]*}"}
		line=${line%"${line##*[![:space:]]}"}
		case "$line" in '' | '#'*) continue ;; esac
		case "$line" in *=*) ;; *) die "$f:$n : ligne sans « = »" ;; esac
		k=${line%%=*}; v=${line#*=}
		k=${k%"${k##*[![:space:]]}"}; v=${v#"${v%%[![:space:]]*}"}
		case "$v" in \"*\") v=${v#\"}; v=${v%\"} ;; \'*\') v=${v#\'}; v=${v%\'} ;; esac
		case "$k" in
		RAGO_LIB_DEVICE | RAGO_LIB_DIR | RAGO_LIB_FSTYPE | RAGO_LIB_OPTIONS | RAGO_LIB_REQUIRE_NTFS) printf -v "$k" '%s' "$v" ;;
		*) die "$f:$n : réglage inconnu $k" ;;
		esac
	done < "$f"
}

check_conf() {
	case "$RAGO_LIB_DIR" in /*) ;; *) die "RAGO_LIB_DIR doit être un chemin absolu" ;; esac
	case "$RAGO_LIB_DIR" in / | /run | /run/ | /usr* | /etc* | /boot* | /home | /home/) die "RAGO_LIB_DIR=$RAGO_LIB_DIR : dossier refusé" ;; esac
	case "$RAGO_LIB_REQUIRE_NTFS" in 0 | 1) ;; *) die "RAGO_LIB_REQUIRE_NTFS doit valoir 0 ou 1" ;; esac
	if [ "$RAGO_LIB_REQUIRE_NTFS" = 1 ] && [ "$RAGO_LIB_FSTYPE" != ntfs3 ]; then
		die "RAGO_LIB_FSTYPE=$RAGO_LIB_FSTYPE : seul le pilote noyau ntfs3 est permis (jamais ntfs-3g / FUSE)"
	fi
	local o
	IFS=, read -r -a opts <<< "$RAGO_LIB_OPTIONS"
	for o in "${opts[@]}"; do
		case "$o" in
		force | force=*) die "RAGO_LIB_OPTIONS : « force » est interdit (il monterait en écriture un volume que Windows n'a pas fermé)" ;;
		ro | rw | remount | bind | rbind) die "RAGO_LIB_OPTIONS : « $o » est choisi par rago-library, pas par les réglages" ;;
		'') ;;
		esac
	done
}

# --- état du montage ---------------------------------------------------------------------------
# Options du montage sur RAGO_LIB_DIR (« rw,… » / « ro,… »), vide si rien n'y est monté.
mounted_opts() { findmnt -rn -M "$RAGO_LIB_DIR" -o OPTIONS 2>/dev/null | tail -1 || true; }
mounted_mode() {
	local o
	o=$(mounted_opts)
	[ -n "$o" ] || return 0
	case ",$o," in *,rw,*) echo rw ;; *) echo ro ;; esac
}
mounted_fstype() { findmnt -rn -M "$RAGO_LIB_DIR" -o FSTYPE 2>/dev/null | tail -1 || true; }

lib_device() {
	[ -e "$RAGO_LIB_DEVICE" ] || die "partition RAGO-LIB introuvable ($RAGO_LIB_DEVICE) : créée par l'installateur (M12), voir la note M7 du vault"
	readlink -f "$RAGO_LIB_DEVICE"
}

blk() { blkid -p -o value -s "$1" "$2" 2>/dev/null || true; }

ntfs3_available() {
	grep -qw ntfs3 /proc/filesystems 2>/dev/null && return 0
	modprobe -q ntfs3 2>/dev/null && grep -qw ntfs3 /proc/filesystems 2>/dev/null
}

# --- mount -------------------------------------------------------------------------------------
do_mount() { # do_mount auto|rw|ro
	local want=$1 dev cur fstype label partuuid serial out rc mode elsewhere opts
	local -a extra=()
	need_root mount
	dev=$(lib_device)
	cur=$(mounted_mode)
	if [ -n "$cur" ]; then
		if { [ "$want" = ro ] && [ "$cur" = ro ]; } || { [ "$want" != ro ] && [ "$cur" = rw ]; }; then
			say "RAGO-LIB déjà montée sur $RAGO_LIB_DIR ($([ "$cur" = rw ] && echo écriture || echo 'lecture seule'))"
			return 0
		fi
		say "RAGO-LIB montée en $([ "$cur" = rw ] && echo écriture || echo 'lecture seule') : démontage pour la remonter"
		do_umount
	fi
	elsewhere=$(findmnt -rn -S "$dev" -o TARGET 2>/dev/null | head -1 || true)
	[ -z "$elsewhere" ] || die "RAGO-LIB ($dev) est déjà montée sur $elsewhere : la démonter d'abord (umount $elsewhere)"

	fstype=$(blk TYPE "$dev")
	label=$(blk LABEL "$dev")
	partuuid=$(blk PART_ENTRY_UUID "$dev")
	serial=$(blk UUID "$dev")
	if [ "$RAGO_LIB_REQUIRE_NTFS" = 1 ]; then
		[ "$fstype" = ntfs ] || die "$dev est en ${fstype:-système de fichiers inconnu} : RAGO-LIB doit être en NTFS"
		ntfs3_available || die "pilote noyau ntfs3 absent (CONFIG_NTFS3_FS ; Ubuntu : paquet linux-modules-extra) ; ntfs-3g n'est jamais utilisé"
	fi
	[ "$label" = RAGO-LIB ] || warn "étiquette « ${label:-aucune} » sur $dev (RAGO-LIB attendue)"

	# Une seule ouverture de RAGO-COMM : décision, contrôle NTFS du disque, partition.json pour Windows.
	[ "$RAGO_LIB_REQUIRE_NTFS" = 1 ] || extra=(--no-ntfs)
	set +e
	out=$(helper prepare-mount "$dev" "$want" "${partuuid:--}" "${serial:--}" "${extra[@]}")
	rc=$?
	set -e
	case "$rc" in
	0) mode=rw ;;
	3) mode=ro ;;
	*) die "contrôle avant montage impossible (code $rc)" ;;
	esac
	if [ "$want" != ro ] && [ "$mode" = ro ]; then
		printf '%s\n' "$out" | "$PY" -I -c 'import json,sys
for r in json.load(sys.stdin).get("reasons") or []: print("  - " + r)' >&2 || true
		if [ "$want" = rw ]; then
			printf 'rago-library : écriture refusée, rien de monté (au doute, lecture seule : rago-library mount --ro)\n' >&2
			exit 3
		fi
		printf 'rago-library : écriture refusée : montage en LECTURE SEULE\n' >&2
	fi
	if [ "$want" = ro ]; then mode=ro; fi

	install -d -m 0755 "$RAGO_LIB_DIR"
	opts="$RAGO_LIB_OPTIONS,$mode"
	# -i : jamais d'assistant /sbin/mount.<type> (ntfs-3g installe mount.ntfs).
	mount -i -t "$RAGO_LIB_FSTYPE" -o "$opts" "$dev" "$RAGO_LIB_DIR" ||
		die "montage de $dev sur $RAGO_LIB_DIR impossible (journal du noyau : journalctl -k | grep ntfs3)"
	cur=$(mounted_mode)
	[ "$(mounted_fstype)" = "$RAGO_LIB_FSTYPE" ] || { umount "$RAGO_LIB_DIR" || true; die "monté avec le pilote $(mounted_fstype) au lieu de $RAGO_LIB_FSTYPE : démonté"; }
	if [ "$mode" = rw ] && [ "$cur" != rw ]; then
		warn "le noyau a monté RAGO-LIB en lecture seule (taille du volume ? journalctl -k | grep ntfs3)"
		mode=ro
	fi
	if [ "$mode" = rw ]; then
		helper init "$RAGO_LIB_DIR" || warn "préparation de .rago/ impossible"
		say "RAGO-LIB montée en ÉCRITURE sur $RAGO_LIB_DIR (démonter avant de passer sous Windows : rago-library umount)"
		return 0
	fi
	say "RAGO-LIB montée en LECTURE SEULE sur $RAGO_LIB_DIR"
	[ "$want" = ro ] && return 0
	return 3
}

do_umount() {
	need_root umount
	if [ -z "$(mounted_mode)" ]; then
		say "RAGO-LIB n'est pas montée"
		return 0
	fi
	sync -f "$RAGO_LIB_DIR" 2>/dev/null || sync
	if ! umount "$RAGO_LIB_DIR"; then
		fuser -vm "$RAGO_LIB_DIR" 2>&1 | sed 's/^/  /' >&2 || true
		die "RAGO-LIB occupée (programmes ci-dessus) : les fermer puis recommencer"
	fi
	say "RAGO-LIB démontée"
}

# --- list --------------------------------------------------------------------------------------
do_list() { # do_list --text|--json
	local cur tmpmounted=0 rc=0
	local -a fmt=()
	[ "$1" = --text ] && fmt=(--text)
	need_root list
	cur=$(mounted_mode)
	if [ -z "$cur" ]; then
		if [ -e "$RAGO_LIB_DEVICE" ]; then
			do_mount ro > /dev/null
			tmpmounted=1
			cur=ro
		else
			warn "partition RAGO-LIB introuvable ($RAGO_LIB_DEVICE) : seulement RAGO-COMM"
		fi
	fi
	if [ -n "$cur" ]; then
		helper list "$RAGO_LIB_DIR" "${fmt[@]}" --mode "$([ "$cur" = rw ] && echo écriture || echo 'lecture seule')" || rc=$?
	else
		helper list - "${fmt[@]}" || rc=$?
	fi
	if [ "$tmpmounted" = 1 ]; then do_umount > /dev/null; fi
	return "$rc"
}

# --- requêtes ----------------------------------------------------------------------------------
do_request() { # do_request install|launch LANCEUR ID [--name NOM]
	need_root "$1"
	local action=$1
	shift
	[ $# -ge 2 ] || refuse "$action steam|epic|riot ID [--name NOM]"
	local launcher=$1 id=$2
	shift 2
	if [ $# -gt 0 ]; then
		[ "$1" = --name ] && [ $# -eq 2 ] || refuse "option inconnue : $*"
		helper request "$action" "$launcher" "$id" --name "$2"
	else
		helper request "$action" "$launcher" "$id"
	fi
}

do_confirm_off() {
	need_root confirm-windows-off
	local yes=${1:-} answer
	if [ "$yes" != --yes ]; then
		cat <<-'EOF'
			Certifier que le micro-Windows est ÉTEINT : ni en marche, ni en veille prolongée.
			À faire seulement après un arrêt brutal (coupure, écran bleu) quand Windows n'a pas
			pu écrire « éteint » lui-même. Si Windows dort en réalité, écrire dans RAGO-LIB
			l'abîmera. Le contrôle du disque (volume NTFS propre) reste fait au montage.
		EOF
		read -r -p 'Windows est éteint ? Taper « oui » : ' answer
		[ "$answer" = oui ] || refuse "pas confirmé"
	fi
	helper confirm-off
}

# --- check -------------------------------------------------------------------------------------
do_check() {
	local bad=0 dev real fstype label parttype attrs cur
	ok() { printf '  OK      %s\n' "$*"; }
	ko() { printf '  MANQUE  %s\n' "$*"; bad=1; }
	if [ "$RAGO_LIB_REQUIRE_NTFS" = 1 ]; then
		if grep -qw ntfs3 /proc/filesystems 2>/dev/null; then ok "pilote noyau ntfs3 chargé"
		elif modinfo ntfs3 > /dev/null 2>&1; then ok "pilote noyau ntfs3 disponible (module)"
		else ko "pilote noyau ntfs3 (CONFIG_NTFS3_FS ; Ubuntu : linux-modules-extra-\$(uname -r))"; fi
	fi
	if [ -e "$CONF" ]; then ok "réglages $CONF"; else printf '  --      réglages %s absents : défauts\n' "$CONF"; fi
	if [ -e /usr/lib/systemd/system/rago-library-sleep-guard.service ] || [ -e /etc/systemd/system/rago-library-sleep-guard.service ]; then
		if systemctl is-enabled --quiet rago-library-sleep-guard.service 2>/dev/null; then ok "garde d'hibernation activée"
		else ko "garde d'hibernation installée mais pas activée (systemctl enable rago-library-sleep-guard.service)"; fi
	else
		ko "garde d'hibernation (host/setup_library.sh install)"
	fi
	dev=$RAGO_LIB_DEVICE
	if [ -e "$dev" ]; then
		real=$(readlink -f "$dev")
		if [ "$(id -u)" -eq 0 ]; then
			fstype=$(blk TYPE "$real"); label=$(blk LABEL "$real")
			parttype=$(blk PART_ENTRY_TYPE "$real"); attrs=$(blk PART_ENTRY_FLAGS "$real")
		else
			fstype=$(lsblk -no FSTYPE "$real" 2>/dev/null | head -1); label=$(lsblk -no LABEL "$real" 2>/dev/null | head -1)
			parttype=$(lsblk -no PARTTYPE "$real" 2>/dev/null | head -1); attrs=""
		fi
		ok "partition $dev -> $real (étiquette ${label:-?})"
		if [ "$RAGO_LIB_REQUIRE_NTFS" = 1 ]; then
			if [ "$fstype" = ntfs ]; then ok "système de fichiers NTFS"; else ko "système de fichiers ${fstype:-inconnu} : NTFS attendu"; fi
		fi
		if [ -z "$parttype" ]; then
			warn "type de partition illisible (disque MBR ?) : Windows doit pouvoir la monter"
		elif [ "${parttype,,}" = ebd0a0a2-b9e5-4433-87c0-68b6b72699c7 ]; then
			ok "type GPT Microsoft basic data (Windows la voit)"
		else
			ko "type GPT $parttype : « Microsoft basic data » attendu, sinon Windows ne la monte pas"
		fi
		[ -n "$attrs" ] && printf '  --      attributs GPT %s\n' "$attrs"
		if [ "$(id -u)" -eq 0 ] && [ "$RAGO_LIB_REQUIRE_NTFS" = 1 ] && [ "$fstype" = ntfs ]; then
			if helper ntfs-check "$real" | "$PY" -I -c 'import json,sys
d=json.load(sys.stdin)
print("  --      NTFS : sale=%s, journal=%s (version %s)" % (d.get("dirty"), d.get("logfile"), d.get("logfile_version")))
for r in d.get("reasons") or []: print("  --      " + r)'; then :; fi
		fi
	else
		ko "partition RAGO-LIB ($dev) : à créer (installateur M12 ; à la main : voir la note M7 du vault)"
	fi
	cur=$(mounted_mode)
	[ -n "$cur" ] && printf '  --      RAGO-LIB montée sur %s (%s, %s)\n' "$RAGO_LIB_DIR" "$cur" "$(mounted_fstype)"
	return "$bad"
}

# --- garde d'hibernation (unité rago-library-sleep-guard.service) -------------------------------
# Appelée par systemd juste avant une hibernation. NE TOUCHE PAS RAGO-COMM
# (son unité de montage est en conflit avec sleep.target). Refuse si RAGO-LIB
# ou n'importe quel volume NTFS est monté : pendant l'hibernation de Linux,
# Windows peut démarrer (switch M6) et écrire sur ce volume.
do_sleep_guard() {
	local found="" src target fstype rlib=""
	[ -e "$RAGO_LIB_DEVICE" ] && rlib=$(readlink -f "$RAGO_LIB_DEVICE")
	# -r : espaces des chemins écrits \x20, trois champs par ligne.
	while read -r src target fstype; do
		[ -n "$target" ] || continue
		case "$fstype" in
		ntfs3 | ntfs) found="$found $target($fstype)" ;;
		fuseblk) if [ "$(blk TYPE "$src")" = ntfs ]; then found="$found $target(ntfs-3g)"; fi ;;
		*)
			if [ "$target" = "$RAGO_LIB_DIR" ] ||
				{ [ -n "$rlib" ] && [ "$(readlink -f "$src" 2>/dev/null || true)" = "$rlib" ]; }; then
				found="$found $target(RAGO-LIB)"
			fi
			;;
		esac
	done < <(findmnt -rn -o SOURCE,TARGET,FSTYPE 2>/dev/null)
	if [ -n "$found" ]; then
		printf 'rago-library : hibernation REFUSÉE : volume(s) NTFS monté(s) :%s. Windows pourrait démarrer pendant la veille et les abîmer. Démonter d abord (rago-library umount).\n' "$found" >&2
		exit 1
	fi
	exit 0
}

usage() { sed -n '3,46p' "$self" | sed 's/^# \{0,1\}//'; }

load_conf
check_conf
cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
status)
	need_root status
	case "${1:-}" in --json) helper status ;; '') helper status --text ;; *) refuse "status [--json]" ;; esac
	;;
list)
	case "${1:-}" in --json) do_list --json ;; '') do_list --text ;; *) refuse "list [--json]" ;; esac
	;;
mount)
	[ $# -le 1 ] || refuse "mount [--rw | --ro]"
	case "${1:-}" in --rw) do_mount rw ;; --ro) do_mount ro ;; '') do_mount auto ;; *) refuse "mount [--rw | --ro]" ;; esac
	;;
umount | unmount) [ $# -eq 0 ] || refuse "umount"; do_umount ;;
install | launch) do_request "$cmd" "$@" ;;
cancel | forget) need_root "$cmd"; [ $# -eq 1 ] || refuse "$cmd ID_REQUÊTE"; helper "$cmd" "$1" ;;
confirm-windows-off) [ $# -le 1 ] || refuse "confirm-windows-off [--yes]"; do_confirm_off "${1:-}" ;;
check) [ $# -eq 0 ] || refuse "check"; do_check ;;
__sleep-guard) do_sleep_guard ;;
-h | --help | help) usage ;;
'') usage >&2; exit 2 ;;
*) refuse "commande inconnue : $cmd (rago-library --help)" ;;
esac
