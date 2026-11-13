#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tuning de l'hôte pour le jeu natif (module M1).
#
# Installe et applique :
#   - le profil tuned « rago-gaming » (dérivé de latency-performance :
#     gouverneur performance, vm.stat_interval=60, kernel.watchdog=0,
#     THP madvise, gestion des C-states au choix) ;
#   - /etc/sysctl.d/99-rago.conf (max_map_count, swappiness, tampons réseau,
#     fq_codel, split_lock_mitigate=0) ;
#   - /etc/udev/rules.d/60-rago-iosched.rules (NVMe none|mq-deadline,
#     SSD SATA mq-deadline, HDD bfq) ;
#   - un swap zram (zram-generator) et zswap coupé (pas de double compression) ;
#   - threadirqs (ajouté à /etc/rago/kernel.conf du noyau Rago, M0) et
#     irqbalance pour une répartition raisonnable des IRQ.
# PAS d'isolation stricte de cœurs : un jeu natif utilise tous les cœurs et
# scx_rago (M0) route déjà le jeu.
#
# Usage : setup_host_tuning.sh [options] [commande]
#
# Commandes :
#   install     (défaut) installe les fichiers et applique tout ; root
#   verify      vérifie que chaque réglage est réellement actif (code 0 = tout
#               bon, 1 = échec, 3 = seulement un redémarrage en attente)
#   status      comme verify
#   uninstall   retire tout et remet l'état d'avant l'installation ; root
#   deps        installe tuned, irqbalance, zram-generator (pacman ou apt) ; root
#
# Options (install ; mémorisées dans /etc/rago/host-tuning.conf) :
#   --cstates deep|shallow|poll   C-states (défaut deep = aucune limite ;
#                                 shallow = comme latency-performance, C1 max ;
#                                 poll = aucun C-state, très chaud)
#   --nvme-scheduler none|mq-deadline   ordonnanceur des NVMe (défaut none)
#   --zram | --no-zram            swap zram de l'hôte (défaut : oui)
#   --threadirqs | --no-threadirqs   IRQ en threads (défaut : oui)
#   --irq-ban LISTE|none          CPU que irqbalance doit éviter (ex. 0-7) ;
#                                 défaut none = toutes les IRQ réparties
#   --keep-ppd                    ne pas arrêter power-profiles-daemon
#                                 (il se battrait avec tuned pour le gouverneur)
# Options générales :
#   --root DIR      installe dans une racine de test (implique --no-apply)
#   --no-apply      écrit les fichiers sans rien appliquer au système vivant
#   --dry-run       affiche les actions sans rien faire
#   -h, --help
#
# Variables d'environnement (tests) : RAGO_SYSFS (défaut /sys),
# RAGO_PROCFS (défaut /proc), RAGO_KERNEL_CONF (défaut /etc/rago/kernel.conf),
# RAGO_VERIFY_LIVE=1 (verify contrôle aussi l'état vivant malgré --root),
# RAGO_TEST_APPLY=1 (applique malgré --root, si RAGO_SYSFS et RAGO_PROCFS
# pointent ailleurs ; réservé aux tests avec des commandes factices).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib/rago_host_lib.sh
. "$here/lib/rago_host_lib.sh"

PROFILE=rago-gaming
SRC_TUNED="$here/tuned/rago-gaming/tuned.conf"
SRC_SYSCTL="$here/sysctl.d/99-rago.conf"
SRC_UDEV="$here/udev/60-rago-iosched.rules"
SRC_ZRAM="$here/zram/rago-zram.conf"

# Chemins sur la machine cible (sans la racine).
P_CONF=/etc/rago/host-tuning.conf
P_STATE=/var/lib/rago/host-tuning
P_KCONF=${RAGO_KERNEL_CONF:-/etc/rago/kernel.conf}
P_SYSCTL=/etc/sysctl.d/99-rago.conf
P_UDEV=/etc/udev/rules.d/60-rago-iosched.rules
P_ZRAM=/etc/systemd/zram-generator.conf.d/rago.conf
P_TUNED_VARS=/etc/tuned/rago-gaming-variables.conf
P_IRQ_DROPIN=/etc/systemd/system/irqbalance.service.d/rago.conf

SYS=${RAGO_SYSFS:-/sys}
PROC=${RAGO_PROCFS:-/proc}

root=/
apply=1
dry_run=0
cmd=""
opt_cstates="" opt_nvme="" opt_zram="" opt_threadirqs="" opt_irq_ban="" opt_keep_ppd=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n "3,/^set -euo/p" "$0" | sed -e "\$d" -e "s/^# \{0,1\}//"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--cstates) [ $# -ge 2 ] || die "--cstates attend une valeur"; opt_cstates=$2; shift 2 ;;
	--nvme-scheduler) [ $# -ge 2 ] || die "--nvme-scheduler attend une valeur"; opt_nvme=$2; shift 2 ;;
	--zram) opt_zram=1; shift ;;
	--no-zram) opt_zram=0; shift ;;
	--threadirqs) opt_threadirqs=1; shift ;;
	--no-threadirqs) opt_threadirqs=0; shift ;;
	--irq-ban) [ $# -ge 2 ] || die "--irq-ban attend une liste de CPU ou none"; opt_irq_ban=$2; shift 2 ;;
	--keep-ppd) opt_keep_ppd=1; shift ;;
	--root) [ $# -ge 2 ] || die "--root attend un dossier"; root=$2; shift 2 ;;
	--no-apply) apply=0; shift ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) usage; exit 0 ;;
	install | verify | status | uninstall | deps)
		[ -z "$cmd" ] || die "une seule commande à la fois ($cmd, $1)"
		cmd=$1; shift ;;
	*) die "option ou commande inconnue : $1 (--help)" ;;
	esac
