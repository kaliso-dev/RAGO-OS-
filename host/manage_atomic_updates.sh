#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — mises à jour atomiques A/B + UKI signée (module M4).
# Installé sous le nom « rago-update ».
#
# Deux racines complètes, chacune sur son volume chiffré (M3) : slot A (rago-a)
# et slot B (rago-b). On n'écrit JAMAIS le slot en marche : une mise à jour
# remplit le slot inactif, puis le prochain démarrage l'ESSAIE une seule fois
# (systemd-boot, entrée à usage unique). S'il atteint multi-user.target, il
# devient le défaut (le dernier slot bon connu) ; sinon (blocage, mode de
# secours, panne) le chien de garde redémarre et systemd-boot reprend le défaut :
# retour arrière automatique.
#
# Chaque slot démarre par SA propre UKI (Unified Kernel Image) : noyau de M0 +
# initramfs du slot (sa crypttab) + ligne de commande, en un seul fichier EFI
# signé avec la clé MOK de M0 (EFI/Linux/rago-a.efi, rago-b.efi sur l'ESP).
# Secure Boot refuse une UKI modifiée : l'initramfs n'est plus un fichier non
# vérifié et la ligne de commande ne se change plus au menu (fin du trou
# « evil maid » de M3). Le TPM (M3) est lié en plus à PCR 11, où systemd-stub
# mesure l'UKI : sa valeur est PRÉDITE depuis le fichier, avant le redémarrage
# (host/lib/rago_uki_lib.sh), et rago-encryption reseal enrôle un jeton par UKI.
# La passphrase de secours n'est jamais retirée.
#
# Dégradation, jamais de brique : sans UKI possible (ukify, systemd-stub, clé
# MOK absents), chaque slot reçoit une entrée de repli (noyau signé + initramfs
# du slot, PCR 0+7 seulement, signalé) ; si PCR 11 ne se prédit pas, le jeton
# reste en PCR 0+7 ; si le re-scellement échoue, la passphrase est demandée au
# démarrage puis « sudo rago-encryption reseal ».
#
# Usage : manage_atomic_updates.sh [options] <commande>
#
# Commandes :
#   check        prérequis : volumes M3, ESP, systemd-boot signé, ukify,
#                systemd-stub, clé MOK, PCR 11 ; code 0 = prêt, 1 = non
#   setup        met M4 en place sur le slot en marche : réglages, outils,
#                services, UKI signée du slot, jetons TPM (passphrase), puis
#                démarrage d'essai de l'UKI ; l'entrée de M0 reste le repli
#                jusqu'à la confirmation ; root
#   status       slots, entrées, défaut, essai en cours, dernier résultat
#   uki          reconstruit l'UKI du slot en marche (ligne de commande,
#                initramfs) en rago-<slot>.next.efi, essayée au redémarrage ; root
#   apply        écrit le slot INACTIF puis arme son essai ; root. Source :
#                  --image FICHIER   archive tar signée d'une racine (M13)
#                  --clone           copie du slot en marche (--run COMMANDE
#                                    lancée ensuite dans la copie, en chroot)
#   switch       démarre l'autre slot une fois (essai sans écriture) ; root
#   rollback     l'autre slot redevient le défaut (dernier bon) ; root
#   confirm      le démarrage en cours devient le défaut (fait seul, par
#                rago-update-confirm.service, après un essai réussi) ; root
#   verify       vérifie tout (fichiers, services, signatures, entrées, PCR 11,
#                jetons TPM) ; code 0 = bon, 1 = échec, 3 = redémarrage attendu
#   install-files  (interne) écrit réglages, outils et services seulement
#   trial-failed, sleep-hook   (internes : services systemd)
#
# Options :
#   --image FICHIER       (apply) archive de la racine (.tar, .tar.zst…)
#   --signature FICHIER   (apply) signature de l'archive (défaut : FICHIER.sig) ;
#                         vérifiée avec les clés publiques de RAGO_AB_KEYS
#   --clone               (apply) copie du slot en marche
#   --run COMMANDE        (apply --clone) lancée dans le nouveau slot (chroot)
#   --bind DIR            (apply) dossier de l'hôte monté au même endroit
#                         dans le chroot (répétable ; ex. le dépôt Rago)
#   --passphrase-file F   passphrase de secours lue dans F (mode 600)
#   --no-trial            (setup, apply) prépare sans armer l'essai
#   --auto                (confirm) seulement si un essai est en cours
#   --esp DIR             ESP (défaut : RAGO_ESP de /etc/rago/kernel.conf)
#   --root DIR            racine cible (tests) : écrit les fichiers dedans
#   --dry-run             affiche les actions sans rien faire
#   --quiet               moins de messages
#   -h, --help
#
# Réglages : /etc/rago/update.conf (écrit par setup). Variables d'environnement
# (tests) : RAGO_SYSFS (défaut /sys), RAGO_KERNEL_CONF, RAGO_M3_TOOL,
# RAGO_MOK_DIR (défaut /etc/rago/secureboot).
#
# Aucun contournement : Secure Boot reste actif, les clés sont celles du
# propriétaire (MOK de M0), rien n'est caché.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
libdir=""
for d in "$here/lib" /usr/lib/rago; do
	if [ -f "$d/rago_uki_lib.sh" ] && [ -f "$d/rago_host_lib.sh" ] && [ -f "$d/rago_crypt_lib.sh" ]; then libdir=$d; break; fi
done
[ -n "$libdir" ] || { echo "ERREUR : rago_uki_lib.sh / rago_host_lib.sh / rago_crypt_lib.sh introuvables" >&2; exit 1; }
# shellcheck source-path=SCRIPTDIR source=lib/rago_host_lib.sh
. "$libdir/rago_host_lib.sh"
# shellcheck source-path=SCRIPTDIR source=lib/rago_crypt_lib.sh
. "$libdir/rago_crypt_lib.sh"
# shellcheck source-path=SCRIPTDIR source=lib/rago_uki_lib.sh
. "$libdir/rago_uki_lib.sh"

src_of() { # src_of <chemin dans le dépôt> <chemin installé>
	if [ -f "$here/$1" ]; then echo "$here/$1"; else echo "$2"; fi
}
SRC_CONFIRM=$(src_of systemd/rago-update-confirm.service /usr/lib/systemd/system/rago-update-confirm.service)
SRC_FAILED=$(src_of systemd/rago-update-trial-failed.service /usr/lib/systemd/system/rago-update-trial-failed.service)
SRC_GEN=$(src_of systemd/system-generators/rago-update-generator /usr/lib/systemd/system-generators/rago-update-generator)
SRC_SLEEP=$(src_of systemd/system-sleep/rago-update /usr/lib/systemd/system-sleep/rago-update)
M3_TOOL=${RAGO_M3_TOOL:-$(src_of setup_secure_encryption.sh /usr/lib/rago/setup_secure_encryption.sh)}

# Chemins sur la machine cible (sans la racine).
P_CONF=/etc/rago/update.conf
P_ENC=/etc/rago/encryption.conf
P_KCONF=${RAGO_KERNEL_CONF:-/etc/rago/kernel.conf}
P_STATE=/var/lib/rago/update
P_LIBDIR=/usr/lib/rago
P_BIN=/usr/bin/rago-update
P_CONFIRM=/usr/lib/systemd/system/rago-update-confirm.service
P_FAILED=/usr/lib/systemd/system/rago-update-trial-failed.service
P_GEN=/usr/lib/systemd/system-generators/rago-update-generator
P_SLEEP=/usr/lib/systemd/system-sleep/rago-update
P_DRACUT=/etc/dracut.conf.d/91-rago-uki.conf
P_RUN=/run/rago/update
SDB_GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
# Noyau et initramfs de l'entrée unique de M0 (build_rago_kernel.sh).
M0_KERNEL=vmlinuz-linux-rago
M0_INITRD=initramfs-linux-rago.img

SYS=${RAGO_SYSFS:-/sys}
EFIVARS="$SYS/firmware/efi/efivars"

root=/
dry_run=0
cmd=""
args=()
o_image="" o_sig="" o_clone=0 o_run="" o_binds=() o_passfile="" o_trial=1 o_auto=0 o_esp="" o_quiet=0

log()  { [ "$o_quiet" = 1 ] || printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n "3,/^set -euo/p" "$0" | sed -e "\$d" -e "s/^# \{0,1\}//"; }
val() { [ $# -ge 2 ] || die "$1 attend une valeur"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--image) val "$@"; o_image=$2; shift 2 ;;
	--signature) val "$@"; o_sig=$2; shift 2 ;;
	--clone) o_clone=1; shift ;;
	--run) val "$@"; o_run=$2; shift 2 ;;
	--bind) val "$@"; o_binds+=("$2"); shift 2 ;;
	--passphrase-file) val "$@"; o_passfile=$2; shift 2 ;;
	--no-trial) o_trial=0; shift ;;
	--auto) o_auto=1; shift ;;
	--esp) val "$@"; o_esp=$2; shift 2 ;;
	--root) val "$@"; root=$2; shift 2 ;;
	--dry-run) dry_run=1; shift ;;
	--quiet) o_quiet=1; shift ;;
	-h | --help) usage; exit 0 ;;
	check | setup | status | uki | apply | switch | rollback | confirm | verify | install-files | trial-failed | sleep-hook)
		[ -z "$cmd" ] || die "une seule commande à la fois ($cmd, $1)"
		cmd=$1; shift ;;
	*)
		# sleep-hook reçoit ses deux arguments de systemd-sleep.
		if [ "$cmd" = sleep-hook ]; then args+=("$1"); shift; else die "option ou commande inconnue : $1 (--help)"; fi ;;
	esac
done
[ -n "$cmd" ] || { usage; exit 2; }
root=${root%/}
[ -z "$root" ] || [ -d "$root" ] || die "--root : dossier introuvable : $root"
R=$root
# Avec --root (tests), l'état d'exécution reste dans la racine donnée.
[ -z "$R" ] || P_RUN="$R$P_RUN"

