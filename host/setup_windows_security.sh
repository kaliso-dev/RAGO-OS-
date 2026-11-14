#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — côté Linux du micro-Windows (module M5) : hook windows-security et
# partition d'échange RAGO-COMM.
#
# Usage :
#   sudo setup_windows_security.sh install     pose le hook, l'unité de montage à la demande, les réglages
#   sudo setup_windows_security.sh uninstall   retire le hook et l'unité (garde /etc/rago/rago-comm.conf)
#   sudo setup_windows_security.sh check       n'écrit rien : hook, unité, partition RAGO-COMM (FAT32, type GPT)
#   sudo setup_windows_security.sh status      profil demandé et dernier état écrit par le micro-Windows
#
# Options :
#   --root DIR   installe sous une fausse racine (tests ; pas de systemctl)
#   --dry-run    affiche ce qui serait fait
#
# Ce qui est installé :
#   /usr/lib/rago/hooks/windows-security        (host/hooks/) appelé par rago-profiled prepare-switch (M14)
#   /usr/lib/systemd/system/run-rago-comm.mount (host/systemd/) montage À LA DEMANDE de RAGO-COMM
#   /etc/rago/rago-comm.conf                    (host/rago-comm.conf) seulement s'il n'existe pas
#   /usr/share/doc/rago/windows/README.md       (windows/README.md)
#
# La partition RAGO-COMM n'est PAS créée ici (ça efface un disque : c'est le
# travail de l'installateur M12). Pour un test à la main : petite partition
# (64 Mio) de type « Microsoft basic data » (code 0700 de sgdisk), puis
#   sudo mkfs.vfat -F 32 -n RAGO-COMM /dev/<partition>
# Prérequis : M14 (rago-profiled) installé ; python3.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
R=""
dry_run=0
cmd=""
HOOK_DST=/usr/lib/rago/hooks/windows-security
UNIT=run-rago-comm.mount
UNIT_DST=/usr/lib/systemd/system/$UNIT
CONF_DST=/etc/rago/rago-comm.conf
DOC_DST=/usr/share/doc/rago/windows/README.md
# GUID GPT « Microsoft basic data » : Windows ne monte que ces partitions-là.
BASIC_DATA_GUID=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }
run() {
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] %s\n' "$*"
	else
		"$@"
	fi
}
sys() {
	if [ -n "$R" ]; then
		printf '[racine %s] sauté : %s\n' "$R" "$*"
	else
		run "$@"
	fi
}
need_root() { [ "$(id -u)" -eq 0 ] || [ "$dry_run" = 1 ] || [ -n "$R" ] || die "« $1 » doit être lancé en root (sudo)"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--root) R=${2%/}; shift 2 ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) die "option inconnue : $1" ;;
	*) [ -z "$cmd" ] || die "une seule commande"; cmd=$1; shift ;;
	esac
done

# Valeur d'une clé de /etc/rago/rago-comm.conf (ou du défaut du dépôt).
conf_get() {
	local key=$1 f="$R$CONF_DST" v
	[ -f "$f" ] || f="$repo/host/rago-comm.conf"
	v=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$f" | tail -1)
	v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
	printf '%s\n' "$v"
}

step_install() {
	need_root install
	command -v python3 >/dev/null || [ -n "$R" ] || die "python3 absent (le hook est un script Python 3)"
	run install -d -m 0755 "$R/usr/lib/rago" "$R/usr/lib/rago/hooks"
	run install -m 0755 "$repo/host/hooks/windows-security" "$R$HOOK_DST"
	run install -Dm 0644 "$repo/host/systemd/$UNIT" "$R$UNIT_DST"
	run install -Dm 0644 "$repo/windows/README.md" "$R$DOC_DST"
	if [ -e "$R$CONF_DST" ]; then
		log "$CONF_DST existe : gardé tel quel"
	else
		run install -Dm 0644 "$repo/host/rago-comm.conf" "$R$CONF_DST"
	fi
	# Le hook tourne en root : lui et son dossier ne doivent être modifiables
	# que par root (rago-profiled refuse sinon).
	if [ "$dry_run" = 0 ] && [ -z "$R" ]; then
		chown root:root "$R/usr/lib/rago/hooks" "$R$HOOK_DST"
	fi
	sys systemctl daemon-reload
	if [ -z "$R" ]; then
		command -v rago-profiled >/dev/null ||
			warn "rago-profiled (M14) absent : le hook ne sera appelé par personne (daemons/rago-profiled/install.sh)"
		[ -e "$(conf_get RAGO_COMM_DEVICE)" ] ||
			warn "partition RAGO-COMM absente ($(conf_get RAGO_COMM_DEVICE)) : voir « check »"
	fi
	log "hook windows-security installé. Essai : sudo rago-profiled prepare-switch --id valorant"
}