done
cmd=${cmd:-install}

root=${root%/}
[ -z "$root" ] || [ -d "$root" ] || die "--root : dossier introuvable : $root"
# Une racine de test ne doit jamais toucher au système vivant. Exception pour
# host/tests/test_setup_sysroot.sh : RAGO_TEST_APPLY=1 avec un faux /sys et un
# faux /proc ET des commandes systemctl / tuned-adm / udevadm factices.
if [ -n "$root" ]; then
	if [ "${RAGO_TEST_APPLY:-0}" = 1 ] && [ "$SYS" != /sys ] && [ "$PROC" != /proc ]; then
		:
	else
		apply=0
	fi
fi
R=$root # préfixe de tous les chemins de fichiers

# --- utilitaires ---------------------------------------------------------------------------
run() {
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] %s\n' "$*"
	else
		"$@"
	fi
}

need_root() {
	[ "$dry_run" = 1 ] && return 0
	[ -n "$R" ] && return 0
	[ "$(id -u)" -eq 0 ] || die "« $1 » doit être lancé en root (sudo)"
}

have() { command -v "$1" >/dev/null 2>&1; }

has_unit() { systemctl cat "$1" >/dev/null 2>&1; }

state() { echo "$R$P_STATE/$1"; }

# Nom de sauvegarde d'un chemin : /etc/a/b -> backup/etc%a%b
backup_path() { local p=${1#/}; echo "$(state backup)/${p//\//%}"; }

# Le fichier appartient-il à M1 (contient le marqueur) ?
is_ours() { grep -qs "$RAGO_HOST_MARKER" "$1"; }

manifest_add() {
	local m
	m=$(state manifest)
	grep -qxF "$1" "$m" 2>/dev/null || echo "$1" >> "$m"
}

# Écrit le contenu de l'entrée standard dans <chemin cible> (atomique), en
# sauvegardant d'abord un fichier existant qui n'est pas à nous.
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
			log "sauvegarde de $p (restauré à la désinstallation)"
		fi
	fi
	tmp=$(mktemp "$dst.rago.XXXXXX")
	if ! cat > "$tmp"; then rm -f "$tmp"; die "écriture impossible : $dst"; fi
	chmod "$mode" "$tmp"
	mv -f "$tmp" "$dst"
	manifest_add "$p"
}

# Retire un fichier installé par M1 et remet la sauvegarde s'il y en a une.
remove_file() {
	local p=$1 dst="$R$1" b
	b=$(backup_path "$p")
	if [ -e "$dst" ] && ! is_ours "$dst"; then
		warn "$p ne vient pas de Rago (modifié à la main ?) : laissé en place"
		return 0
	fi
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] retirer %s\n' "$dst"
		return 0
	fi
	rm -f "$dst"
	if [ -e "$b" ]; then
		mv -f "$b" "$dst"
		log "restauré : $p"
	fi
}

# --- réglages (défauts < /etc/rago/host-tuning.conf < options) ----------------------
load_settings() {
	local c="$R$P_CONF"
	CSTATES=$(rago_conf_get "$c" RAGO_CSTATES deep)
	NVME_SCHED=$(rago_conf_get "$c" RAGO_NVME_SCHED none)
	ZRAM=$(rago_conf_get "$c" RAGO_ZRAM 1)
	THREADIRQS=$(rago_conf_get "$c" RAGO_THREADIRQS 1)
	IRQ_BAN=$(rago_conf_get "$c" RAGO_IRQ_BAN none)
	KEEP_PPD=$(rago_conf_get "$c" RAGO_KEEP_PPD 0)
	[ -n "$opt_cstates" ] && CSTATES=$opt_cstates
	[ -n "$opt_nvme" ] && NVME_SCHED=$opt_nvme
	[ -n "$opt_zram" ] && ZRAM=$opt_zram
	[ -n "$opt_threadirqs" ] && THREADIRQS=$opt_threadirqs
	[ -n "$opt_irq_ban" ] && IRQ_BAN=$opt_irq_ban
	[ -n "$opt_keep_ppd" ] && KEEP_PPD=$opt_keep_ppd

	FORCE_LATENCY=$(rago_cstates_latency "$CSTATES") || die "--cstates invalide : $CSTATES (deep|shallow|poll)"
	rago_valid_nvme_sched "$NVME_SCHED" || die "--nvme-scheduler invalide : $NVME_SCHED (none|mq-deadline)"
	case "$ZRAM$THREADIRQS$KEEP_PPD" in *[!01]*) die "valeur invalide dans $P_CONF (RAGO_ZRAM / RAGO_THREADIRQS / RAGO_KEEP_PPD : 0 ou 1)" ;; esac
	if [ "$IRQ_BAN" != none ]; then
		rago_cpulist_valid "$IRQ_BAN" || die "--irq-ban invalide : $IRQ_BAN (ex. 0-7,16-23 ou none)"
	fi
	TUNED_DIR="$(rago_tuned_profile_dir "$R")/$PROFILE"
}