# --- utilitaires --------------------------------------------------------------------
run() {
	if [ "$dry_run" = 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}
need_root() {
	[ "$dry_run" = 1 ] && return 0
	[ -n "$R" ] && return 0
	[ "$(id -u)" -eq 0 ] || die "« $1 » doit être lancé en root (sudo)"
}
have() { command -v "$1" >/dev/null 2>&1; }
is_ours() { grep -qs "$RAGO_AB_MARKER" "$1"; }

# Écrit l'entrée standard dans <chemin> (atomique, mode donné).
put_file() { # put_file <chemin cible sans racine> <mode>
	local dst="$R$1" tmp
	if [ "$dry_run" = 1 ]; then
		cat > /dev/null
		printf '[dry-run] écrire %s (%s)\n' "$dst" "$2"
		return 0
	fi
	mkdir -p "$(dirname "$dst")"
	tmp=$(mktemp "$dst.rago.XXXXXX")
	if ! cat > "$tmp"; then rm -f "$tmp"; die "écriture impossible : $dst"; fi
	chmod "$2" "$tmp"
	mv -f "$tmp" "$dst"
}

# Écrit un fichier sur l'ESP (FAT : pas de droits) : copie puis renommage.
esp_put() { # esp_put <fichier source> <chemin relatif à l'ESP>
	local dst="$ESP/$2"
	if [ "$dry_run" = 1 ]; then printf '[dry-run] copier %s -> %s\n' "$1" "$dst"; return 0; fi
	mkdir -p "$(dirname "$dst")"
	cp "$1" "$dst.rago-tmp" || { rm -f "$dst.rago-tmp"; die "écriture impossible sur l'ESP : $dst (pleine ?)"; }
	sync -f "$dst.rago-tmp" 2>/dev/null || sync
	mv -f "$dst.rago-tmp" "$dst"
	sync -f "$dst" 2>/dev/null || true
}

# Passphrase : jamais dans les arguments, jamais dans un journal.
PASS=""
PASSFILE=""
read_pass_file() {
	local f=$1 mode
	[ -r "$f" ] || die "passphrase : fichier illisible : $f"
	mode=$(stat -c %a "$f")
	[ $((8#$mode & 8#077)) -eq 0 ] || die "passphrase : $f est lisible par d'autres comptes (mode $mode) : chmod 600 $f"
	PASS=$(cat "$f"; printf x)
	PASS=${PASS%x}
	PASS=${PASS%$'\n'}
	PASS=${PASS%$'\r'}
}
have_tty() { { true < /dev/tty && true > /dev/tty; } 2>/dev/null; }
# Passphrase de secours : fichier, sinon clavier ; code 1 si aucune n'est
# disponible (service, pas de terminal) : l'appelant se replie.
get_pass() {
	[ -n "$PASS" ] && return 0
	if [ -n "$o_passfile" ]; then
		read_pass_file "$o_passfile"
	elif have_tty; then
		printf 'Passphrase de secours du disque : ' > /dev/tty
		IFS= read -r -s PASS < /dev/tty || PASS=""
		printf '\n' > /dev/tty
	else
		return 1
	fi
	[ -n "$PASS" ] || return 1
	return 0
}
# Fichier temporaire (mémoire, mode 600) pour passer la passphrase à M3.
pass_to_file() {
	[ -n "$PASSFILE" ] && return 0
	mkdir -p "$P_RUN"
	chmod 0700 "$P_RUN"
	PASSFILE=$(mktemp "$P_RUN/pass.XXXXXX")
	chmod 0600 "$PASSFILE"
	printf '%s' "$PASS" > "$PASSFILE"
}

CLEANUP=()
cleanup() {
	local i
	for ((i = ${#CLEANUP[@]} - 1; i >= 0; i--)); do eval "${CLEANUP[$i]}" 2>/dev/null || true; done
	if [ -n "$PASSFILE" ]; then rm -f "$PASSFILE"; fi
}
trap cleanup EXIT

# --- réglages -----------------------------------------------------------------------
# update.conf ; ESP ; volumes de M3.
load_settings() {
	local c="$R$P_CONF"
	MODE=$(rago_conf_get "$c" RAGO_AB_MODE uki)
	PCR11=$(rago_conf_get "$c" RAGO_AB_PCR11 1)
	TRIAL_TIMEOUT=$(rago_conf_get "$c" RAGO_AB_TRIAL_TIMEOUT 900)
	KEYS_DIR=$(rago_conf_get "$c" RAGO_AB_KEYS /etc/rago/update-keys)
	KEEP=$(rago_conf_get "$c" RAGO_AB_KEEP "/etc/rago /etc/machine-id /etc/hostname /etc/vconsole.conf /etc/locale.conf /etc/localtime /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/subuid /etc/subgid /etc/fstab /etc/NetworkManager/system-connections /etc/ssh /var/lib/bluetooth /var/lib/rago/encryption")
	AB_CMDLINE=$(rago_conf_get "$c" RAGO_AB_CMDLINE_EXTRA "rd.shell=0 rd.emergency=reboot")
	KERNEL_PICK=$(rago_conf_get "$c" RAGO_AB_KERNEL auto)
	case "$MODE" in uki | entry) ;; *) die "RAGO_AB_MODE invalide dans $P_CONF : uki ou entry" ;; esac
	case "$PCR11" in 0 | 1) ;; *) die "RAGO_AB_PCR11 invalide : 0 ou 1" ;; esac
	case "$TRIAL_TIMEOUT" in '' | *[!0-9]*) die "RAGO_AB_TRIAL_TIMEOUT invalide (secondes)" ;; esac
	if [ -n "$o_esp" ]; then ESP=${o_esp%/}; else ESP="$R$(rago_conf_get "$R$P_KCONF" RAGO_ESP /boot)"; ESP=${ESP%/}; fi
	SLOT=$(rago_conf_get "$R$P_ENC" RAGO_ENC_SLOT "")
	ROOT_A_UUID=$(rago_conf_get "$R$P_ENC" RAGO_ENC_ROOT_A_UUID "")
	ROOT_B_UUID=$(rago_conf_get "$R$P_ENC" RAGO_ENC_ROOT_B_UUID "")
	SWAP_UUID=$(rago_conf_get "$R$P_ENC" RAGO_ENC_SWAP_UUID "")
	MOK_DIR=${RAGO_MOK_DIR:-$R/etc/rago/secureboot}
	return 0
}

state_file() { echo "$1$P_STATE/state"; } # state_file <racine>
state_get() { rago_conf_get "$(state_file "${2-$R}")" "$1" ""; } # state_get <clé> [racine]
state_set() { # state_set <clé> <valeur> [racine]
	local f
	f=$(state_file "${3-$R}")
	[ "$dry_run" = 1 ] && return 0
	mkdir -p "$(dirname "$f")"
	[ -f "$f" ] || printf '# Rago OS — état des mises à jour A/B (module M4). Marqueur : %s\n' "$RAGO_AB_MARKER" > "$f"
	rago_conf_set "$f" "$1" "$2"
}
hist_add() { # hist_add <message> [racine]
	local f="${2-$R}$P_STATE/history.log"
	[ "$dry_run" = 1 ] && return 0
	mkdir -p "$(dirname "$f")"
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$f"
}
# Message vers le journal (et la console du démarrage, pour les services).
journal() { if have systemd-cat; then printf '%s\n' "$1" | systemd-cat -t rago-update -p "${2:-info}" 2>/dev/null || true; fi; }

# --- variables EFI de systemd-boot ----------------------------------------------------
efivar() { rago_efivar_string "$EFIVARS/$1-$SDB_GUID"; }
entry_selected() { efivar LoaderEntrySelected; }
entry_oneshot() { efivar LoaderEntryOneShot; }
entry_default() {
	local d
	d=$(efivar LoaderEntryDefault)
	[ -n "$d" ] || d=$(rago_loader_conf_get "$ESP/loader/loader.conf" default)
	echo "$d"
}
secure_boot_state() {
	local f="$EFIVARS/SecureBoot-$EFI_GLOBAL" b
	[ -r "$f" ] || { echo "?"; return 0; }
	b=$(od -An -t u1 -j 4 -N 1 "$f" 2>/dev/null | tr -d ' ' || true)
	if [ "$b" = 1 ]; then echo on; else echo off; fi
}
# L'UKI démarrée a-t-elle été mesurée par systemd-stub (PCR 11) ?
stub_measured() { [ "$(efivar StubPcrKernelImage)" = 11 ] || [ -e "$EFIVARS/StubPcrKernelImage-$SDB_GUID" ]; }

bootctl_run() { # bootctl_run <arguments…>
	if [ "$dry_run" = 1 ]; then printf '[dry-run] bootctl %s\n' "$*"; return 0; fi
	have bootctl || { warn "bootctl absent : variable EFI pas écrite ($*)"; return 1; }
	bootctl --esp-path="$ESP" "$@" >/dev/null 2>&1 || bootctl "$@" >/dev/null 2>&1
}

# Le défaut : variable EFI (bootctl set-default) ET loader.conf (si la NVRAM est
# effacée, systemd-boot relit loader.conf).
set_default() {
	local id=$1
	log "défaut de systemd-boot : $id"
	bootctl_run set-default "$id" || warn "bootctl set-default $id a échoué : loader.conf seulement"
	loader_conf_set default "$id"
}
loader_conf_set() { # loader_conf_set <clé> <valeur>
	local f="$ESP/loader/loader.conf" tmp
	[ "$(rago_loader_conf_get "$f" "$1")" = "$2" ] && return 0
	if [ "$dry_run" = 1 ]; then printf '[dry-run] loader.conf : %s %s\n' "$1" "$2"; return 0; fi
	mkdir -p "$ESP/loader"
	tmp=$(mktemp)
	rago_loader_conf_set "$f" "$1" "$2" > "$tmp"
	esp_put "$tmp" loader/loader.conf
	rm -f "$tmp"
}
arm_trial() { # arm_trial <entrée>
	log "démarrage d'essai au prochain redémarrage : $1 (une seule fois)"
	bootctl_run set-oneshot "$1" || { warn "bootctl set-oneshot a échoué : l'essai n'est pas armé"; return 1; }
}

# --- disques et slot en marche --------------------------------------------------------
dev_by_uuid() {
	local u=$1 d
	[ -n "$u" ] || return 1
	if [ -e "/dev/disk/by-uuid/$u" ]; then readlink -f "/dev/disk/by-uuid/$u"; return 0; fi
	d=$(blkid -U "$u" 2>/dev/null || true)
	[ -n "$d" ] || return 1
	echo "$d"
}
mounted_root_luks_uuid() {
	local src name s
	src=$(findmnt -no SOURCE / 2>/dev/null || true)
	case "$src" in /dev/mapper/* | /dev/dm-*) ;; *) return 1 ;; esac
	name=$(basename "$(readlink -f "$src")")
	for s in "$SYS/class/block/$name"/slaves/*; do
		[ -e "$s" ] || continue
		cryptsetup luksUUID "/dev/${s##*/}" 2>/dev/null && return 0
	done
	return 1
}
# Slot en marche : celui dont le volume LUKS porte « / » (avec --root : réglage).
current_slot() {
	local u
	if [ -n "$R" ]; then
		[ -n "$SLOT" ] && { echo "$SLOT"; return 0; }
		return 1
	fi
	u=$(mounted_root_luks_uuid) || return 1
	if [ -n "$ROOT_A_UUID" ] && [ "$u" = "$ROOT_A_UUID" ]; then echo a; return 0; fi
	if [ -n "$ROOT_B_UUID" ] && [ "$u" = "$ROOT_B_UUID" ]; then echo b; return 0; fi
	return 1
}
other_slot() { if [ "$1" = a ]; then echo b; else echo a; fi; }
slot_uuid() { if [ "$1" = a ]; then echo "$ROOT_A_UUID"; else echo "$ROOT_B_UUID"; fi; }
upper() { printf '%s' "$1" | tr 'ab' 'AB'; }

# Entrée de démarrage d'un slot sur l'ESP (UKI, sinon repli), vide si aucune.
slot_entry() { # slot_entry <slot> [next]
	local id
	for id in "$(rago_ab_entry_id "$1" uki "${2:-}")" "$(rago_ab_entry_id "$1" conf "${2:-}")"; do
		[ -f "$ESP/$(rago_ab_entry_path "$id")" ] && { echo "$id"; return 0; }
	done
	return 1
}
# Entrée par laquelle ce système a démarré (renommée par confirm : .next retiré).
booted_entry() {
	local s
	s=$(cat "$P_RUN/booted-entry" 2>/dev/null || true)
	[ -n "$s" ] || s=$(entry_selected)
	echo "$s"
}

# --- noyau, initramfs et UKI d'un slot ------------------------------------------------
# Noyau d'une racine : « <version> <chemin> » (le noyau Rago de M0 d'abord,
# sinon le plus récent qui a son image).
pick_kernel() { # pick_kernel <racine>
	local rt=$1 d k best="" bestk="" img
	for d in "$rt"/usr/lib/modules/*; do
		[ -d "$d" ] || continue
		k=${d##*/}
		img=""
		if [ -f "$d/vmlinuz" ]; then img="$d/vmlinuz"; elif [ -f "$rt/boot/vmlinuz-$k" ]; then img="$rt/boot/vmlinuz-$k"; fi
		[ -n "$img" ] || continue
		if [ "$KERNEL_PICK" != auto ]; then
			[ "$k" = "$KERNEL_PICK" ] && { echo "$k $img"; return 0; }
			continue
		fi
		if [ "$(cat "$d/pkgbase" 2>/dev/null)" = linux-rago ]; then echo "$k $img"; return 0; fi
		if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best" "$k" | sort -V | tail -1)" = "$k" ]; then best=$k; bestk=$img; fi
	done
	[ -n "$best" ] || return 1
	echo "$best $bestk"
}

