#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — côté Linux de la bibliothèque partagée (module M7) : commande
# rago-library et garde d'hibernation.
#
# Usage :
#   sudo setup_library.sh install     pose rago-library, le garde d'hibernation (activé), les réglages
#   sudo setup_library.sh uninstall   retire rago-library et le garde (garde /etc/rago/rago-library.conf)
#   sudo setup_library.sh check       n'écrit rien : fichiers posés + rago-library check
#
# Options :
#   --root DIR   installe sous une fausse racine (tests ; pas de systemctl, garde activé par lien)
#   --dry-run    affiche ce qui serait fait
#
# Ce qui est installé :
#   /usr/lib/rago/rago-library.sh                           (host/bin/)
#   /usr/lib/rago/rago_library.py                           (host/lib/)
#   /usr/bin/rago-library -> /usr/lib/rago/rago-library.sh
#   /usr/lib/systemd/system/rago-library-sleep-guard.service (host/systemd/), activé
#   /etc/rago/rago-library.conf                             (host/rago-library.conf) seulement s'il n'existe pas
#   /usr/share/doc/rago/library/README.md                   (windows/rago-agent/README.md)
#
# La partition RAGO-LIB n'est PAS créée ici (ça efface un disque : travail de
# l'installateur M12). À la main, sur une partition vide de type « Microsoft
# basic data » : sudo mkntfs -Q -L RAGO-LIB /dev/<partition> (paquet ntfs-3g,
# seulement pour formater ; le montage passe toujours par ntfs3).
# Prérequis : M5 (RAGO-COMM, host/setup_windows_security.sh install) ; python3 ;
# pilote noyau ntfs3.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
R=""
dry_run=0
cmd=""
LIBEXEC=/usr/lib/rago
UNIT=rago-library-sleep-guard.service
UNIT_DST=/usr/lib/systemd/system/$UNIT
CONF_DST=/etc/rago/rago-library.conf
DOC_DST=/usr/share/doc/rago/library/README.md
BIN_LINK=/usr/bin/rago-library
# Services d'hibernation que le garde doit précéder (RequiredBy= de l'unité).
SLEEP_UNITS="systemd-hibernate.service systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service"

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
need_root() { [ "$(id -u)" -eq 0 ] || [ "$dry_run" = 1 ] || [ -n "$R" ] || die "« $1 » doit être lancé en root (sudo)"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--root) R=${2%/}; shift 2 ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) die "option inconnue : $1" ;;
	*) [ -z "$cmd" ] || die "une seule commande"; cmd=$1; shift ;;
	esac
done

step_install() {
	need_root install
	command -v python3 >/dev/null || [ -n "$R" ] || die "python3 absent (rago_library.py)"
	run install -d -m 0755 "$R$LIBEXEC" "$R/usr/bin"
	run install -m 0755 "$repo/host/bin/rago-library.sh" "$R$LIBEXEC/rago-library.sh"
	run install -m 0755 "$repo/host/lib/rago_library.py" "$R$LIBEXEC/rago_library.py"
	run ln -sfn "$LIBEXEC/rago-library.sh" "$R$BIN_LINK"
	run install -Dm 0644 "$repo/host/systemd/$UNIT" "$R$UNIT_DST"
	run install -Dm 0644 "$repo/windows/rago-agent/README.md" "$R$DOC_DST"
	if [ -e "$R$CONF_DST" ]; then
		log "$CONF_DST existe : gardé tel quel"
	else
		run install -Dm 0644 "$repo/host/rago-library.conf" "$R$CONF_DST"
	fi
	if [ -n "$R" ]; then
		# Même effet que systemctl enable (RequiredBy=), sans systemd.
		local u
		for u in $SLEEP_UNITS; do
			run install -d -m 0755 "$R/etc/systemd/system/$u.requires"
			run ln -sfn "$UNIT_DST" "$R/etc/systemd/system/$u.requires/$UNIT"
		done
	else
		run systemctl daemon-reload
		run systemctl enable "$UNIT"
	fi
	if [ -z "$R" ]; then
		[ -e /usr/lib/systemd/system/run-rago-comm.mount ] ||
			warn "RAGO-COMM (M5) pas installée : host/setup_windows_security.sh install"
		grep -qw ntfs3 /proc/filesystems || modinfo ntfs3 >/dev/null 2>&1 ||
			warn "pilote noyau ntfs3 introuvable (CONFIG_NTFS3_FS ; Ubuntu : linux-modules-extra)"
	fi
	log "rago-library installée (rago-library --help) ; hibernation refusée tant que RAGO-LIB est montée"
}

step_uninstall() {
	need_root uninstall
	local u
	if [ -n "$R" ]; then
		for u in $SLEEP_UNITS; do run rm -f "$R/etc/systemd/system/$u.requires/$UNIT"; done
	else
		run systemctl disable "$UNIT" || true
	fi
	run rm -f "$R$LIBEXEC/rago-library.sh" "$R$LIBEXEC/rago_library.py" "$R$BIN_LINK" "$R$UNIT_DST" "$R$DOC_DST"
	[ -d "$R/usr/share/doc/rago/library" ] && run rmdir --ignore-fail-on-non-empty "$R/usr/share/doc/rago/library"
	[ -n "$R" ] || run systemctl daemon-reload
	log "retiré. Gardé : $CONF_DST (réglages) ; RAGO-LIB et son contenu ne sont jamais touchés."
}

step_check() {
	local bad=0 f
	for f in "$LIBEXEC/rago-library.sh" "$LIBEXEC/rago_library.py" "$UNIT_DST"; do
		if [ -e "$R$f" ]; then printf '  OK      %s\n' "$f"; else printf '  MANQUE  %s\n' "$f"; bad=1; fi
	done
	if [ -n "$R" ]; then
		printf '  --      partition, pilote, garde : non vérifiés sous une fausse racine\n'
		return "$bad"
	fi
	if [ -x "$LIBEXEC/rago-library.sh" ]; then "$LIBEXEC/rago-library.sh" check || bad=1; fi
	return "$bad"
}

case "$cmd" in
install) step_install ;;
uninstall) step_uninstall ;;
check) step_check ;;
"") sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
*) die "commande inconnue : $cmd (install | uninstall | check)" ;;
esac