save_settings() {
	local c="$R$P_CONF"
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] écrire %s (RAGO_CSTATES=%s RAGO_NVME_SCHED=%s RAGO_ZRAM=%s RAGO_THREADIRQS=%s RAGO_IRQ_BAN=%s RAGO_KEEP_PPD=%s)\n' \
			"$c" "$CSTATES" "$NVME_SCHED" "$ZRAM" "$THREADIRQS" "$IRQ_BAN" "$KEEP_PPD"
		return 0
	fi
	mkdir -p "$(dirname "$c")"
	if [ ! -f "$c" ]; then
		cat > "$c" <<-EOF
		# Rago OS — choix du tuning hôte (module M1). Marqueur : $RAGO_HOST_MARKER
		# Relu par host/setup_host_tuning.sh ; après modification : sudo setup_host_tuning.sh install
		#   RAGO_CSTATES     deep | shallow | poll
		#   RAGO_NVME_SCHED  none | mq-deadline
		#   RAGO_ZRAM        1 = swap zram de l'hôte, 0 = non
		#   RAGO_THREADIRQS  1 = threadirqs au démarrage, 0 = non
		#   RAGO_IRQ_BAN     CPU évités par irqbalance (ex. 0-7) ou none
		#   RAGO_KEEP_PPD    1 = laisser power-profiles-daemon actif
		EOF
	fi
	rago_conf_set "$c" RAGO_CSTATES "$CSTATES"
	rago_conf_set "$c" RAGO_NVME_SCHED "$NVME_SCHED"
	rago_conf_set "$c" RAGO_ZRAM "$ZRAM"
	rago_conf_set "$c" RAGO_THREADIRQS "$THREADIRQS"
	rago_conf_set "$c" RAGO_IRQ_BAN "$IRQ_BAN"
	rago_conf_set "$c" RAGO_KEEP_PPD "$KEEP_PPD"
}

# Jetons de ligne de commande voulus par M1.
wanted_tokens() {
	local t=""
	[ "$THREADIRQS" = 1 ] && t="$t threadirqs"
	[ "$ZRAM" = 1 ] && t="$t zswap.enabled=0"
	echo "${t# }"
}

# --- tuned ---------------------------------------------------------------------------------
tuned_active() {
	tuned-adm active 2>/dev/null | rago_tuned_active_from_output
}

# Profil choisi, même si le daemon est arrêté (ex. arrêté par
# power-profiles-daemon, Conflicts=) : tuned le garde dans active_profile.
tuned_selected() {
	local p
	p=$(tuned_active || true)
	if [ -z "$p" ] && [ -r "$R/etc/tuned/active_profile" ]; then
		p=$(head -1 "$R/etc/tuned/active_profile")
	fi
	echo "$p"
}

# --- deps ----------------------------------------------------------------------------------
step_deps() {
	need_root deps
	[ -z "$R" ] || die "deps ne marche pas avec --root"
	if have pacman; then
		run pacman -S --needed --noconfirm tuned irqbalance zram-generator
	elif have apt-get; then
		run apt-get install -y tuned irqbalance systemd-zram-generator
	else
		die "ni pacman ni apt-get : installe tuned, irqbalance et zram-generator à la main"
	fi
}

check_tools() {
	local missing="" t
	for t in tuned-adm systemctl udevadm; do
		have "$t" || missing="$missing $t"
	done
	[ -z "$missing" ] || die "outils manquants :$missing (sudo $0 deps)"
}

zram_generator_present() {
	local d
	for d in /usr/lib/systemd/system-generators /lib/systemd/system-generators; do
		[ -x "$R$d/zram-generator" ] && return 0
	done
	return 1
}