initramfs_gen() { # initramfs_gen <racine> -> dracut | mkinitcpio | none
	if [ -x "$1/usr/bin/mkinitcpio" ] && [ -f "$1/etc/mkinitcpio.conf" ]; then echo mkinitcpio; return 0; fi
	if [ -x "$1/usr/bin/dracut" ] || [ -x "$1/usr/sbin/dracut" ]; then echo dracut; return 0; fi
	echo none
}

# Lance une commande dans une racine : directement si c'est « / », sinon en
# chroot (avec /dev, /proc, /sys, /run et les --bind).
in_root() { # in_root <racine> <commande…>
	local rt=$1
	shift
	if [ "$rt" = / ]; then "$@"; else chroot "$rt" "$@"; fi
}
CHROOT_MOUNTS=""
chroot_on() { # chroot_on <racine>
	local rt=$1 m b
	for m in dev proc sys run; do
		mkdir -p "$rt/$m"
		mount --rbind "/$m" "$rt/$m" && mount --make-rslave "$rt/$m"
		CHROOT_MOUNTS="$rt/$m $CHROOT_MOUNTS"
	done
	for b in "${o_binds[@]}"; do
		[ -d "$b" ] || die "--bind : dossier introuvable : $b"
		mkdir -p "$rt$b"
		mount --rbind "$b" "$rt$b" && mount --make-rslave "$rt$b"
		CHROOT_MOUNTS="$rt$b $CHROOT_MOUNTS"
	done
}
chroot_off() {
	local m
	for m in $CHROOT_MOUNTS; do umount -R "$m" 2>/dev/null || umount -R -l "$m" 2>/dev/null || true; done
	CHROOT_MOUNTS=""
}

# Initramfs fraîche pour <version> dans <racine>, écrite dans <sortie> (chemin
# vu depuis la racine : sous /run, partagé avec l'hôte).
make_initramfs() { # make_initramfs <racine> <version> <sortie>
	local rt=$1 k=$2 out=$3 gen
	gen=$(initramfs_gen "$rt")
	case "$gen" in
	dracut) in_root "$rt" dracut --force --kver "$k" "$out" ;;
	mkinitcpio) in_root "$rt" mkinitcpio -k "$k" -g "$out" ;;
	*) warn "aucun générateur d'initramfs dans $rt (dracut ou mkinitcpio)"; return 1 ;;
	esac
}
initramfs_listing() { # initramfs_listing <racine> <image> -> liste des fichiers
	local rt=$1 img=$2
	case "$(initramfs_gen "$rt")" in
	dracut) in_root "$rt" lsinitrd "$img" 2>/dev/null ;;
	mkinitcpio) in_root "$rt" lsinitcpio "$img" 2>/dev/null ;;
	*) return 1 ;;
	esac
}

# Ligne de commande d'un slot (son kernel.conf, comme M0) + options de M4.
slot_cmdline() { # slot_cmdline <racine>
	local kc="$1/${P_KCONF#/}" base
	base=$(rago_conf_get "$kc" RAGO_CMDLINE "")
	[ -n "$base" ] || die "RAGO_CMDLINE vide dans $kc (noyau M0 / chiffrement M3 pas installés ?)"
	rago_uki_cmdline "$base" "$(rago_conf_get "$kc" RAGO_MITIGATIONS auto)" \
		"$(rago_conf_get "$kc" RAGO_CMDLINE_EXTRA "")" "$AB_CMDLINE" ||
		die "RAGO_MITIGATIONS invalide dans $kc (auto|off)"
}

mok_ready() { [ -f "$MOK_DIR/MOK.key" ] && [ -f "$MOK_DIR/MOK.crt" ]; }
signed_by_mok() { have sbverify && [ -f "$MOK_DIR/MOK.crt" ] && sbverify --cert "$MOK_DIR/MOK.crt" "$1" >/dev/null 2>&1; }
stub_path() { # stub_path <racine>
	local s
	for s in "$1/usr/lib/systemd/boot/efi/linuxx64.efi.stub" /usr/lib/systemd/boot/efi/linuxx64.efi.stub; do
		[ -f "$s" ] && { echo "$s"; return 0; }
	done
	return 1
}
# Une UKI est-elle possible ici ? Sinon, la raison est affichée (repli).
uki_possible() { # uki_possible <racine>
	have ukify || { echo "ukify absent (paquet systemd-ukify)"; return 1; }
	stub_path "$1" >/dev/null || { echo "systemd-stub absent (linuxx64.efi.stub)"; return 1; }
	mok_ready || { echo "clé MOK absente ($MOK_DIR) : build_rago_kernel.sh mok-gen"; return 1; }
	if ! have sbsign || ! have sbverify; then echo "sbsign / sbverify absents (sbsigntools)"; return 1; fi
	return 0
}