step_uninstall() {
	need_root uninstall
	sys systemctl stop "$UNIT"
	run rm -f "$R$HOOK_DST" "$R$UNIT_DST" "$R$DOC_DST"
	[ -d "$R/usr/share/doc/rago/windows" ] && run rmdir --ignore-fail-on-non-empty "$R/usr/share/doc/rago/windows"
	sys systemctl daemon-reload
	log "retiré. Gardé : $CONF_DST (réglages) ; la partition RAGO-COMM n'est jamais touchée."
}

# check : n'écrit rien. Code 0 si tout est prêt, 1 sinon.
step_check() {
	local bad=0 dev real fstype parttype label size mode owner
	ok() { printf '  OK      %s\n' "$*"; }
	ko() { printf '  MANQUE  %s\n' "$*"; bad=1; }
	if [ -x "$R$HOOK_DST" ]; then
		mode=$(stat -c %a "$R$HOOK_DST"); owner=$(stat -c %u "$R$HOOK_DST")
		if [ "$owner" = 0 ] && [ $((8#$mode & 8#022)) = 0 ]; then ok "hook $HOOK_DST ($mode, root)"
		else ko "hook $HOOK_DST : doit appartenir à root, non modifiable par le groupe ou les autres ($mode, uid $owner)"; fi
	else
		ko "hook $HOOK_DST (lancer « install »)"
	fi
	[ -f "$R$UNIT_DST" ] && ok "unité $UNIT" || ko "unité $UNIT_DST"
	[ -f "$R$CONF_DST" ] && ok "réglages $CONF_DST" || ko "réglages $CONF_DST (défauts du hook utilisés)"
	dev=$(conf_get RAGO_COMM_DEVICE)
	if [ -n "$R" ]; then
		printf '  --      partition : non vérifiée sous une fausse racine\n'
	elif [ -e "$dev" ]; then
		real=$(readlink -f "$dev")
		fstype=$(lsblk -no FSTYPE "$real" 2>/dev/null | head -1)
		parttype=$(lsblk -no PARTTYPE "$real" 2>/dev/null | head -1)
		label=$(lsblk -no LABEL "$real" 2>/dev/null | head -1)
		size=$(lsblk -bno SIZE "$real" 2>/dev/null | head -1)
		ok "partition $dev -> $real (étiquette ${label:-?}, $((${size:-0} / 1048576)) Mio)"
		[ "$fstype" = vfat ] && ok "système de fichiers FAT32 (vfat)" || ko "système de fichiers ${fstype:-inconnu} : FAT32 attendu (mkfs.vfat -F 32 -n RAGO-COMM)"
		if [ -z "$parttype" ]; then
			warn "type GPT illisible (disque MBR ?) : Windows doit pouvoir la monter"
		elif [ "${parttype,,}" = "$BASIC_DATA_GUID" ]; then
			ok "type GPT Microsoft basic data (Windows la voit)"
		else
			ko "type GPT $parttype : « Microsoft basic data » ($BASIC_DATA_GUID) attendu, sinon Windows ne la monte pas (sgdisk -t N:0700)"
		fi
		if findmnt -n "$(conf_get RAGO_COMM_DIR)" >/dev/null 2>&1; then
			warn "RAGO-COMM est montée en ce moment sur $(conf_get RAGO_COMM_DIR) (normal seulement pendant une écriture)"
		fi
	else
		ko "partition RAGO-COMM ($dev) : à créer (installateur M12, ou à la main : voir l'en-tête de ce script)"
	fi
	if [ -z "$R" ] && command -v rago-profiled >/dev/null; then
		if rago-profiled status 2>/dev/null | grep -q "hook windows-security.*présent"; then ok "rago-profiled voit le hook"
		else warn "rago-profiled ne signale pas le hook présent (démon arrêté ?)"; fi
	fi
	return "$bad"
}

step_status() {
	need_root status
	if [ -n "$R" ]; then
		die "status : pas sous une fausse racine"
	fi
	run python3 -I "$HOOK_DST" status
}

case "$cmd" in
install) step_install ;;
uninstall) step_uninstall ;;
check) step_check ;;
status) step_status ;;
"") sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
*) die "commande inconnue : $cmd (install | uninstall | check | status)" ;;
esac