# --- install -------------------------------------------------------------------------------
install_files() {
	local nvme_rule
	log "profil tuned : $TUNED_DIR/tuned.conf"
	put_file "$TUNED_DIR/tuned.conf" 0644 < "$SRC_TUNED"
	{
		printf '# Rago OS — variables du profil tuned %s (module M1).\n' "$PROFILE"
		printf '# Écrit par host/setup_host_tuning.sh. Marqueur : %s\n' "$RAGO_HOST_MARKER"
		printf '# Mode C-states : deep | shallow | poll\n'
		printf 'rago_cstates=%s\n' "$CSTATES"
		printf '# Valeur passée à [cpu] force_latency.\n'
		printf 'rago_force_latency=%s\n' "$FORCE_LATENCY"
	} | put_file "$P_TUNED_VARS" 0644

	log "sysctl : $P_SYSCTL"
	put_file "$P_SYSCTL" 0644 < "$SRC_SYSCTL"

	log "udev : $P_UDEV (NVMe : $NVME_SCHED)"
	nvme_rule=$(sed "s/@NVME_SCHED@/$NVME_SCHED/g" "$SRC_UDEV")
	printf '%s\n' "$nvme_rule" | put_file "$P_UDEV" 0644

	if [ "$ZRAM" = 1 ]; then
		if zram_generator_present || [ "$apply" = 0 ]; then
			log "zram : $P_ZRAM"
			put_file "$P_ZRAM" 0644 < "$SRC_ZRAM"
		else
			warn "zram-generator absent : pas de swap zram (sudo $0 deps)"
		fi
	elif [ -e "$R$P_ZRAM" ]; then
		remove_file "$P_ZRAM"
	fi

	if [ "$IRQ_BAN" != none ]; then
		log "irqbalance : CPU évités $IRQ_BAN"
		{
			printf '# Rago OS — répartition des IRQ (module M1). Marqueur : %s\n' "$RAGO_HOST_MARKER"
			printf '# Les IRQ restent sur les autres CPU ; aucune isolation des tâches.\n'
			printf '[Service]\n'
			printf 'Environment=IRQBALANCE_BANNED_CPULIST=%s\n' "$IRQ_BAN"
		} | put_file "$P_IRQ_DROPIN" 0644
	elif [ -e "$R$P_IRQ_DROPIN" ]; then
		remove_file "$P_IRQ_DROPIN"
	fi
}

# Ligne de commande du noyau Rago (M0) : /etc/rago/kernel.conf, RAGO_CMDLINE_EXTRA.
update_kernel_cmdline() {
	local kc="$R$P_KCONF" want extra new added_file added="" t prev_added
	want=$(wanted_tokens)
	added_file=$(state cmdline-tokens)
	prev_added=$(cat "$added_file" 2>/dev/null || true)
	if [ ! -f "$kc" ]; then
		if [ -n "$want" ]; then
			warn "$P_KCONF absent (noyau Rago M0 pas installé) : ajoute « $want » à la ligne de commande de ton chargeur de démarrage à la main"
		fi
		return 0
	fi
	extra=$(rago_conf_get "$kc" RAGO_CMDLINE_EXTRA "")
	new=$extra
	# Retire ce que M1 avait ajouté et qui n'est plus voulu.
	for t in $prev_added; do
		rago_cmdline_has "$want" "$t" || new=$(rago_cmdline_remove "$new" "$t")
	done
	for t in $want; do
		if ! rago_cmdline_has "$new" "$t"; then
			new=$(rago_cmdline_add "$new" "$t")
			added="$added $t"
		elif rago_cmdline_has "$prev_added" "$t"; then
			added="$added $t"
		fi
	done
	added=${added# }
	if [ "$new" = "$extra" ]; then
		[ "$dry_run" = 1 ] || printf '%s\n' "$added" > "$added_file"
		return 0
	fi
	log "ligne de commande du noyau Rago : RAGO_CMDLINE_EXTRA=\"$new\""
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] écrire RAGO_CMDLINE_EXTRA dans %s\n' "$kc"
		return 0
	fi
	rago_conf_set "$kc" RAGO_CMDLINE_EXTRA "$new"
	printf '%s\n' "$added" > "$added_file"
	NEED_BOOTLOADER=1
}

# Valeurs sysctl d'avant l'installation (une seule fois), pour les remettre.
save_sysctl_before() {
	local f k v opt p out
	out=$(state sysctl-before)
	[ -e "$out" ] && return 0
	[ "$dry_run" = 1 ] && return 0
	: > "$out"
	while IFS=$'\t' read -r k v opt; do
		p="$PROC/sys/$(rago_sysctl_path "$k")"
		[ -r "$p" ] || continue
		f=$(rago_norm_ws "$(cat "$p")")
		printf '%s\t%s\n' "$k" "$f" >> "$out"
	done < <(rago_sysctl_entries "$SRC_SYSCTL")
}

# Ordonnanceurs d'E/S d'avant l'installation (une seule fois).
save_iosched_before() {
	local out d name cur
	out=$(state iosched-before)
	[ -e "$out" ] && return 0
	[ "$dry_run" = 1 ] && return 0
	: > "$out"
	for d in "$SYS"/block/*; do
		[ -r "$d/queue/scheduler" ] || continue
		name=${d##*/}
		cur=$(rago_sched_current "$(cat "$d/queue/scheduler")") || continue
		printf '%s\t%s\n' "$name" "$cur" >> "$out"
	done
}

apply_ppd() {
	if [ "$KEEP_PPD" = 1 ]; then
		systemctl is-active -q power-profiles-daemon 2>/dev/null &&
			warn "power-profiles-daemon reste actif (--keep-ppd) : il peut changer le gouverneur derrière tuned"
		return 0
	fi
	if systemctl is-active -q power-profiles-daemon 2>/dev/null; then
		log "arrêt de power-profiles-daemon (il se battrait avec tuned ; remis à la désinstallation)"
		[ "$dry_run" = 1 ] || touch "$(state ppd-disabled)"
		run systemctl disable --now power-profiles-daemon
	fi
}