# Construit l'entrée de démarrage d'un slot depuis sa racine. UKI signée MOK si
# possible, sinon repli (noyau signé + initramfs + entrée type 1). Résultat :
#   BUILT_KIND (uki|conf), BUILT_UKI (fichier temporaire, UKI) ou BUILT_DIR
#   (dossier temporaire : vmlinuz, initramfs.img, cmdline, version), BUILT_PRED
#   (PCR 11 prédit ou -).
#   build_entry <slot> <racine> <version de l'image> <source>
build_entry() {
	local slot=$1 rt=$2 ver=$3 srcname=$4 kk k kimg tmpd rel phases="" why cl osr pred rc
	kk=$(pick_kernel "$rt") || die "aucun noyau dans $rt/usr/lib/modules (avec son image vmlinuz)"
	k=${kk%% *}
	kimg=${kk#* }
	mkdir -p "$P_RUN"
	tmpd=$(mktemp -d "$P_RUN/build.XXXXXX")
	CLEANUP+=("rm -rf '$tmpd'")
	rel=${tmpd#/}
	log "slot $(upper "$slot") : noyau $k, initramfs fraîche ($(initramfs_gen "$rt"))"
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] initramfs %s pour %s, puis UKI signée MOK\n' "$rt" "$k"
		BUILT_KIND=uki BUILT_UKI="$tmpd/uki.efi" BUILT_PRED=-
		return 0
	fi
	make_initramfs "$rt" "$k" "/$rel/initramfs.img" > "$tmpd/initramfs.log" 2>&1 ||
		{ tail -15 "$tmpd/initramfs.log" >&2; die "initramfs du slot $(upper "$slot") : échec (voir ci-dessus)"; }
	[ -s "$tmpd/initramfs.img" ] || die "initramfs du slot $(upper "$slot") vide"
	if initramfs_listing "$rt" "/$rel/initramfs.img" > "$tmpd/initramfs.list" && [ -s "$tmpd/initramfs.list" ]; then
		if rago_initramfs_has_pcrphase "$tmpd/initramfs.list"; then
			phases=$RAGO_PCR11_UNLOCK_PHASE
		else
			warn "initramfs sans systemd-pcrphase : pas de barrière « enter-initrd » (module dracut systemd-pcrextend absent ?) ; PCR 11 prédit sans elle"
		fi
	else
		warn "contenu de l'initramfs illisible (lsinitrd / lsinitcpio) : PCR 11 ne peut pas être prédit"
		phases="?"
	fi
	if [ "$(initramfs_gen "$rt")" = mkinitcpio ] && ls "$rt"/boot/*-ucode.img "$ESP"/*-ucode.img >/dev/null 2>&1 &&
		! grep -Eq '^[[:space:]]*HOOKS=.*[( ]microcode[ )]' "$rt/etc/mkinitcpio.conf" 2>/dev/null; then
		warn "mkinitcpio sans le hook « microcode » : l'UKI démarre sans le microcode CPU de /boot (ajoute microcode à HOOKS)"
	fi
	cl=$(slot_cmdline "$rt")
	printf '%s' "$cl" > "$tmpd/cmdline"
	osr="$rt/etc/os-release"
	[ -f "$osr" ] || osr="$rt/usr/lib/os-release"
	rago_uki_os_release "$osr" "$slot" "$ver" > "$tmpd/os-release"
	why=""
	if [ "$MODE" = uki ] && why=$(uki_possible "$rt"); then
		# Le noyau embarqué ne doit PAS être signé par la clé MOK : un noyau nu signé
		# démarrerait avec une initramfs quelconque, qui pourrait rejouer les mesures
		# de PCR 11. ukify signerait un noyau non signé : --no-sign-kernel ; un noyau
		# déjà signé par la clé MOK (M0 avant M4) perd sa signature ici.
		cp "$kimg" "$tmpd/vmlinuz"
		if signed_by_mok "$tmpd/vmlinuz"; then
			have sbattach || die "noyau signé par la clé MOK et sbattach absent : impossible de l'embarquer sans signature"
			sbattach --remove "$tmpd/vmlinuz" >/dev/null 2>&1 || die "sbattach --remove a échoué sur $kimg"
		fi
		{
			printf 'slot=%s\n' "$slot"
			printf 'kernel=%s\n' "$k"
			printf 'version=%s\n' "$ver"
			printf 'source=%s\n' "$srcname"
			printf 'built=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			[ "$phases" = "?" ] || printf 'pcr11-phases=%s\n' "$phases"
		} > "$tmpd/rago-meta"
		log "slot $(upper "$slot") : UKI signée avec la clé MOK (ukify, systemd-stub de la racine du slot)"
		if ! ukify build --linux="$tmpd/vmlinuz" --initrd="$tmpd/initramfs.img" --cmdline=@"$tmpd/cmdline" \
			--os-release=@"$tmpd/os-release" --uname="$k" --section=.rago:@"$tmpd/rago-meta" \
			--stub="$(stub_path "$rt")" --signtool=sbsign --no-sign-kernel \
			--secureboot-private-key="$MOK_DIR/MOK.key" --secureboot-certificate="$MOK_DIR/MOK.crt" \
			--output="$tmpd/uki.efi" > "$tmpd/ukify.log" 2>&1; then
			tail -10 "$tmpd/ukify.log" >&2
			die "ukify a échoué pour le slot $(upper "$slot")"
		fi
		check_uki "$tmpd/uki.efi" "$slot" || die "UKI du slot $(upper "$slot") refusée (voir ci-dessus)"
		rc=0
		pred=$(rago_uki_unlock_pcr11 "$tmpd/uki.efi") || rc=$?
		if [ "$rc" != 0 ]; then
			pred=-
			case "$rc" in
			2) warn "UKI à sections non prises en charge : PCR 11 non prédit, TPM en PCR 0+7 (dégradé, signalé)" ;;
			*) warn "PCR 11 non prédit pour cette UKI : TPM en PCR 0+7 (dégradé, signalé)" ;;
			esac
		fi
		BUILT_KIND=uki BUILT_UKI="$tmpd/uki.efi" BUILT_PRED=$pred
		return 0
	fi
	[ "$MODE" = entry ] || warn "UKI impossible : $why"
	warn "slot $(upper "$slot") : entrée de REPLI (noyau signé + initramfs non signée, TPM PCR 0+7) : tant qu'elle existe, le trou « evil maid » de M3 reste ouvert pour toute la machine"
	journal "rago-update : slot $slot sans UKI ($why) : entrée de repli, TPM PCR 0+7" warning
	cp "$kimg" "$tmpd/vmlinuz"
	if mok_ready && have sbsign && ! signed_by_mok "$tmpd/vmlinuz"; then
		if sbsign --key "$MOK_DIR/MOK.key" --cert "$MOK_DIR/MOK.crt" --output "$tmpd/vmlinuz.signed" "$tmpd/vmlinuz" >/dev/null 2>&1; then
			mv "$tmpd/vmlinuz.signed" "$tmpd/vmlinuz"
		else
			warn "signature du noyau impossible : il ne démarrera pas avec Secure Boot"
		fi
	elif ! mok_ready; then
		warn "clé MOK absente : noyau NON signé (démarre seulement Secure Boot inactif)"
	fi
	printf '%s' "$k" > "$tmpd/version"
	BUILT_KIND=conf BUILT_DIR=$tmpd BUILT_PRED=-
}

# Contrôles d'une UKI avant de la poser sur l'ESP.
check_uki() { # check_uki <fichier> <slot>
	local f=$1 slot=$2 s bad=0 secs
	secs=$(rago_pe_sections "$f") || { warn "$f n'est pas un fichier PE"; return 1; }
	for s in .linux .initrd .cmdline .osrel .rago; do
		grep -q "^$s " <<<"$secs" || { warn "UKI sans section $s"; bad=1; }
	done
	[ "$(rago_uki_meta "$f" slot)" = "$slot" ] || { warn "UKI : métadonnée slot=$(rago_uki_meta "$f" slot), attendu $slot"; bad=1; }
	if signed_by_mok "$f"; then :; else warn "UKI pas signée par la clé MOK ($MOK_DIR/MOK.crt)"; bad=1; fi
	rago_uki_section "$f" .linux > "$f.linux" 2>/dev/null
	if signed_by_mok "$f.linux"; then warn "le noyau embarqué est signé par la clé MOK (rejeu de PCR 11 possible) : refusé"; bad=1; fi
	rm -f "$f.linux"
	grep -q "root=/dev/mapper/$RAGO_MAP_ROOT" <<<"$(rago_uki_section "$f" .cmdline)" ||
		warn "ligne de commande de l'UKI sans root=/dev/mapper/$RAGO_MAP_ROOT (chiffrement M3 pas installé ?)"
	[ "$bad" = 0 ]
}

# Pose l'entrée construite sur l'ESP sous l'identifiant donné.
install_entry() { # install_entry <id>
	local id=$1 dir f title
	case "$BUILT_KIND" in
	uki)
		log "ESP : $(rago_ab_entry_path "$id")"
		esp_put "$BUILT_UKI" "$(rago_ab_entry_path "$id")"
		;;
	conf)
		dir=$(rago_ab_conf_dir "$id")
		log "ESP : $dir/ et $(rago_ab_entry_path "$id") (repli sans UKI)"
		esp_put "$BUILT_DIR/vmlinuz" "$dir/vmlinuz"
		esp_put "$BUILT_DIR/initramfs.img" "$dir/initramfs.img"
		title="Rago OS — slot $(upper "$(rago_ab_entry_slot "$id")") (repli sans UKI)"
		f=$(mktemp)
		{
			printf 'title   %s\n' "$title"
			printf 'version %s\n' "$(cat "$BUILT_DIR/version")"
			printf 'linux   /%s/vmlinuz\n' "$dir"
			printf 'initrd  /%s/initramfs.img\n' "$dir"
			printf 'options %s\n' "$(cat "$BUILT_DIR/cmdline")"
		} > "$f"
		esp_put "$f" "$(rago_ab_entry_path "$id")"
		rm -f "$f"
		;;
	esac
}

remove_entry() { # remove_entry <id> : fichier(s) d'une entrée sur l'ESP
	local id=$1 p dir
	p="$ESP/$(rago_ab_entry_path "$id")"
	[ -e "$p" ] && run rm -f "$p"
	if [ "$(rago_ab_entry_kind "$id")" = conf ] && dir=$(rago_ab_conf_dir "$id" 2>/dev/null); then
		[ -d "$ESP/$dir" ] && run rm -rf "${ESP:?}/$dir"
	fi
	return 0
}

# Entrée à l'essai renommée sous son nom définitif (rago-a.next.efi -> rago-a.efi).
promote_entry() { # promote_entry <id à l'essai> -> nom définitif
	local id=$1 fin src dst dir fdir tmp
	fin=$(rago_ab_entry_final "$id")
	[ "$fin" = "$id" ] && { echo "$id"; return 0; }
	src="$ESP/$(rago_ab_entry_path "$id")"
	dst="$ESP/$(rago_ab_entry_path "$fin")"
	[ -e "$src" ] || { echo "$fin"; return 0; }
	if [ "$dry_run" = 1 ]; then printf '[dry-run] %s -> %s\n' "$src" "$dst" >&2; echo "$fin"; return 0; fi
	if [ "$(rago_ab_entry_kind "$id")" = conf ]; then
		dir=$(rago_ab_conf_dir "$id")
		fdir=$(rago_ab_conf_dir "$fin")
		rm -rf "${ESP:?}/$fdir"
		mv "$ESP/$dir" "$ESP/$fdir"
		tmp=$(mktemp)
		sed "s|/$dir/|/$fdir/|g" "$src" > "$tmp"
		esp_put "$tmp" "$(rago_ab_entry_path "$fin")"
		rm -f "$tmp" "$src"
	else
		mv -f "$src" "$dst"
	fi
	sync
	echo "$fin"
}

# --- TPM (M3) -------------------------------------------------------------------------
m3() { # m3 <arguments…> : outil de chiffrement de M3
	[ -x "$M3_TOOL" ] || [ -f "$M3_TOOL" ] || { warn "outil de chiffrement M3 introuvable ($M3_TOOL)"; return 1; }
	bash "$M3_TOOL" ${R:+--root "$R"} ${o_esp:+--esp "$o_esp"} "$@"
}
# Met les jetons TPM en accord avec les entrées de l'ESP (M3 reseal). M3 ne
# demande la passphrase que s'il manque un jeton. Sans passphrase (service, pas
# de terminal) : on le dit, elle sera demandée au démarrage (repli).
tpm_resync() {
	local missing
	if [ "$dry_run" = 1 ]; then echo "[dry-run] rago-encryption reseal (un jeton par entrée de démarrage)"; return 0; fi
	if [ -n "$PASS" ] || [ -n "$o_passfile" ]; then
		get_pass || true
		pass_to_file
		if m3 --passphrase-file "$PASSFILE" reseal; then return 0; fi
		missing="le re-scellement a échoué (voir ci-dessus)"
	else
		if m3 reseal; then return 0; fi
		missing="le re-scellement a échoué, ou pas de passphrase de secours ici (ni --passphrase-file ni terminal)"
	fi
	warn "TPM pas re-scellé : $missing."
	warn "Rien n'est bloqué : au démarrage par la nouvelle entrée, la passphrase de secours sera demandée ;"
	warn "ensuite : sudo rago-encryption reseal"
	journal "rago-update : TPM pas re-scellé ($missing) : passphrase de secours au prochain démarrage" warning
	return 1
}

# --- installation des fichiers ----------------------------------------------------------
write_conf() { # write_conf <mode> <pcr11>
	local c="$R$P_CONF"
	if [ -f "$c" ]; then
		[ "$dry_run" = 1 ] && return 0
		rago_conf_set "$c" RAGO_AB_MODE "$1"
		rago_conf_set "$c" RAGO_AB_PCR11 "$2"
		return 0
	fi
	{
		printf '# Rago OS — mises à jour A/B + UKI signée (module M4). Marqueur : %s\n' "$RAGO_AB_MARKER"
		printf '# Relu par rago-update (manage_atomic_updates.sh) et rago-encryption (M3).\n'
		printf '#   RAGO_AB_MODE           uki = chaque slot démarre par son UKI signée (MOK) ;\n'
		printf '#                          entry = repli : noyau signé + initramfs du slot\n'
		printf '#   RAGO_AB_PCR11          1 = TPM lié aussi à PCR 11 (mesure de l'"'"'UKI, prédite) ;\n'
		printf '#                          0 = PCR 0+7 seulement (dégradé)\n'
		printf '#   RAGO_AB_TRIAL_TIMEOUT  secondes pour atteindre multi-user.target pendant un essai\n'
		printf '#   RAGO_AB_KEYS           clés publiques (.pem) acceptées pour les images (apply --image)\n'
		printf '#   RAGO_AB_KEEP           fichiers du slot en marche gardés dans une nouvelle image\n'
		printf '#   RAGO_AB_CMDLINE_EXTRA  ajouté à la ligne de commande des UKI : pas de shell\n'
		printf '#                          dans l'"'"'initramfs (après un déverrouillage TPM, il\n'
		printf '#                          donnerait la clé), redémarrage en cas d'"'"'échec\n'
		printf '#   RAGO_AB_KERNEL         noyau embarqué (auto = linux-rago, sinon le plus récent)\n'
		printf 'RAGO_AB_MODE="%s"\n' "$1"
		printf 'RAGO_AB_PCR11="%s"\n' "$2"
		printf 'RAGO_AB_TRIAL_TIMEOUT="%s"\n' "$TRIAL_TIMEOUT"
		printf 'RAGO_AB_KEYS="%s"\n' "$KEYS_DIR"
		printf 'RAGO_AB_KEEP="%s"\n' "$KEEP"
		printf 'RAGO_AB_CMDLINE_EXTRA="%s"\n' "$AB_CMDLINE"
		printf 'RAGO_AB_KERNEL="%s"\n' "$KERNEL_PICK"
	} | put_file "$P_CONF" 0644
}

dracut_module_name() { # module dracut qui met systemd-pcrphase dans l'initramfs
	local d
	for d in "$R"/usr/lib/dracut/modules.d/[0-9][0-9]systemd-pcrextend "$R"/usr/lib/dracut/modules.d/[0-9][0-9]systemd-pcrphase; do
		[ -d "$d" ] && { d=${d##*/}; echo "${d#[0-9][0-9]}"; return 0; }
	done
	return 1
}

install_files() { # réglages, outils, services (aussi dans une racine --root)
	local f m
	log "outils : $P_BIN, $P_LIBDIR/, services rago-update-*, générateur, crochet d'hibernation"
	for f in rago_uki_lib.sh rago_crypt_lib.sh rago_host_lib.sh; do
		put_file "$P_LIBDIR/$f" 0644 < "$libdir/$f"
	done
	put_file "$P_LIBDIR/manage_atomic_updates.sh" 0755 < "$here/$(basename "${BASH_SOURCE[0]}")"
	{
		printf '#!/bin/sh\n'
		printf '# Rago OS — mises à jour A/B + UKI signée (module M4). Marqueur : %s\n' "$RAGO_AB_MARKER"
		printf 'exec %s/manage_atomic_updates.sh "$@"\n' "$P_LIBDIR"
	} | put_file "$P_BIN" 0755
	put_file "$P_CONFIRM" 0644 < "$SRC_CONFIRM"
	put_file "$P_FAILED" 0644 < "$SRC_FAILED"
	put_file "$P_GEN" 0755 < "$SRC_GEN"
	put_file "$P_SLEEP" 0755 < "$SRC_SLEEP"
	if [ "$(initramfs_gen "${R:-/}")" = dracut ]; then
		if m=$(dracut_module_name); then
			{
				printf '# Rago OS — UKI mesurée (module M4). Marqueur : %s\n' "$RAGO_AB_MARKER"
				printf '# systemd-pcrphase dans l'"'"'initramfs : PCR 11 reçoit « enter-initrd » avant\n'
				printf '# l'"'"'ouverture des volumes, puis « leave-initrd » : passé l'"'"'initramfs, la clé du\n'
				printf '# TPM ne se descelle plus.\n'
				printf 'add_dracutmodules+=" %s "\n' "$m"
			} | put_file "$P_DRACUT" 0644
		else
			warn "module dracut systemd-pcrextend absent : pas de barrière PCR 11 dans l'initramfs (prédiction sans elle)"
		fi
	fi
	if [ "$dry_run" = 1 ]; then
		echo "[dry-run] activer rago-update-confirm.service"
	elif [ -z "$R" ] && have systemctl && [ -d /run/systemd/system ]; then
		systemctl daemon-reload 2>/dev/null || true
		systemctl enable rago-update-confirm.service >/dev/null 2>&1 || warn "rago-update-confirm.service non activé"
	else
		mkdir -p "$R/etc/systemd/system/multi-user.target.wants"
		ln -sf "$P_CONFIRM" "$R/etc/systemd/system/multi-user.target.wants/rago-update-confirm.service"
	fi
}

step_install_files() {
	need_root install-files
	load_settings
	write_conf "$MODE" "$PCR11"
	install_files
}

