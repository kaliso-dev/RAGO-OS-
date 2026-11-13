#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — installe le démon des profils par jeu rago-profiled (module M14).
#
# Usage :
#   install.sh build                       compile (sans root) : target/release/rago-profiled
#   sudo install.sh install [--user NOM]   installe et démarre le service
#   sudo install.sh uninstall              arrête et retire (garde /etc/rago/profiles)
#
# Options :
#   --user NOM     ajoute NOM au groupe rago (accès au socket, comme M0)
#   --bin FICHIER  binaire à installer (défaut : target/release/rago-profiled)
#   --root DIR     installe sous une fausse racine (tests ; pas de systemctl, groupadd, usermod)
#   --dry-run      affiche ce qui serait fait
#
# Ce qui est installé :
#   /usr/bin/rago-profiled
#   /usr/lib/systemd/system/rago-profiled.service   (host/systemd/)
#   /usr/share/rago/profiles/                        base communautaire (profiles/community/)
#   /usr/share/rago/schema/rago-profile.schema.json
#   /usr/share/doc/rago/profiles/README.md
#   /etc/rago/profiles/                              profils locaux (jamais touchés)
#   /usr/lib/rago/hooks/                             hooks de M9 / M5-M6 (vide pour l'instant)
#
# Prérequis : M1 installé (réglage de base) ; M0 (rago-sched-hint, groupe rago)
# conseillé. Sans M0, les jeux se lancent sans hint ordonnanceur.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
R=""
dry_run=0
target_user=""
bin="$repo/target/release/rago-profiled"
cmd=""

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
# Commandes système : sautées sous une fausse racine.
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
	--user) target_user=$2; shift 2 ;;
	--bin) bin=$2; shift 2 ;;
	--root) R=${2%/}; shift 2 ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) die "option inconnue : $1" ;;
	*) [ -z "$cmd" ] || die "une seule commande"; cmd=$1; shift ;;
	esac
done

step_build() {
	[ "$(id -u)" -ne 0 ] || [ "${RAGO_ALLOW_ROOT_BUILD:-0}" = 1 ] ||
		die "compiler sans root (ou RAGO_ALLOW_ROOT_BUILD=1 dans un conteneur jetable)"
	command -v cargo >/dev/null || die "cargo absent (rustup ou paquet rust)"
	run cargo build --release --manifest-path "$repo/Cargo.toml" -p rago-profiled
	log "binaire : $bin"
}

step_install() {
	need_root install
	[ -x "$bin" ] || [ "$dry_run" = 1 ] || die "$bin absent : lancer d'abord « install.sh build » (sans root)"
	run install -Dm 0755 "$bin" "$R/usr/bin/rago-profiled"
	run install -Dm 0644 "$repo/host/systemd/rago-profiled.service" "$R/usr/lib/systemd/system/rago-profiled.service"
	run install -Dm 0644 "$repo/profiles/schema/rago-profile.schema.json" "$R/usr/share/rago/schema/rago-profile.schema.json"
	run install -Dm 0644 "$repo/profiles/README.md" "$R/usr/share/doc/rago/profiles/README.md"
	# Base communautaire : copie exacte (les anciens profils retirés du dépôt disparaissent).
	local dst="$R/usr/share/rago/profiles" f
	run install -d -m 0755 "$dst"
	if [ -d "$dst" ]; then
		for f in "$dst"/*.toml "$dst"/*.json; do
			[ -e "$f" ] || continue
			[ -e "$repo/profiles/community/$(basename "$f")" ] || run rm -f "$f"
		done
	fi
	for f in "$repo/profiles/community"/*.toml "$repo/profiles/community"/*.json; do
		[ -e "$f" ] || continue
		run install -m 0644 "$f" "$dst/"
	done
	run install -d -m 0755 "$R/etc/rago/profiles" "$R/usr/lib/rago/hooks"
	if [ -z "$R" ]; then
		if ! getent group rago >/dev/null; then
			log "création du groupe système « rago » (accès au socket, partagé avec M0)"
			run groupadd --system rago
		fi
		if [ -n "$target_user" ]; then
			log "ajout de $target_user au groupe rago (effectif à la prochaine connexion)"
			run usermod -aG rago "$target_user"
		elif [ -n "${SUDO_USER:-}" ] && ! id -nG "$SUDO_USER" 2>/dev/null | tr ' ' '\n' | grep -qx rago; then
			warn "$SUDO_USER n'est pas dans le groupe rago : relancer avec --user $SUDO_USER"
		fi
		command -v rago-sched-hint >/dev/null ||
			warn "rago-sched-hint (M0) absent : les jeux se lanceront sans hint ordonnanceur"
		[ -f /etc/rago/host-tuning.conf ] ||
			warn "M1 (host/setup_host_tuning.sh) non installé : la « base » sera le réglage actuel du système"
	fi
	sys systemctl daemon-reload
	sys systemctl enable rago-profiled.service
	sys systemctl restart rago-profiled.service
	log "rago-profiled installé. État : rago-profiled status ; profils : rago-profiled list"
}

step_uninstall() {
	need_root uninstall
	sys systemctl disable --now rago-profiled.service
	run rm -f "$R/usr/bin/rago-profiled" "$R/usr/lib/systemd/system/rago-profiled.service" \
		"$R/usr/share/rago/schema/rago-profile.schema.json" "$R/usr/share/doc/rago/profiles/README.md"
	run rm -rf "$R/usr/share/rago/profiles"
	local d
	for d in "$R/usr/share/rago/schema" "$R/usr/share/doc/rago/profiles" "$R/usr/lib/rago/hooks"; do
		[ -d "$d" ] && run rmdir --ignore-fail-on-non-empty "$d"
	done
	sys systemctl daemon-reload
	log "rago-profiled retiré. Gardés : /etc/rago/profiles (profils locaux), le groupe rago (M0)."
}

case "$cmd" in
build) step_build ;;
install) step_install ;;
uninstall) step_uninstall ;;
"") sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
*) die "commande inconnue : $cmd (build | install | uninstall)" ;;
esac