apply_sysctl() {
	log "application des sysctl"
	if ! run systemctl restart systemd-sysctl.service; then
		warn "systemd-sysctl a signalé une erreur : journalctl -u systemd-sysctl"
	fi
}

apply_udev() {
	log "application de l'ordonnanceur d'E/S"
	run udevadm control --reload-rules
	run udevadm trigger --action=change --subsystem-match=block
	run udevadm settle --timeout=30 || warn "udevadm settle : délai dépassé"
}

apply_zram() {
	local zs="$SYS/module/zswap/parameters/enabled" cur
	if [ "$ZRAM" = 1 ]; then
		# zswap compresse déjà le swap en RAM : avec zram, double compression.
		if [ -w "$zs" ]; then
			cur=$(cat "$zs")
			if [ "$cur" != N ] && [ "$cur" != 0 ]; then
				log "zswap coupé (zram le remplace)"
				[ -e "$(state zswap-before)" ] || [ "$dry_run" = 1 ] || printf '%s\n' "$cur" > "$(state zswap-before)"
				[ "$dry_run" = 1 ] || echo N > "$zs"
			fi
		fi
		if [ -e "$R$P_ZRAM" ] || [ "$dry_run" = 1 ]; then
			run systemctl daemon-reload
			if grep -qs '^/dev/zram' "$PROC/swaps"; then
				log "swap zram déjà actif (nouvelle taille au prochain démarrage)"
			else
				log "création du swap zram"
				[ "$dry_run" = 1 ] || touch "$(state zram-started)"
				run systemctl restart systemd-zram-setup@zram0.service ||
					warn "systemd-zram-setup@zram0 a échoué : journalctl -u systemd-zram-setup@zram0"
			fi
		fi
	else
		run systemctl daemon-reload
		if [ -e "$(state zram-started)" ]; then
			run systemctl stop systemd-zram-setup@zram0.service || true
			[ "$dry_run" = 1 ] || rm -f "$(state zram-started)"
		fi
		restore_zswap
	fi
}

restore_zswap() {
	local zs="$SYS/module/zswap/parameters/enabled" b
	b=$(state zswap-before)
	[ -e "$b" ] || return 0
	if [ -w "$zs" ] && [ "$dry_run" = 0 ]; then
		cat "$b" > "$zs"
		log "zswap remis à $(cat "$b")"
	fi
	[ "$dry_run" = 1 ] || rm -f "$b"
}

apply_irqbalance() {
	if ! has_unit irqbalance.service; then
		warn "irqbalance absent : les IRQ restent sur la répartition par défaut du noyau (sudo $0 deps)"
		return 0
	fi
	if [ ! -e "$(state irqbalance-was-enabled)" ] && [ "$dry_run" = 0 ]; then
		if systemctl is-enabled -q irqbalance.service 2>/dev/null; then echo 1; else echo 0; fi > "$(state irqbalance-was-enabled)"
	fi
	log "irqbalance : activé$([ "$IRQ_BAN" != none ] && echo " (CPU évités : $IRQ_BAN)")"
	run systemctl daemon-reload
	run systemctl enable irqbalance.service
	run systemctl restart irqbalance.service || warn "irqbalance n'a pas démarré : journalctl -u irqbalance"
}

apply_tuned() {
	if [ ! -e "$(state tuned-was-enabled)" ] && [ "$dry_run" = 0 ]; then
		if systemctl is-enabled -q tuned.service 2>/dev/null; then echo 1; else echo 0; fi > "$(state tuned-was-enabled)"
	fi
	log "activation de tuned, profil $PROFILE"
	run systemctl enable tuned.service
	# Redémarrage : relit le profil et ses variables même si le nom n'a pas changé.
	run systemctl restart tuned.service || die "tuned ne démarre pas : journalctl -u tuned"
	run tuned-adm profile "$PROFILE" || die "tuned-adm profile $PROFILE a échoué : journalctl -u tuned"
}

step_install() {
	need_root install
	load_settings
	if [ "$apply" = 1 ]; then check_tools; fi
	NEED_BOOTLOADER=0
	[ "$dry_run" = 1 ] || mkdir -p "$(state backup)"

	# Profil tuned d'avant Rago, mémorisé une seule fois (pour la désinstallation).
	if [ "$apply" = 1 ] && [ ! -e "$(state previous-tuned-profile)" ] && [ "$dry_run" = 0 ]; then
		local prev
		prev=$(tuned_selected)
		[ "$prev" = "$PROFILE" ] && prev=""
		printf '%s\n' "${prev:-none}" > "$(state previous-tuned-profile)"
		if systemctl is-active -q tuned.service 2>/dev/null; then echo 1; else echo 0; fi > "$(state tuned-was-active)"
	fi
	if [ "$apply" = 1 ]; then
		save_sysctl_before
		save_iosched_before
	fi

	install_files
	update_kernel_cmdline
	save_settings

	if [ "$apply" = 0 ]; then
		log "fichiers écrits dans ${R:-/} (rien appliqué : --no-apply / --root)"
		return 0
	fi
	apply_ppd
	apply_sysctl
	apply_udev
	apply_zram
	apply_irqbalance
	apply_tuned

	if [ "$NEED_BOOTLOADER" = 1 ]; then
		warn "ligne de commande changée ($(wanted_tokens)) : sudo kernel/build_rago_kernel.sh bootloader, puis redémarrer"
	fi
	log "installation terminée ; vérification :"
	local rc=0
	step_verify || rc=$?
	case "$rc" in
	0) log "tout est actif" ;;
	3) log "tout est actif sauf ce qui attend un redémarrage" ;;
	*) warn "certains réglages ne sont pas actifs (voir ci-dessus)" ;;
	esac
	return 0
}