# =====================================================================================
# check
# =====================================================================================
n_ok=0 n_fail=0 n_warn=0 n_boot=0 n_skip=0
ok()   { n_ok=$((n_ok + 1));     printf '  [ OK ]        %s\n' "$*"; }
ko()   { n_fail=$((n_fail + 1)); printf '  [ ÉCHEC ]     %s\n' "$*"; }
att()  { n_warn=$((n_warn + 1)); printf '  [ ATTENTION ] %s\n' "$*"; }
boot() { n_boot=$((n_boot + 1)); printf '  [ REDÉMARRER ] %s\n' "$*"; }
skip() { n_skip=$((n_skip + 1)); printf '  [ IGNORÉ ]    %s\n' "$*"; }
bilan() {
	printf 'Bilan : %d OK, %d échec(s), %d attention, %d redémarrage(s) en attente, %d ignoré(s)\n' \
		"$n_ok" "$n_fail" "$n_warn" "$n_boot" "$n_skip"
	if [ "$n_fail" -gt 0 ]; then return 1; fi
	if [ "$n_boot" -gt 0 ]; then return 3; fi
	return 0
}

check_sdboot() { # systemd-boot sur l'ESP, signé par la clé MOK ?
	local f found=0
	for f in "$ESP/EFI/systemd/systemd-bootx64.efi" "$ESP/EFI/rago/grubx64.efi" "$ESP/EFI/BOOT/BOOTX64.EFI"; do
		[ -f "$f" ] || continue
		case "$f" in */BOOTX64.EFI) grep -qa 'systemd-boot' "$f" || continue ;; esac
		found=1
		if signed_by_mok "$f"; then ok "systemd-boot signé par la clé MOK : ${f#"$ESP"/}"
		elif [ -f "$MOK_DIR/MOK.crt" ] && have sbverify; then ko "systemd-boot NON signé par la clé MOK : ${f#"$ESP"/} (sudo kernel/build_rago_kernel.sh bootloader)"
		else skip "signature de ${f#"$ESP"/} non vérifiable (sbverify ou MOK.crt absent)"; fi
	done
	[ "$found" = 1 ] || ko "systemd-boot absent de l'ESP ($ESP) : bootctl install, puis build_rago_kernel.sh bootloader"
}