# --- uninstall -----------------------------------------------------------------------------
restore_sysctl() {
	local f k v p
	f=$(state sysctl-before)
	[ -e "$f" ] || return 0
	while IFS=$'\t' read -r k v; do
		p="$PROC/sys/$(rago_sysctl_path "$k")"
		[ -w "$p" ] || continue
		if [ "$dry_run" = 1 ]; then
			printf '[dry-run] %s = %s\n' "$k" "$v"
		else
			printf '%s\n' "$v" > "$p" 2>/dev/null || warn "impossible de remettre $k = $v"
		fi
	done < "$f"
	log "sysctl remis aux valeurs d'avant"
}

restore_iosched() {
	local f name s p
	f=$(state iosched-before)
	[ -e "$f" ] || return 0
	while IFS=$'\t' read -r name s; do
		p="$SYS/block/$name/queue/scheduler"
		[ -w "$p" ] || continue
		if [ "$dry_run" = 1 ]; then
			printf '[dry-run] %s : %s\n' "$name" "$s"
		else
			printf '%s\n' "$s" > "$p" 2>/dev/null || warn "impossible de remettre $s sur $name"
		fi
	done < "$f"
	log "ordonnanceurs d'E/S remis à ceux d'avant"
}

step_uninstall() {
	need_root uninstall
	local st="$R$P_STATE" p prev kc extra new t
	if [ ! -d "$st" ] && [ ! -e "$R$P_CONF" ]; then
		log "rien à désinstaller (pas d'état dans $P_STATE)"
		return 0
	fi
	load_settings

	if [ "$apply" = 1 ] && have tuned-adm; then
		prev=$(cat "$(state previous-tuned-profile)" 2>/dev/null || echo none)
		if [ "$prev" != none ] && [ -n "$prev" ]; then
			log "tuned : retour au profil $prev"
			run tuned-adm profile "$prev" || warn "profil $prev introuvable"
		else
			log "tuned : aucun profil (comme avant)"
			run tuned-adm off || true
		fi
		if [ "$(cat "$(state tuned-was-enabled)" 2>/dev/null)" = 0 ]; then
			run systemctl disable --now tuned.service || true
		elif [ "$(cat "$(state tuned-was-active)" 2>/dev/null)" = 0 ]; then
			run systemctl stop tuned.service || true
		fi
	fi

	# Fichiers : tout le manifeste, plus les chemins connus (installation partielle).
	{
		cat "$(state manifest)" 2>/dev/null || true
		printf '%s\n' "$TUNED_DIR/tuned.conf" "$P_TUNED_VARS" "$P_SYSCTL" "$P_UDEV" "$P_ZRAM" "$P_IRQ_DROPIN"
	} | sort -u | while read -r p; do
		[ -n "$p" ] || continue
		if [ -e "$R$p" ] || [ -e "$(backup_path "$p")" ]; then remove_file "$p"; fi
	done
	if [ "$dry_run" = 0 ]; then
		rmdir "$R$TUNED_DIR" "$R$(dirname "$P_ZRAM")" "$R$(dirname "$P_IRQ_DROPIN")" 2>/dev/null || true
	fi

	# Ligne de commande : on retire seulement ce que M1 a ajouté.
	kc="$R$P_KCONF"
	if [ -f "$kc" ] && [ -s "$(state cmdline-tokens)" ]; then
		extra=$(rago_conf_get "$kc" RAGO_CMDLINE_EXTRA "")
		new=$extra
		for t in $(<"$(state cmdline-tokens)"); do new=$(rago_cmdline_remove "$new" "$t"); done
		if [ "$new" != "$extra" ]; then
			log "ligne de commande du noyau Rago : RAGO_CMDLINE_EXTRA=\"$new\""
			[ "$dry_run" = 1 ] || rago_conf_set "$kc" RAGO_CMDLINE_EXTRA "$new"
			[ "$apply" = 1 ] && warn "puis : sudo kernel/build_rago_kernel.sh bootloader et redémarrer"
		fi
	fi

	if [ "$apply" = 1 ]; then
		restore_sysctl
		run systemctl restart systemd-sysctl.service || true
		run udevadm control --reload-rules || true
		restore_iosched
		run systemctl daemon-reload || true
		if [ -e "$(state zram-started)" ]; then
			log "arrêt du swap zram créé par Rago"
			run systemctl stop systemd-zram-setup@zram0.service || true
		fi
		restore_zswap
		if has_unit irqbalance.service; then
			if [ "$(cat "$(state irqbalance-was-enabled)" 2>/dev/null)" = 0 ]; then
				run systemctl disable --now irqbalance.service || true
			else
				run systemctl restart irqbalance.service || true
			fi
		fi
		if [ -e "$(state ppd-disabled)" ]; then
			log "power-profiles-daemon remis en marche"
			run systemctl enable --now power-profiles-daemon || warn "power-profiles-daemon ne redémarre pas"
		fi
	fi

	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] retirer %s et %s\n' "$R$P_CONF" "$st"
	else
		rm -f "$R$P_CONF"
		rm -rf "$st"
	fi
	log "désinstallation terminée"
}