step_check() {
	load_settings
	n_ok=0 n_fail=0 n_warn=0 n_boot=0 n_skip=0
	local cs why v
	printf 'Rago OS — prérequis des mises à jour A/B + UKI (M4)\n'
	if [ -f "$R$P_ENC" ]; then ok "chiffrement M3 : $P_ENC (slot ${SLOT:-?})"; else ko "chiffrement M3 pas installé ($P_ENC absent) : setup_secure_encryption.sh install"; fi
	if [ -n "$ROOT_A_UUID" ]; then ok "slot A : UUID=$ROOT_A_UUID"; else ko "slot A non configuré (M3)"; fi
	if [ -n "$ROOT_B_UUID" ]; then ok "slot B : UUID=$ROOT_B_UUID"; else ko "slot B non configuré (M3 install --other-slot-device)"; fi
	if [ -n "$SWAP_UUID" ]; then ok "swap chiffré : UUID=$SWAP_UUID"; else att "pas de swap chiffré (hibernation du Fast OS Switch impossible)"; fi
	if cs=$(current_slot); then ok "slot en marche : $(upper "$cs")"; else ko "la racine « / » n'est pas un slot Rago (A ou B)"; fi
	if [ -d "$ESP/loader" ]; then ok "ESP : $ESP"; else ko "ESP introuvable ou sans systemd-boot : $ESP (RAGO_ESP dans $P_KCONF, --esp)"; fi
	[ -d "$ESP/loader" ] && check_sdboot
	case "$(secure_boot_state)" in
	on) ok "Secure Boot actif" ;;
	off) att "Secure Boot inactif : l'UKI n'est pas vérifiée au démarrage (l'activer, clé MOK inscrite)" ;;
	*) skip "état Secure Boot illisible" ;;
	esac
	if mok_ready; then ok "clé MOK de M0 : $MOK_DIR"; else ko "clé MOK absente ($MOK_DIR) : sudo kernel/build_rago_kernel.sh mok-gen"; fi
	if why=$(uki_possible "${R:-/}"); then ok "UKI possible : ukify $(ukify --version 2>/dev/null | awk '{ print $2 }'), systemd-stub, sbsign"; else att "UKI impossible ($why) : repli sur une entrée noyau + initramfs, TPM PCR 0+7"; fi
	if have bootctl; then ok "bootctl"; else ko "bootctl absent (systemd-boot)"; fi
	v=$(systemd-cryptenroll --version 2>/dev/null | awk 'NR == 1 { print $2 }' || true)
	if [ -n "$v" ] && [ "$(printf '%s\n%s\n' 254 "$v" | sort -V | head -1)" = 254 ]; then ok "systemd-cryptenroll $v : PCR 11 lié à une valeur prédite"; else att "systemd-cryptenroll ${v:-absent} < 254 : TPM en PCR 0+7 seulement"; fi
	case "$(initramfs_gen "${R:-/}")" in
	dracut) if dracut_module_name >/dev/null; then ok "dracut : module $(dracut_module_name) (barrière PCR 11)"; else att "dracut sans module systemd-pcrextend : pas de barrière PCR 11 dans l'initramfs"; fi ;;
	mkinitcpio) ok "mkinitcpio (barrière PCR 11 selon le hook systemd)" ;;
	*) ko "aucun générateur d'initramfs (dracut ou mkinitcpio)" ;;
	esac
	if have rsync; then ok "rsync (apply --clone)"; else att "rsync absent : apply --clone copie avec cp -ax"; fi
	if [ -d "$R$KEYS_DIR" ] && ls "$R$KEYS_DIR"/*.pem >/dev/null 2>&1; then ok "clés de confiance des images : $KEYS_DIR"; else att "aucune clé de confiance des images ($KEYS_DIR/*.pem) : apply --image refusé (apply --clone possible)"; fi
	bilan
}

# =====================================================================================
# setup
# =====================================================================================
step_setup() {
	need_root setup
	load_settings
	local cs mode pcr11 id cur m0="" why
	[ -f "$R$P_ENC" ] || die "chiffrement M3 pas installé ($P_ENC) : setup_secure_encryption.sh install d'abord"
	cs=$(current_slot) || die "la racine « / » n'est pas un slot Rago (volumes de $P_ENC)"
	[ -d "$ESP/loader" ] || die "ESP sans systemd-boot : $ESP (bootctl install, puis build_rago_kernel.sh bootloader)"
	mode=$MODE
	if [ "$mode" = uki ] && ! why=$(uki_possible "${R:-/}"); then
		warn "UKI impossible : $why"
		warn "repli : chaque slot démarrera par une entrée noyau + initramfs (TPM PCR 0+7), comme M3"
		mode=entry
	fi
	pcr11=1
	[ "$mode" = uki ] || pcr11=0
	MODE=$mode
	write_conf "$mode" "$pcr11"
	PCR11=$pcr11
	install_files
	loader_conf_set editor no
	[ -f "$ESP/loader/entries/rago.conf" ] && m0=rago.conf
	cur=$(entry_default)
	if [ -z "$cur" ] && [ -n "$m0" ]; then set_default "$m0"; cur=$m0; fi
	if [ -n "$R" ]; then
		log "fichiers écrits dans $R (--root : pas d'UKI, pas de TPM)"
		return 0
	fi
	[ -f "$R$P_STATE/state" ] || state_set RAGO_UPD_LAST "M4 installé"
	build_entry "$cs" / "$(osr_version /)" "slot $(upper "$cs") (setup)"
	id=$(rago_ab_entry_id "$cs" "$BUILT_KIND")
	[ -n "$(slot_entry "$cs" || true)" ] && remove_entry "$(slot_entry "$cs")"
	install_entry "$id"
	tpm_resync || true
	if [ -z "$cur" ] || [ "$o_trial" = 0 ]; then
		# Pas d'entrée de repli connue : la nouvelle devient le défaut tout de suite.
		set_default "$id"
		state_set RAGO_UPD_LAST "setup : $id par défaut (sans essai)"
		hist_add "setup : $id par défaut (sans essai)"
		log "fait : $id est l'entrée par défaut"
		return 0
	fi
	state_set RAGO_UPD_TRIAL "$id"
	state_set RAGO_UPD_PENDING "$id"
	state_set RAGO_UPD_PENDING_FROM "$cur"
	arm_trial "$id" || true
	hist_add "setup : essai de $id (repli : $cur)"
	log "fait. Redémarre : $id est essayée une fois ; si multi-user.target est atteint,"
	log "elle devient le défaut (rago-update-confirm) ; sinon retour automatique sur $cur."
}

osr_version() { # version affichée d'une racine : IMAGE_VERSION, sinon VERSION_ID + date
	local f="$1/etc/os-release" v
	[ -f "$f" ] || f="$1/usr/lib/os-release"
	v=$(rago_conf_get "$f" IMAGE_VERSION "")
	[ -n "$v" ] || v="$(rago_conf_get "$f" ID rago)-$(rago_conf_get "$f" VERSION_ID "")-$(date -u +%Y%m%d)"
	echo "$v"
}

# =====================================================================================
# uki : nouvelle UKI du slot en marche, à l'essai (rago-<slot>.next.efi)
# =====================================================================================
step_uki() {
	need_root uki
	load_settings
	[ -n "$R" ] && die "uki ne marche pas avec --root"
	is_ours "$R$P_CONF" || die "M4 pas en place : sudo rago-update setup"
	local cs cur id old oldpred
	cs=$(current_slot) || die "la racine « / » n'est pas un slot Rago"
	cur=$(slot_entry "$cs") || die "le slot $(upper "$cs") n'a pas d'entrée de démarrage : sudo rago-update setup"
	build_entry "$cs" / "$(osr_version /)" "slot $(upper "$cs") (uki)"
	id=$(rago_ab_entry_id "$cs" "$BUILT_KIND" next)
	if [ "$BUILT_KIND" = uki ] && [ "$(rago_ab_entry_kind "$cur")" = uki ]; then
		old="$ESP/$(rago_ab_entry_path "$cur")"
		oldpred=$(rago_uki_unlock_pcr11 "$old" 2>/dev/null || true)
		if [ -n "$oldpred" ] && [ "$oldpred" = "$BUILT_PRED" ]; then
			log "UKI identique à $cur (mêmes mesures) : rien à faire"
			return 0
		fi
	fi
	remove_entry "$id"
	install_entry "$id"
	tpm_resync || true
	state_set RAGO_UPD_TRIAL "$id"
	state_set RAGO_UPD_PENDING "$id"
	state_set RAGO_UPD_PENDING_FROM "$cur"
	arm_trial "$id" || true
	hist_add "uki : essai de $id (repli : $cur)"
	log "fait. Au redémarrage, $id est essayée ; repli : $cur."
}

# =====================================================================================
# apply : écrit le slot inactif
# =====================================================================================
# Signature de l'image : une des clés publiques de confiance doit la valider.
verify_image_sig() { # verify_image_sig <image> <signature>
	local img=$1 sig=$2 k pub
	[ -f "$sig" ] || die "signature introuvable : $sig (--signature)"
	ls "$R$KEYS_DIR"/*.pem >/dev/null 2>&1 || die "aucune clé de confiance ($KEYS_DIR/*.pem) : image refusée"
	for k in "$R$KEYS_DIR"/*.pem; do
		pub=$k
		if grep -q 'BEGIN CERTIFICATE' "$k"; then
			pub=$(mktemp)
			CLEANUP+=("rm -f '$pub'")
			openssl x509 -in "$k" -pubkey -noout > "$pub" 2>/dev/null || continue
		fi
		if openssl dgst -sha256 -verify "$pub" -signature "$sig" "$img" >/dev/null 2>&1; then
			log "image signée par $(basename "$k")"
			return 0
		fi
	done
	die "signature de l'image invalide (aucune clé de $KEYS_DIR ne la valide) : refusée"
}

step_apply() {
	need_root apply
	load_settings
	[ -n "$R" ] && die "apply ne marche pas avec --root"
	is_ours "$R$P_CONF" || die "M4 pas en place : sudo rago-update setup"
	[ -n "$o_image" ] || [ "$o_clone" = 1 ] || die "apply : --image FICHIER ou --clone"
	[ -z "$o_image" ] || [ "$o_clone" = 0 ] || die "apply : --image OU --clone, pas les deux"
	[ -z "$o_run" ] || [ "$o_clone" = 1 ] || die "--run va avec --clone"
	local cs ts tu tdev def name mnt fstype ver srcname id p
	cs=$(current_slot) || die "la racine « / » n'est pas un slot Rago"
	ts=$(other_slot "$cs")
	tu=$(slot_uuid "$ts")
	[ -n "$tu" ] || die "slot $(upper "$ts") non configuré (M3 : --other-slot-device)"
	tdev=$(dev_by_uuid "$tu") || die "volume du slot $(upper "$ts") introuvable (UUID=$tu)"
	# Jamais le slot en marche, jamais le dernier bon connu.
	def=$(entry_default)
	if [ -n "$def" ] && [ "$(rago_ab_entry_slot "$def" 2>/dev/null)" = "$ts" ]; then
		die "le slot $(upper "$ts") est le défaut (dernier bon connu) et ce démarrage n'est pas confirmé : sudo rago-update confirm (ou rollback) d'abord"
	fi
	if [ -n "$o_image" ]; then
		[ -f "$o_image" ] || die "image introuvable : $o_image"
		# /home dans la racine : la nouvelle image ne l'aurait pas, et le prochain
		# apply effacerait le seul slot qui l'a encore. Refusé.
		if home_in_root && [ -n "$(ls -A /home 2>/dev/null)" ]; then
			die "apply --image : /home est dans la racine du slot en marche ; la nouvelle image ne l'aurait pas (données perdues au prochain apply). Utilise apply --clone, ou un /home séparé partagé par les deux slots."
		fi
		verify_image_sig "$o_image" "${o_sig:-$o_image.sig}"
		srcname="image $(basename "$o_image")"
	else
		srcname="copie du slot $(upper "$cs")"
	fi
	name="rago-update-$ts"
	[ ! -e "/dev/mapper/$name" ] || die "/dev/mapper/$name existe déjà (apply interrompu ?) : cryptsetup close $name"
	if [ -n "$(ls -A "$SYS/class/block/$(basename "$(readlink -f "$tdev")")/holders" 2>/dev/null)" ]; then
		die "le volume du slot $(upper "$ts") ($tdev) est déjà ouvert ou utilisé : rien n'est écrit"
	fi
	get_pass || die "passphrase de secours nécessaire pour ouvrir le slot $(upper "$ts") (--passphrase-file ou terminal)"
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] écrire le slot %s (%s) depuis : %s\n' "$(upper "$ts")" "$tdev" "$srcname"
		return 0
	fi
	# Les montages de la mise à jour restent dans un espace de montage privé : ils
	# ne fuient pas dans ceux des services (udevd, logind…), qui empêcheraient
	# ensuite de fermer le volume.
	if [ -z "${RAGO_UPDATE_PRIVATE_NS:-}" ]; then
		ls "$ESP/" >/dev/null 2>&1 || true # ESP en automontage : montée avant
		pass_to_file
		local re=(--passphrase-file "$PASSFILE")
		[ -n "$o_image" ] && re+=(--image "$o_image" --signature "${o_sig:-$o_image.sig}")
		[ "$o_clone" = 1 ] && re+=(--clone)
		[ -n "$o_run" ] && re+=(--run "$o_run")
		for p in "${o_binds[@]}"; do re+=(--bind "$p"); done
		[ "$o_trial" = 0 ] && re+=(--no-trial)
		[ -n "$o_esp" ] && re+=(--esp "$o_esp")
		[ "$o_quiet" = 1 ] && re+=(--quiet)
		RAGO_UPDATE_PRIVATE_NS=1 unshare --mount --propagation private bash "$0" "${re[@]}" apply
		return $?
	fi
	# 1. Le slot inactif n'est plus démarrable pendant qu'on l'écrit.
	for id in "$(rago_ab_entry_id "$ts" uki)" "$(rago_ab_entry_id "$ts" uki next)" "$(rago_ab_entry_id "$ts" conf)" "$(rago_ab_entry_id "$ts" conf next)"; do
		remove_entry "$id"
	done
	state_set RAGO_UPD_LAST "écriture du slot $(upper "$ts") en cours ($srcname)"
	hist_add "apply : écriture du slot $(upper "$ts") ($srcname)"
	# 2. Ouverture et système de fichiers neuf.
	log "slot $(upper "$ts") : ouverture de $tdev (passphrase de secours)"
	printf '%s\n' "$PASS" | cryptsetup open --disable-external-tokens "$tdev" "$name" ||
		die "ouverture du slot $(upper "$ts") refusée (passphrase ?)"
	CLEANUP+=("cryptsetup close '$name'")
	fstype=$(findmnt -no FSTYPE / 2>/dev/null || echo ext4)
	log "slot $(upper "$ts") : nouveau système de fichiers $fstype"
	case "$fstype" in
	ext4) mkfs.ext4 -q -F -L "rago-$ts-fs" "/dev/mapper/$name" ;;
	btrfs) mkfs.btrfs -q -f -L "rago-$ts-fs" "/dev/mapper/$name" ;;
	xfs) mkfs.xfs -q -f -L "rago-$ts-fs" "/dev/mapper/$name" ;;
	*) die "système de fichiers de la racine non pris en charge : $fstype (ext4, btrfs, xfs)" ;;
	esac
	mnt="$P_RUN/target"
	mkdir -p "$mnt"
	mount "/dev/mapper/$name" "$mnt"
	CLEANUP+=("umount -R '$mnt'")
	# 3. Contenu.
	if [ -n "$o_image" ]; then
		log "slot $(upper "$ts") : extraction de $(basename "$o_image")"
		tar -xpf "$o_image" -C "$mnt" --numeric-owner --xattrs --xattrs-include='*' --acls ||
			die "extraction de l'image impossible"
		keep_files "$mnt"
	else
		log "slot $(upper "$ts") : copie du slot $(upper "$cs") en marche"
		clone_root "$mnt"
	fi
	mkdir -p "$mnt/dev" "$mnt/proc" "$mnt/sys" "$mnt/run" "$mnt/tmp"
	chmod 1777 "$mnt/tmp"
	rm -rf "${mnt:?}$P_STATE"
	chroot_on "$mnt"
	CLEANUP+=("chroot_off")
	# 4. Réglages propres au slot : M3 (crypttab, initramfs, kernel.conf), M4.
	slot_config "$mnt" "$ts" "$cs"
	if [ -n "$o_run" ]; then
		log "slot $(upper "$ts") : $o_run (chroot)"
		RAGO_UPDATE_TARGET_SLOT=$ts chroot "$mnt" /bin/sh -c "$o_run" ||
			die "--run a échoué dans le slot $(upper "$ts") : slot laissé sans entrée de démarrage"
	fi
	ver=$(osr_version "$mnt")
	[ -n "$o_image" ] || ver="$ver-copie-$cs"
	# 5. Entrée de démarrage (UKI signée) construite depuis le slot lui-même.
	build_entry "$ts" "$mnt" "$ver" "$srcname"
	id=$(rago_ab_entry_id "$ts" "$BUILT_KIND")
	state_set RAGO_UPD_TRIAL "$id" "$mnt"
	state_set RAGO_UPD_LAST "écrit depuis le slot $(upper "$cs") ($srcname) ; en essai" "$mnt"
	hist_add "écrit depuis le slot $(upper "$cs") ($srcname)" "$mnt"
	chroot_off
	sync
	umount -R "$mnt"
	cryptsetup close "$name" || warn "fermeture de $name impossible (sera fermé au redémarrage)"
	install_entry "$id"
	# 6. TPM : jetons pour la nouvelle UKI (passphrase déjà donnée).
	tpm_resync || true
	if [ "$o_trial" = 0 ]; then
		state_set RAGO_UPD_LAST "slot $(upper "$ts") écrit ($srcname), pas d'essai armé (rago-update switch)"
		log "fait : slot $(upper "$ts") prêt ($id) ; essai : sudo rago-update switch"
		return 0
	fi
	state_set RAGO_UPD_PENDING "$id"
	state_set RAGO_UPD_PENDING_FROM "$(entry_default)"
	state_set RAGO_UPD_LAST "slot $(upper "$ts") écrit ($srcname) ; essai armé"
	arm_trial "$id" || true
	hist_add "apply : essai de $id armé"
	log "fait. Redémarre : le slot $(upper "$ts") ($id) est essayé une fois ; s'il n'atteint pas"
	log "multi-user.target en $TRIAL_TIMEOUT s, retour automatique sur le slot $(upper "$cs")."
}

# /home est-il dans la racine (pas un système de fichiers à part, partagé) ?
home_in_root() { [ "$(findmnt -no TARGET --target /home 2>/dev/null || echo /)" = / ]; }

# Copie du slot en marche (sans les montages, /proc, /sys, /dev, /run, /tmp).
# Un /home à part (autre système de fichiers) n'est pas copié : il est partagé.
clone_root() { # clone_root <cible>
	local t=$1 d k
	if have rsync; then
		rsync -aHAXx --numeric-ids --exclude=/dev/ --exclude=/proc/ --exclude=/sys/ --exclude=/run/ \
			--exclude=/tmp/ --exclude=/mnt/ --exclude=/media/ --exclude=/lost+found/ --exclude="$P_STATE/" \
			/ "$t/" || die "copie du slot en marche impossible (rsync)"
	else
		cp -ax / "$t" || die "copie du slot en marche impossible (cp)"
		rm -rf "${t:?}/proc/"* "${t:?}/sys/"* "${t:?}/dev/"* "${t:?}/run/"* "${t:?}/tmp/"* 2>/dev/null || true
	fi
	mkdir -p "$t/mnt" "$t/media"
	# Noyau rangé seulement dans /boot alors que /boot est un autre système de
	# fichiers (l'ESP, pas copiée) : son image suit ses modules dans le slot.
	for d in "$t"/usr/lib/modules/*; do
		[ -d "$d" ] || continue
		k=${d##*/}
		[ -f "$d/vmlinuz" ] || [ -f "$t/boot/vmlinuz-$k" ] || [ ! -f "/boot/vmlinuz-$k" ] || cp "/boot/vmlinuz-$k" "$d/vmlinuz"
	done
}

# Fichiers propres à la machine gardés d'une image à l'autre (RAGO_AB_KEEP).
keep_files() { # keep_files <cible>
	local t=$1 p
	for p in $KEEP; do
		[ -e "$p" ] || continue
		rm -rf "${t:?}$p"
		mkdir -p "$t$(dirname "$p")"
		cp -a "$p" "$t$p"
	done
}