# --- verify --------------------------------------------------------------------------------
n_ok=0 n_fail=0 n_warn=0 n_boot=0 n_skip=0
ok()    { n_ok=$((n_ok + 1));     printf '  [ OK ]        %s\n' "$*"; }
ko()    { n_fail=$((n_fail + 1)); printf '  [ ÉCHEC ]     %s\n' "$*"; }
att()   { n_warn=$((n_warn + 1)); printf '  [ ATTENTION ] %s\n' "$*"; }
boot()  { n_boot=$((n_boot + 1)); printf '  [ REDÉMARRER ] %s\n' "$*"; }
skip()  { n_skip=$((n_skip + 1)); printf '  [ IGNORÉ ]    %s\n' "$*"; }

verify_files() {
	local p
	for p in "$TUNED_DIR/tuned.conf" "$P_TUNED_VARS" "$P_SYSCTL" "$P_UDEV"; do
		if is_ours "$R$p"; then ok "fichier $p"; else ko "fichier $p absent ou pas de Rago"; fi
	done
	if [ "$ZRAM" = 1 ]; then
		if is_ours "$R$P_ZRAM"; then ok "fichier $P_ZRAM"; else ko "fichier $P_ZRAM absent (zram-generator installé ?)"; fi
	fi
	if grep -qs "^rago_force_latency=$FORCE_LATENCY\$" "$R$P_TUNED_VARS"; then
		ok "C-states demandés : $CSTATES"
	else
		ko "variables tuned différentes de RAGO_CSTATES=$CSTATES (relancer install)"
	fi
}

verify_tuned() {
	local act
	if ! have tuned-adm; then ko "tuned-adm absent"; return; fi
	if systemctl is-active -q tuned.service 2>/dev/null; then ok "service tuned actif"; else ko "service tuned arrêté"; fi
	act=$(tuned_active || true)
	if [ "$act" = "$PROFILE" ]; then ok "tuned-adm active = $PROFILE"; else ko "tuned-adm active = ${act:-aucun} (attendu $PROFILE)"; fi
	if [ "$act" = "$PROFILE" ]; then
		if tuned-adm verify >/dev/null 2>&1; then
			ok "tuned-adm verify : profil appliqué"
		else
			ko "tuned-adm verify : écarts (détail : /var/log/tuned/tuned.log)"
		fi
	fi
}

verify_cpu() {
	local g n=0 bad="" cpu f v
	for f in "$SYS"/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
		[ -r "$f" ] || continue
		n=$((n + 1))
		g=$(cat "$f")
		cpu=${f#"$SYS"/devices/system/cpu/}; cpu=${cpu%%/*}
		[ "$g" = performance ] || bad="$bad $cpu=$g"
	done
	if [ "$n" = 0 ]; then
		skip "gouverneur : pas de cpufreq (VM ou pilote absent)"
	elif [ -z "$bad" ]; then
		ok "gouverneur performance sur $n CPU"
	else
		ko "gouverneur pas en performance :$bad"
	fi

	if [ -r /dev/cpu_dma_latency ] && [ "$SYS" = /sys ]; then
		v=$(od -An -t d4 -N4 /dev/cpu_dma_latency 2>/dev/null | tr -d ' ')
		if rago_cstates_check "$CSTATES" "$v"; then
			ok "C-states $CSTATES (cpu_dma_latency = $v µs)"
		else
			ko "C-states : cpu_dma_latency = ${v:-?} µs, pas conforme au mode $CSTATES"
		fi
	else
		skip "C-states : /dev/cpu_dma_latency illisible"
	fi
}

verify_kernel_knobs() {
	local f v
	f="$SYS/kernel/mm/transparent_hugepage/enabled"
	if [ -r "$f" ]; then
		v=$(rago_sched_current "$(cat "$f")" || true)
		if [ "$v" = madvise ]; then ok "THP = madvise"; else ko "THP = ${v:-?} (attendu madvise ; un profil de jeu M14 peut le changer pendant un jeu)"; fi
	else
		skip "THP : $f absent"
	fi
	local k want
	while read -r k want; do
		f="$PROC/sys/$(rago_sysctl_path "$k")"
		if [ -r "$f" ]; then
			v=$(cat "$f")
			if [ "$v" = "$want" ]; then ok "$k = $want (tuned)"; else ko "$k = $v (attendu $want)"; fi
		else
			skip "$k : absent de ce noyau"
		fi
	done <<-EOF
	vm.stat_interval 60
	kernel.watchdog 0
	EOF
}

verify_sysctl() {
	local k v opt f cur
	while IFS=$'\t' read -r k v opt; do
		f="$PROC/sys/$(rago_sysctl_path "$k")"
		if [ ! -r "$f" ]; then
			if [ "$opt" = 1 ]; then skip "$k : absent de ce noyau/CPU (facultatif)"; else ko "$k : absent"; fi
			continue
		fi
		cur=$(rago_norm_ws "$(cat "$f")")
		if [ "$cur" = "$v" ]; then ok "$k = $v"; else ko "$k = $cur (attendu $v)"; fi
	done < <(rago_sysctl_entries "$R$P_SYSCTL" 2>/dev/null || rago_sysctl_entries "$SRC_SYSCTL")
}

verify_iosched() {
	local d name rot list cur want n=0
	for d in "$SYS"/block/*; do
		[ -r "$d/queue/scheduler" ] || continue
		name=${d##*/}
		rot=$(cat "$d/queue/rotational" 2>/dev/null || echo "?")
		want=$(rago_expected_sched "$name" "$rot" "$NVME_SCHED") || continue
		n=$((n + 1))
		list=$(cat "$d/queue/scheduler")
		cur=$(rago_sched_current "$list" || echo "?")
		if [ "$cur" = "$want" ]; then
			ok "E/S $name : $cur"
		elif ! rago_sched_available "$list" "$want"; then
			att "E/S $name : $want absent du noyau (dispo : $list)"
		else
			ko "E/S $name : $cur (attendu $want)"
		fi
	done
	[ "$n" -gt 0 ] || skip "E/S : aucun disque NVMe / SATA / eMMC"
}