# Réglages propres au slot dans sa racine : M3 (sa crypttab, son dracut,
# kernel.conf), M4 (outils, services). L'outil du slot lui-même d'abord (une
# image neuve apporte sa version), sinon celui du slot en marche (--root).
slot_config() { # slot_config <racine> <slot> <slot en marche>
	local t=$1 ts=$2 cs=$3 a=()
	a=(--slot "$ts" --root-uuid "$(slot_uuid "$ts")" --other-slot-uuid "$(slot_uuid "$cs")")
	[ -n "$SWAP_UUID" ] && a+=(--swap-uuid "$SWAP_UUID")
	log "slot $(upper "$ts") : crypttab et réglages du slot (M3)"
	if [ -f "$t$P_LIBDIR/setup_secure_encryption.sh" ]; then
		chroot "$t" bash "$P_LIBDIR/setup_secure_encryption.sh" --quiet --no-apply "${a[@]}" install > "$P_RUN/slot-config.log" 2>&1 ||
			{ tail -15 "$P_RUN/slot-config.log" >&2; die "réglages M3 du slot $(upper "$ts") : échec"; }
	else
		bash "$M3_TOOL" --quiet --root "$t" "${a[@]}" install > "$P_RUN/slot-config.log" 2>&1 ||
			{ tail -15 "$P_RUN/slot-config.log" >&2; die "réglages M3 du slot $(upper "$ts") : échec"; }
	fi
	grep -q "UUID=$(slot_uuid "$ts")" "$t/etc/crypttab" 2>/dev/null || die "crypttab du slot $(upper "$ts") n'ouvre pas son volume"
	log "slot $(upper "$ts") : outils et services de M4"
	if [ -f "$t$P_LIBDIR/manage_atomic_updates.sh" ]; then
		chroot "$t" bash "$P_LIBDIR/manage_atomic_updates.sh" --quiet install-files > "$P_RUN/slot-m4.log" 2>&1 ||
			{ tail -15 "$P_RUN/slot-m4.log" >&2; die "outils M4 du slot $(upper "$ts") : échec"; }
	else
		bash "$here/$(basename "${BASH_SOURCE[0]}")" --quiet --root "$t" install-files > "$P_RUN/slot-m4.log" 2>&1 ||
			{ tail -15 "$P_RUN/slot-m4.log" >&2; die "outils M4 du slot $(upper "$ts") : échec"; }
	fi
}

# =====================================================================================
# switch / rollback
# =====================================================================================
step_switch() {
	need_root switch
	load_settings
	is_ours "$R$P_CONF" || die "M4 pas en place : sudo rago-update setup"
	local cs ts id
	cs=$(current_slot) || die "la racine « / » n'est pas un slot Rago"
	ts=$(other_slot "$cs")
	id=$(slot_entry "$ts") || die "le slot $(upper "$ts") n'a pas d'entrée de démarrage (rago-update apply d'abord)"
	tpm_resync || true
	arm_trial "$id" || die "essai pas armé"
	state_set RAGO_UPD_LAST "démarrage unique du slot $(upper "$ts") demandé"
	hist_add "switch : démarrage unique de $id"
	log "au prochain redémarrage : slot $(upper "$ts") une fois ; pour le garder : sudo rago-update confirm (sur ce slot)"
}

step_rollback() {
	need_root rollback
	load_settings
	is_ours "$R$P_CONF" || die "M4 pas en place : sudo rago-update setup"
	local cs ts id
	cs=$(current_slot) || die "la racine « / » n'est pas un slot Rago"
	ts=$(other_slot "$cs")
	id=$(slot_entry "$ts") || die "le slot $(upper "$ts") n'a pas d'entrée de démarrage : pas de retour possible"
	tpm_resync || true
	set_default "$id"
	bootctl_run set-oneshot "" || true
	state_set RAGO_UPD_TRIAL ""
	state_set RAGO_UPD_PENDING ""
	state_set RAGO_UPD_LAST "retour arrière demandé : slot $(upper "$ts") par défaut"
	hist_add "rollback : $id par défaut"
	log "le slot $(upper "$ts") ($id) est le défaut : redémarre pour y revenir"
}

# =====================================================================================
# confirm (rago-update-confirm.service, après multi-user.target)
# =====================================================================================
# PCR 11 réel du démarrage en cours = une des valeurs prédites pour l'UKI
# démarrée ? Confirme le modèle de mesure sur cette machine.
pcr11_now() {
	local v
	v=$(cat "$SYS/class/tpm/tpm0/pcr-sha256/11" 2>/dev/null || true)
	if [ -z "$v" ] && have tpm2_pcrread; then
		v=$(tpm2_pcrread sha256:11 2>/dev/null | rago_pcrread_parse | awk '$1 == 11 { print $2 }')
	fi
	printf '%s' "$v" | tr 'A-F' 'a-f'
}
check_pcr11_model() { # check_pcr11_model <id> -> 0 confirmé, 1 différent, 2 impossible
	local id=$1 f now line
	[ "$(rago_ab_entry_kind "$id")" = uki ] || return 2
	f="$ESP/$(rago_ab_entry_path "$id")"
	[ -f "$f" ] || return 2
	stub_measured || return 2
	now=$(pcr11_now)
	[ -n "$now" ] || return 2
	line=$(rago_uki_pcr11_runtime_values "$f" 2>/dev/null | awk -v v="$now" '$2 == v { print $1; exit }')
	[ -n "$line" ] || return 1
	PCR11_PHASES=$line
	return 0
}

remove_m0_entry() {
	local f="$ESP/loader/entries/rago.conf" k i
	[ -f "$f" ] || return 0
	k=$(awk '$1 == "linux" { print $2 }' "$f")
	i=$(awk '$1 == "initrd" { print $2 }' "$f" | tail -1)
	log "entrée de M0 retirée (rago.conf) : le slot démarre par son UKI signée"
	run rm -f "$f"
	# Le noyau nu de M0 est signé par la clé MOK : laissé sur l'ESP, il démarrerait
	# avec une initramfs quelconque. On le retire.
	case "$k" in "/$M0_KERNEL") run rm -f "$ESP/$M0_KERNEL" ;; esac
	case "$i" in "/$M0_INITRD") run rm -f "$ESP/$M0_INITRD" ;; esac
}

step_confirm() {
	need_root confirm
	load_settings
	is_ours "$R$P_CONF" || { [ "$o_auto" = 1 ] && return 0; die "M4 pas en place"; }
	local sel trial pending from fin cs rc def
	sel=$(entry_selected)
	trial=$(state_get RAGO_UPD_TRIAL)
	pending=$(state_get RAGO_UPD_PENDING)
	cs=$(current_slot || true)
	mkdir -p "$P_RUN"
	if [ -n "$trial" ] && [ "$sel" = "$trial" ]; then
		# Essai réussi : multi-user.target atteint.
		fin=$(promote_entry "$trial")
		set_default "$fin"
		[ "$dry_run" = 1 ] || echo "$fin" > "$P_RUN/booted-entry"
		[ "$(rago_ab_entry_slot "$fin")" = "$cs" ] && remove_m0_entry
		state_set RAGO_UPD_TRIAL ""
		[ "$pending" = "$trial" ] && state_set RAGO_UPD_PENDING ""
		state_set RAGO_UPD_LAST "essai réussi : $fin est le défaut ($(date -u +%Y-%m-%d))"
		hist_add "confirm : $fin par défaut"
		journal "rago-update : démarrage d'essai réussi, $fin devient le défaut (dernier slot bon connu)"
		log "essai réussi : $fin est le défaut"
		rc=0
		check_pcr11_model "$fin" || rc=$?
		case "$rc" in
		0) log "PCR 11 mesuré = PCR 11 prédit pour $fin (phases $PCR11_PHASES)"; hist_add "PCR 11 confirmé ($fin)" ;;
		1)
			if [ "$PCR11" = 1 ]; then
				warn "PCR 11 mesuré ≠ prédit pour $fin : la prédiction ne marche pas sur cette machine"
				warn "dégradation : TPM en PCR 0+7 (RAGO_AB_PCR11=0) ; sudo rago-encryption reseal"
				[ "$dry_run" = 1 ] || rago_conf_set "$R$P_CONF" RAGO_AB_PCR11 0
				journal "rago-update : PCR 11 mesuré différent de la prédiction : TPM ramené à PCR 0+7 (reseal à faire)" warning
				hist_add "PCR 11 différent de la prédiction : RAGO_AB_PCR11=0"
			fi ;;
		*) : ;;
		esac
		# Jetons des anciennes entrées retirés (sans passphrase, seulement si chaque
		# entrée a déjà le sien).
		[ "$dry_run" = 1 ] || m3 --quiet prune-tpm || warn "jetons TPM : sudo rago-encryption reseal (voir ci-dessus)"
		return 0
	fi
	if [ -n "$pending" ] && [ "$sel" != "$pending" ]; then
		from=$(state_get RAGO_UPD_PENDING_FROM)
		def=$(entry_default)
		if [ "$(rago_ab_entry_slot "$pending" 2>/dev/null)" != "$cs" ] && [ "$def" = "$(rago_ab_entry_final "$pending")" ]; then
			state_set RAGO_UPD_PENDING ""
			state_set RAGO_UPD_LAST "le slot de $pending a été confirmé"
			hist_add "$pending confirmé de l'autre côté"
		else
			state_set RAGO_UPD_PENDING ""
			[ "$trial" = "$pending" ] && state_set RAGO_UPD_TRIAL ""
			state_set RAGO_UPD_LAST "ÉCHEC de l'essai de $pending : retour sur ${sel:-$from} ($(date -u +%Y-%m-%d))"
			hist_add "échec de l'essai de $pending : retour sur ${sel:-$from}"
			journal "rago-update : l'essai de $pending a échoué (multi-user.target non atteint) : retour automatique sur ${sel:-$from}" warning
			warn "l'essai de $pending a échoué : retour sur ${sel:-$from}"
			case "$pending" in
			*.next.*)
				# UKI reconstruite qui ne démarre pas : retirée, avec ses jetons TPM.
				remove_entry "$pending"
				[ "$dry_run" = 1 ] || m3 --quiet prune-tpm >/dev/null 2>&1 || true
				;;
			esac
		fi
		return 0
	fi
	[ "$o_auto" = 1 ] && return 0
	# Confirmation à la main : le démarrage en cours (slot choisi au menu, switch)
	# devient le défaut.
	[ -n "$sel" ] || die "entrée démarrée inconnue (LoaderEntrySelected absente)"
	rago_ab_entry_slot "$sel" >/dev/null || die "$sel n'est pas une entrée Rago"
	fin=$(promote_entry "$sel")
	set_default "$fin"
	state_set RAGO_UPD_LAST "$fin mis par défaut à la main"
	hist_add "confirm (à la main) : $fin par défaut"
	log "$fin est le défaut"
}

# =====================================================================================
# trial-failed (rago-update-trial-failed.service) / sleep-hook
# =====================================================================================
step_trial_failed() {
	local sel
	load_settings
	sel=$(entry_selected)
	# <3> : niveau « err », affiché sur la console même avec loglevel=4.
	printf '<3>RAGO-UPDATE : démarrage d'\''essai de %s en mode de secours : redémarrage, retour au slot précédent\n' "${sel:-?}" > /dev/kmsg 2>/dev/null || true
	journal "rago-update : démarrage d'essai de ${sel:-?} tombé en mode de secours : redémarrage sur le dernier slot bon connu" err
	hist_add "essai de ${sel:-?} en mode de secours : redémarrage" 2>/dev/null || true
	return 0
}

step_sleep_hook() {
	local phase=${args[0]:-} what=${args[1]:-} sel def one f="$P_RUN/sleep-oneshot"
	case "$what" in hibernate | hybrid-sleep | suspend-then-hibernate) ;; *) return 0 ;; esac
	load_settings
	case "$phase" in
	pre)
		sel=$(booted_entry)
		def=$(entry_default)
		one=$(entry_oneshot)
		[ -n "$sel" ] && rago_ab_entry_slot "$sel" >/dev/null 2>&1 || return 0
		[ "$sel" != "$def" ] || return 0
		# Un autre programme (M6 : bascule vers Windows) a déjà choisi : on n'y touche pas.
		[ -z "$one" ] || return 0
		bootctl_run set-oneshot "$sel" || return 0
		mkdir -p "$P_RUN"
		echo "$sel" > "$f"
		journal "rago-update : hibernation hors entrée par défaut : reprise sur $sel"
		;;
	post)
		[ -f "$f" ] || return 0
		# Reprise faite (systemd-boot a consommé l'entrée) ou hibernation ratée : on
		# retire ce qui reste.
		if [ "$(entry_oneshot)" = "$(cat "$f")" ]; then bootctl_run set-oneshot "" || true; fi
		rm -f "$f"
		;;
	esac
	return 0
}