verify_zram() {
	local zs="$SYS/module/zswap/parameters/enabled" v
	[ "$ZRAM" = 1 ] || { skip "zram désactivé (RAGO_ZRAM=0)"; return; }
	if grep -qs '^/dev/zram' "$PROC/swaps"; then
		ok "swap zram actif ($(awk '/^\/dev\/zram/ {print $1 " prio " $5}' "$PROC/swaps" | head -1))"
	else
		ko "aucun swap zram dans /proc/swaps"
	fi
	if [ -r "$zs" ]; then
		v=$(cat "$zs")
		if [ "$v" = N ] || [ "$v" = 0 ]; then ok "zswap coupé"; else ko "zswap actif ($v) : double compression avec zram"; fi
	fi
}

verify_irq() {
	local cl kc iso
	cl=$(cat "$PROC/cmdline" 2>/dev/null || true)
	kc="$R$P_KCONF"
	for t in $(wanted_tokens); do
		if rago_cmdline_has "$cl" "$t"; then
			ok "démarrage : $t"
		elif [ -f "$kc" ] && rago_cmdline_has "$(rago_conf_get "$kc" RAGO_CMDLINE_EXTRA "")" "$t"; then
			boot "démarrage : $t est dans $P_KCONF, pas encore actif (build_rago_kernel.sh bootloader + redémarrer)"
		elif [ "$t" = zswap.enabled=0 ] && [ ! -r "$SYS/module/zswap/parameters/enabled" ]; then
			skip "démarrage : zswap absent du noyau, $t inutile"
		else
			att "démarrage : $t absent (noyau Rago M0 pas installé ? ajouter à la main)"
		fi
	done
	iso=$(rago_cmdline_isolation "$cl")
	if [ -n "$iso" ]; then
		att "isolation de cœurs sur la ligne de commande ($iso) : Rago ne le fait pas exprès, le jeu natif doit avoir tous les cœurs"
	else
		ok "pas d'isolation stricte de cœurs"
	fi
	if has_unit irqbalance.service; then
		if systemctl is-active -q irqbalance.service 2>/dev/null; then ok "irqbalance actif"; else ko "irqbalance arrêté"; fi
	else
		att "irqbalance absent : IRQ sur la répartition par défaut"
	fi
	if systemctl is-active -q power-profiles-daemon 2>/dev/null; then
		if [ "$KEEP_PPD" = 1 ]; then att "power-profiles-daemon actif (--keep-ppd)"; else ko "power-profiles-daemon actif : il se bat avec tuned"; fi
	fi
}

step_verify() {
	load_settings
	n_ok=0 n_fail=0 n_warn=0 n_boot=0 n_skip=0
	printf 'Rago OS — vérification du tuning hôte (M1)\n'
	verify_files
	# RAGO_VERIFY_LIVE=1 : tests, vérifie aussi l'état vivant (faux /sys, /proc)
	# avec une racine de test.
	if [ "$apply" = 1 ] || [ "${RAGO_VERIFY_LIVE:-0}" = 1 ]; then
		verify_tuned
		verify_cpu
		verify_kernel_knobs
		verify_sysctl
		verify_iosched
		verify_zram
		verify_irq
	fi
	printf 'Bilan : %d OK, %d échec(s), %d attention, %d redémarrage(s) en attente, %d ignoré(s)\n' \
		"$n_ok" "$n_fail" "$n_warn" "$n_boot" "$n_skip"
	if [ "$n_fail" -gt 0 ]; then return 1; fi
	if [ "$n_boot" -gt 0 ]; then return 3; fi
	return 0
}

case "$cmd" in
install) step_install ;;
verify | status) step_verify ;;
uninstall) step_uninstall ;;
deps) step_deps ;;
esac