# =====================================================================================
# status / verify
# =====================================================================================
entry_desc() { # entry_desc <id>
	local id=$1 f
	f="$ESP/$(rago_ab_entry_path "$id")"
	case "$(rago_ab_entry_kind "$id")" in
	uki) printf 'UKI %s, noyau %s, construite %s, source : %s' "$(rago_uki_meta "$f" version)" "$(rago_uki_meta "$f" kernel)" "$(rago_uki_meta "$f" built)" "$(rago_uki_meta "$f" source)" ;;
	conf) printf 'repli sans UKI, noyau %s' "$(awk '$1 == "version" { print $2 }' "$f")" ;;
	esac
}

step_status() {
	load_settings
	local cs s id sel def one
	printf 'Rago OS — mises à jour A/B (M4)\n'
	if ! is_ours "$R$P_CONF"; then printf '  M4 pas en place (sudo rago-update setup)\n'; return 0; fi
	printf '  mode : %s, TPM lié à PCR 11 : %s\n' "$MODE" "$([ "$PCR11" = 1 ] && echo oui || echo non)"
	cs=$(current_slot || echo "?")
	sel=$(booted_entry)
	def=$(entry_default)
	one=$(entry_oneshot)
	printf '  slot en marche : %s (démarré par %s)\n' "$(upper "$cs")" "${sel:-?}"
	printf '  défaut (dernier bon connu) : %s\n' "${def:-?}"
	printf '  essai au prochain démarrage : %s\n' "${one:-aucun}"
	for s in a b; do
		if id=$(slot_entry "$s"); then printf '  slot %s : %s — %s\n' "$(upper "$s")" "$id" "$(entry_desc "$id")"; else printf '  slot %s : pas d'"'"'entrée de démarrage\n' "$(upper "$s")"; fi
		if id=$(slot_entry "$s" next); then printf '  slot %s, à l'"'"'essai : %s — %s\n' "$(upper "$s")" "$id" "$(entry_desc "$id")"; fi
	done
	[ -f "$ESP/loader/entries/rago.conf" ] && printf '  entrée de M0 : rago.conf (repli pendant la mise en place)\n'
	printf '  dernier résultat : %s\n' "$(state_get RAGO_UPD_LAST)"
	[ -z "$(state_get RAGO_UPD_TRIAL)" ] || printf '  ce slot est à l'"'"'essai via : %s\n' "$(state_get RAGO_UPD_TRIAL)"
	[ -z "$(state_get RAGO_UPD_PENDING)" ] || printf '  essai armé par ce slot : %s\n' "$(state_get RAGO_UPD_PENDING)"
	if [ -f /run/rago/encryption-status ]; then printf '  TPM (rago-encryption tpm-check) : %s\n' "$(grep -v '^#' /run/rago/encryption-status | tr '\n' ' ')"; fi
	return 0
}

verify_entry() { # verify_entry <id>
	local id=$1 f pred rc cl
	f="$ESP/$(rago_ab_entry_path "$id")"
	case "$(rago_ab_entry_kind "$id")" in
	uki)
		if signed_by_mok "$f"; then ok "$id : signée par la clé MOK"; elif have sbverify && [ -f "$MOK_DIR/MOK.crt" ]; then ko "$id : PAS signée par la clé MOK (Secure Boot la refusera)"; else skip "$id : signature non vérifiable"; fi
		rago_uki_section "$f" .linux > "$P_RUN/v.linux" 2>/dev/null || true
		if signed_by_mok "$P_RUN/v.linux"; then ko "$id : noyau embarqué signé par la clé MOK (rejeu de PCR 11 possible)"; else ok "$id : noyau embarqué non signé à part (ne démarre que dans l'UKI)"; fi
		rm -f "$P_RUN/v.linux"
		if [ "$(rago_uki_meta "$f" slot)" = "$(rago_ab_entry_slot "$id")" ]; then ok "$id : slot $(rago_uki_meta "$f" slot)"; else ko "$id : métadonnée slot=$(rago_uki_meta "$f" slot) ne correspond pas au nom"; fi
		cl=$(rago_uki_section "$f" .cmdline 2>/dev/null || true)
		case " $cl " in *" root=/dev/mapper/$RAGO_MAP_ROOT "*) ok "$id : root=/dev/mapper/$RAGO_MAP_ROOT" ;; *) ko "$id : ligne de commande sans root=/dev/mapper/$RAGO_MAP_ROOT" ;; esac
		case " $cl " in *" rd.shell=0 "*) ok "$id : pas de shell dans l'initramfs (rd.shell=0)" ;; *) att "$id : shell de secours possible dans l'initramfs (après un déverrouillage TPM)" ;; esac
		rc=0
		pred=$(rago_uki_unlock_pcr11 "$f") || rc=$?
		if [ "$rc" = 0 ]; then
			ok "$id : PCR 11 prédit ($(rago_uki_meta "$f" pcr11-phases | sed 's/^$/sans barrière/'))"
		elif [ "$PCR11" = 1 ]; then
			att "$id : PCR 11 non prédictible (code $rc) : TPM en PCR 0+7 pour elle"
		fi
		;;
	conf) att "$id : entrée de repli (initramfs non signée, ligne de commande modifiable : TPM en PCR 0+7)" ;;
	esac
}

# Résultat de « rago-encryption tpm-check » sur une ligne : « a=ok b=… swap=… ».
tpm_report() { grep -E '^  [a-z]+=' "$P_RUN/tpm-check.log" | tr -d ' ' | paste -sd ' ' -; }

step_verify() {
	load_settings
	n_ok=0 n_fail=0 n_warn=0 n_boot=0 n_skip=0
	local cs s id sel def f n t rc trial
	printf 'Rago OS — vérification des mises à jour A/B + UKI (M4)\n'
	if is_ours "$R$P_CONF"; then ok "réglages : $P_CONF (mode $MODE, PCR 11 : $PCR11)"; else ko "réglages : $P_CONF absent (sudo rago-update setup)"; bilan; return; fi
	for f in "$P_BIN" "$P_LIBDIR/manage_atomic_updates.sh" "$P_LIBDIR/rago_uki_lib.sh" "$P_CONFIRM" "$P_FAILED" "$P_GEN" "$P_SLEEP"; do
		if [ -e "$R$f" ]; then ok "fichier : $f"; else ko "fichier absent : $f (sudo rago-update setup)"; fi
	done
	if [ -L "$R/etc/systemd/system/multi-user.target.wants/rago-update-confirm.service" ]; then ok "rago-update-confirm.service activé"; else ko "rago-update-confirm.service pas activé"; fi
	if [ "$(initramfs_gen "${R:-/}")" = dracut ]; then
		if is_ours "$R$P_DRACUT"; then ok "dracut : $P_DRACUT (barrière PCR 11)"; else att "dracut : $P_DRACUT absent (pas de barrière PCR 11)"; fi
	fi
	if [ ! -d "$ESP/loader" ]; then ko "ESP introuvable : $ESP"; bilan; return; fi
	check_sdboot
	if [ "$(rago_loader_conf_get "$ESP/loader/loader.conf" editor)" = no ]; then ok "loader.conf : editor no (ligne de commande non modifiable au menu)"; else ko "loader.conf : éditeur de systemd-boot actif (editor no)"; fi
	mkdir -p "$P_RUN"
	for s in a b; do
		if id=$(slot_entry "$s"); then verify_entry "$id"; else att "slot $(upper "$s") : pas d'entrée de démarrage (rago-update apply)"; fi
		if id=$(slot_entry "$s" next); then verify_entry "$id"; fi
	done
	n=0
	for f in "$ESP"/loader/entries/*.conf; do
		[ -f "$f" ] || continue
		t=${f##*/}
		rago_ab_entry_slot "$t" >/dev/null 2>&1 && continue
		att "entrée étrangère $t : elle démarre sans UKI vérifiée (à retirer si inutile)"
		n=$((n + 1))
	done
	if [ -f "$ESP/$M0_KERNEL" ] && signed_by_mok "$ESP/$M0_KERNEL"; then
		if [ -f "$ESP/loader/entries/rago.conf" ]; then att "noyau nu de M0 signé MOK sur l'ESP (repli de la mise en place ; retiré à la confirmation)"; else ko "noyau nu signé par la clé MOK sur l'ESP ($M0_KERNEL) : il démarrerait avec n'importe quelle initramfs : à retirer"; fi
	fi
	def=$(entry_default)
	trial=$(state_get RAGO_UPD_TRIAL)
	if [ "$def" = rago.conf ] && [ -f "$ESP/loader/entries/rago.conf" ]; then
		# Juste après setup, l'entrée de M0 reste le repli jusqu'à la confirmation ;
		# sans essai en cours, la première UKI n'a pas été confirmée.
		if [ -n "$trial" ]; then
			ok "défaut : rago.conf (entrée de M0), repli jusqu'à la confirmation de $trial"
		else
			att "défaut : rago.conf (entrée de M0, sans UKI : ligne de commande et initramfs non signées) : sudo rago-update setup"
		fi
	elif [ -n "$def" ] && rago_ab_entry_slot "$def" >/dev/null 2>&1 && [ -e "$ESP/$(rago_ab_entry_path "$def")" ]; then
		ok "défaut (dernier bon connu) : $def"
	else
		ko "défaut de systemd-boot : ${def:-aucun} (pas une entrée Rago présente)"
	fi
	if [ -z "$R" ]; then
		cs=$(current_slot || true)
		sel=$(booted_entry)
		if [ -n "$cs" ]; then ok "slot en marche : $(upper "$cs")"; else ko "la racine « / » n'est pas un slot Rago"; fi
		case "$(secure_boot_state)" in on) ok "Secure Boot actif" ;; off) att "Secure Boot inactif : UKI non vérifiée au démarrage" ;; *) skip "état Secure Boot illisible" ;; esac
		if [ -z "$sel" ]; then
			skip "entrée démarrée inconnue (pas de systemd-boot ?)"
		elif [ "$(rago_ab_entry_kind "$sel" 2>/dev/null)" = uki ]; then
			if stub_measured; then ok "démarré par l'UKI $sel, mesurée par systemd-stub (PCR 11)"; else ko "démarré par $sel sans mesure de systemd-stub"; fi
			rc=0
			check_pcr11_model "$sel" || rc=$?
			case "$rc" in
			0) ok "PCR 11 mesuré = prédit pour $sel (phases $PCR11_PHASES)" ;;
			1) ko "PCR 11 mesuré ≠ prédit pour $sel : la prédiction ne marche pas ici (RAGO_AB_PCR11=0, puis reseal)" ;;
			*) skip "PCR 11 : comparaison impossible (TPM illisible ?)" ;;
			esac
		else
			att "démarré par $sel (pas une UKI Rago)"
		fi
		if [ -n "$trial" ] && [ "$sel" = "$trial" ]; then
			boot "démarrage d'essai pas encore confirmé ($sel)"
		elif [ -n "$trial" ] && [ "$(entry_oneshot)" = "$trial" ]; then
			boot "essai de $trial armé : redémarre pour l'essayer"
		fi
		if [ -x "$M3_TOOL" ] || [ -f "$M3_TOOL" ]; then
			rc=0
			m3 --quiet tpm-check > "$P_RUN/tpm-check.log" 2>&1 || rc=$?
			case "$rc" in
			0) ok "TPM : un jeton à jour par entrée de démarrage ($(tpm_report))" ;;
			1) ko "TPM : jetons manquants ($(tpm_report)) : sudo rago-encryption reseal" ;;
			*) skip "TPM : pas testable ici ($(tpm_report))" ;;
			esac
		fi
	fi
	bilan
}

case "$cmd" in
check) step_check ;;
setup) step_setup ;;
status) step_status ;;
uki) step_uki ;;
apply) step_apply ;;
switch) step_switch ;;
rollback) step_rollback ;;
confirm) step_confirm ;;
verify) step_verify ;;
install-files) step_install_files ;;
trial-failed) step_trial_failed ;;
sleep-hook) step_sleep_hook ;;
esac
