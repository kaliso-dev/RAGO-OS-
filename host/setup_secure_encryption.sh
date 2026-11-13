#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — chiffrement du disque hôte : LUKS2 + TPM 2.0 (module M3).
#
# Volumes Rago (créés par l'installateur M12, deux slots pour M4) :
#   rago-a, rago-b   racine de chaque slot (LUKS2), ouverte au démarrage sous
#                    le nom « rago-root » (chaque slot a sa propre crypttab) ;
#   rago-swap        swap chiffré de l'hibernation du Fast OS Switch (M6),
#                    ouvert dans l'initramfs AVANT le resume.
# Chiffrement : LUKS2, aes-xts-plain64, clé 512 bits, sha512, argon2id.
# Déverrouillage : TPM 2.0 lié aux PCR 0+7 (systemd-cryptenroll) ET passphrase
# de secours OBLIGATOIRE (jamais le TPM seul). Le TPM refuse si le firmware
# (PCR 0) ou Secure Boot (PCR 7) change : la passphrase est alors demandée,
# puis « reseal » ré-enrôle le TPM.
#
# Avec M4 (host/manage_atomic_updates.sh, /etc/rago/update.conf présent) : le
# TPM suit les entrées de démarrage Rago de l'ESP. Chaque UKI signée (noyau +
# initramfs + ligne de commande d'un slot) a son jeton, lié aussi à PCR 11 :
# la valeur que systemd-stub y mesurera, PRÉDITE depuis le fichier de l'UKI
# (host/lib/rago_uki_lib.sh). Racine du slot A : jetons des UKI du slot A ;
# slot B : celles du slot B ; swap : toutes. enroll-tpm / reseal ajoutent les
# jetons qui manquent (passphrase) puis retirent ceux qui ne servent plus ;
# prune-tpm retire seulement (sans passphrase). Une entrée sans UKI, ou une UKI
# dont PCR 11 ne se prédit pas, garde un jeton PCR 0+7 (dégradation, signalée).
#
# Usage : setup_secure_encryption.sh [options] <commande>
#
# Commandes :
#   check        matériel et logiciels prêts ? (AES-NI / AVX2, TPM 2.0, PCR,
#                UEFI / Secure Boot, outils, initramfs) ; code 0 = prêt, 1 = non
#   format       chiffre un volume (EFFACE TOUT) et pose la passphrase de
#                secours ; root ; --device et --role obligatoires
#   open         ouvre un volume (TPM, sinon passphrase) ; root
#   close        ferme un volume ouvert (--name) ; root
#   enroll-tpm   enrôle le TPM (PCR 0+7) sur les volumes Rago ; la passphrase
#                de secours reste ; root
#   reseal       ré-enrôle le TPM après une mise à jour du firmware / Secure
#                Boot (même chose qu'enroll-tpm) ; root
#   prune-tpm    (M4) retire les jetons TPM qui ne correspondent plus à aucune
#                entrée de démarrage ; jamais la passphrase ; sans passphrase ;
#                seulement si chaque entrée a déjà son jeton ; root
#   install      /etc/crypttab (tpm2-device=auto), swap d'hibernation dans
#                fstab, initramfs (dracut ou mkinitcpio), ligne de commande du
#                noyau Rago (M0), service de contrôle du TPM ; root
#   verify       vérifie tout (volumes, clés, TPM, crypttab, initramfs, resume) ;
#   status       code 0 = bon, 1 = échec, 3 = seulement un redémarrage en attente
#   tpm-check    le TPM déverrouille-t-il encore les volumes ? (service
#                rago-tpm-check, après une mise à jour du firmware) ; root
#   cmdline      affiche les paramètres du noyau pour un slot (pour M4)
#   deps         installe cryptsetup, systemd-cryptsetup, tpm2-tools, dracut
#                si besoin (pacman ou apt) ; root
#
# Options :
#   --device DEV          volume visé (format, open, enroll-tpm, reseal)
#   --role root-a|root-b|swap   (format) rôle -> étiquette rago-a / rago-b / rago-swap
#   --name NOM            (open, close) nom du volume ouvert (défaut : son étiquette)
#   --passphrase-file F   passphrase de secours lue dans F (mode 600) au lieu du
#                         clavier ; un retour à la ligne final est ignoré
#   --yes                 (format) pas de question (installateur) ; les
#                         protections (monté, utilisé, partitions) restent
#   --virtual-only        refuse tout ce qui n'est pas un disque virtuel (loop,
#                         virtio, QEMU) : mode des tests (aussi RAGO_ENC_VIRTUAL_ONLY=1)
#   --pcrs LISTE          PCR liés au TPM (défaut 0+7)
#   --tpm2-device DEV     TPM (défaut auto ; ex. swtpm:path=/run/swtpm.sock en test)
#   --allow-zero-pcrs     enrôle même si le firmware n'a rien mesuré (DANGEREUX :
#                         le TPM déverrouillerait pour n'importe quel système)
#   --iter-time MS        coût argon2id en temps (défaut cryptsetup : 2000 ms)
#   --pbkdf-memory KIO    coût argon2id en mémoire (défaut cryptsetup : jusqu'à 1 Gio)
#   --no-discard          pas de TRIM sur les volumes (défaut : TRIM actif)
#   --no-mkswap           (format --role swap) ne crée pas le swap dedans
#   --slot a|b            (install, cmdline) slot de ce système
#   --root-device DEV | --root-uuid UUID       (install) volume LUKS de la racine
#   --swap-device DEV | --swap-uuid UUID       (install) volume LUKS du swap
#   --other-slot-device DEV | --other-slot-uuid UUID   (install) l'autre slot
#   --initramfs auto|dracut|mkinitcpio         (install) générateur d'initramfs
#   --esp DIR             (M4) ESP où sont les entrées de démarrage (défaut :
#                         RAGO_ESP de /etc/rago/kernel.conf, sinon /boot)
#   --root DIR            racine cible (tests) : écrit les fichiers dedans,
#                         n'applique rien (implique --no-apply)
#   --no-apply            écrit les fichiers sans régénérer l'initramfs
#   --dry-run             affiche les actions sans rien faire
#   -h, --help
#
# Variables d'environnement (tests) : RAGO_SYSFS (défaut /sys), RAGO_PROCFS
# (défaut /proc), RAGO_KERNEL_CONF (défaut /etc/rago/kernel.conf),
# RAGO_ENC_VIRTUAL_ONLY=1 (comme --virtual-only).
#
# Aucun contournement : le chiffrement protège les données du joueur ; Secure
# Boot reste actif, rien n'est caché.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
libdir=""
for d in "$here/lib" /usr/lib/rago; do
	if [ -f "$d/rago_crypt_lib.sh" ] && [ -f "$d/rago_host_lib.sh" ] && [ -f "$d/rago_uki_lib.sh" ]; then libdir=$d; break; fi
done
[ -n "$libdir" ] || { echo "ERREUR : rago_crypt_lib.sh / rago_host_lib.sh / rago_uki_lib.sh introuvables" >&2; exit 1; }
# shellcheck source-path=SCRIPTDIR source=lib/rago_host_lib.sh
. "$libdir/rago_host_lib.sh"
# shellcheck source-path=SCRIPTDIR source=lib/rago_crypt_lib.sh
. "$libdir/rago_crypt_lib.sh"
# shellcheck source-path=SCRIPTDIR source=lib/rago_uki_lib.sh
. "$libdir/rago_uki_lib.sh"

SRC_UNIT_SVC="$here/systemd/rago-tpm-check.service"
SRC_UNIT_TIMER="$here/systemd/rago-tpm-check.timer"
SRC_DRACUT_MOD="$here/dracut/91rago-crypttab/module-setup.sh"
[ -f "$SRC_UNIT_SVC" ] || SRC_UNIT_SVC=/usr/lib/systemd/system/rago-tpm-check.service
[ -f "$SRC_UNIT_TIMER" ] || SRC_UNIT_TIMER=/usr/lib/systemd/system/rago-tpm-check.timer
[ -f "$SRC_DRACUT_MOD" ] || SRC_DRACUT_MOD=/usr/lib/dracut/modules.d/91rago-crypttab/module-setup.sh

# Chemins sur la machine cible (sans la racine).
P_CONF=/etc/rago/encryption.conf
P_STATE=/var/lib/rago/encryption
P_KCONF=${RAGO_KERNEL_CONF:-/etc/rago/kernel.conf}
P_CRYPTTAB=/etc/crypttab
P_CRYPTTAB_INITRAMFS=/etc/crypttab.initramfs
P_FSTAB=/etc/fstab
P_DRACUT=/etc/dracut.conf.d/90-rago-encryption.conf
P_DRACUT_MOD=/usr/lib/dracut/modules.d/91rago-crypttab/module-setup.sh
P_MKINIT=/etc/mkinitcpio.conf.d/90-rago-encryption.conf
P_LIBDIR=/usr/lib/rago
P_BIN=/usr/bin/rago-encryption
P_UNIT_SVC=/usr/lib/systemd/system/rago-tpm-check.service
P_UNIT_TIMER=/usr/lib/systemd/system/rago-tpm-check.timer
P_RUNSTATUS=/run/rago/encryption-status
P_UPDCONF=/etc/rago/update.conf
SWAP_PRIO=10
EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c

SYS=${RAGO_SYSFS:-/sys}
PROC=${RAGO_PROCFS:-/proc}

root=/
apply=1
dry_run=0
cmd=""
o_device="" o_role="" o_name="" o_passfile="" o_yes=0 o_virtual=${RAGO_ENC_VIRTUAL_ONLY:-0}
o_pcrs="" o_tpm="" o_zero_pcrs=0 o_iter="" o_mem="" o_discard="" o_mkswap=1 o_slot=""
o_root_dev="" o_root_uuid="" o_swap_dev="" o_swap_uuid="" o_other_dev="" o_other_uuid=""
o_initramfs="" o_quiet=0 o_esp=""

log()  { [ "$o_quiet" = 1 ] || printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n "3,/^set -euo/p" "$0" | sed -e "\$d" -e "s/^# \{0,1\}//"; }
val() { [ $# -ge 2 ] || die "$1 attend une valeur"; }

while [ $# -gt 0 ]; do
	case "$1" in
	--device) val "$@"; o_device=$2; shift 2 ;;
	--role) val "$@"; o_role=$2; shift 2 ;;
	--name) val "$@"; o_name=$2; shift 2 ;;
	--passphrase-file) val "$@"; o_passfile=$2; shift 2 ;;
	--yes) o_yes=1; shift ;;
	--virtual-only) o_virtual=1; shift ;;
	--pcrs) val "$@"; o_pcrs=$2; shift 2 ;;
	--tpm2-device) val "$@"; o_tpm=$2; shift 2 ;;
	--allow-zero-pcrs) o_zero_pcrs=1; shift ;;
	--iter-time) val "$@"; o_iter=$2; shift 2 ;;
	--pbkdf-memory) val "$@"; o_mem=$2; shift 2 ;;
	--no-discard) o_discard=0; shift ;;
	--discard) o_discard=1; shift ;;
	--no-mkswap) o_mkswap=0; shift ;;
	--slot) val "$@"; o_slot=$2; shift 2 ;;
	--root-device) val "$@"; o_root_dev=$2; shift 2 ;;
	--root-uuid) val "$@"; o_root_uuid=$2; shift 2 ;;
	--swap-device) val "$@"; o_swap_dev=$2; shift 2 ;;
	--swap-uuid) val "$@"; o_swap_uuid=$2; shift 2 ;;
	--other-slot-device) val "$@"; o_other_dev=$2; shift 2 ;;
	--other-slot-uuid) val "$@"; o_other_uuid=$2; shift 2 ;;
	--initramfs) val "$@"; o_initramfs=$2; shift 2 ;;
	--esp) val "$@"; o_esp=$2; shift 2 ;;
	--quiet) o_quiet=1; shift ;;
	--root) val "$@"; root=$2; shift 2 ;;
	--no-apply) apply=0; shift ;;
	--dry-run) dry_run=1; shift ;;
	-h | --help) usage; exit 0 ;;
	check | format | open | close | enroll-tpm | reseal | prune-tpm | install | verify | status | tpm-check | cmdline | deps)
		[ -z "$cmd" ] || die "une seule commande à la fois ($cmd, $1)"
		cmd=$1; shift ;;
	*) die "option ou commande inconnue : $1 (--help)" ;;
	esac
done
[ -n "$cmd" ] || { usage; exit 2; }

root=${root%/}
[ -z "$root" ] || [ -d "$root" ] || die "--root : dossier introuvable : $root"
# Une racine de test ne touche jamais au système vivant.
[ -n "$root" ] && apply=0
R=$root

# --- utilitaires ------------------------------------------------------------------
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

state() { echo "$R$P_STATE/$1"; }

backup_path() { local p=${1#/}; echo "$(state backup)/${p//\//%}"; }

is_ours() { grep -qs "$RAGO_ENC_MARKER" "$1"; }

# Sauvegarde (une seule fois) d'un fichier système avant sa première modification.
# S'il n'existait pas, « <sauvegarde>.absent » le note (pour ne pas sauvegarder
# plus tard le fichier écrit par Rago comme s'il était d'origine).
backup_once() {
	local p=$1 b
	[ "$dry_run" = 1 ] && return 0
	b=$(backup_path "$p")
	{ [ -e "$b" ] || [ -e "$b.absent" ]; } && return 0
	mkdir -p "$(dirname "$b")"
	if [ -e "$R$p" ]; then cp -a "$R$p" "$b"; else : > "$b.absent"; fi
}

# Écrit l'entrée standard dans <chemin> (atomique, mode donné).
#   put_file <chemin cible sans racine> <mode>
put_file() {
	local p=$1 mode=$2 dst="$R$1" tmp
	if [ "$dry_run" = 1 ]; then
		cat > /dev/null
		printf '[dry-run] écrire %s (%s)\n' "$dst" "$mode"
		return 0
	fi
	mkdir -p "$(dirname "$dst")"
	tmp=$(mktemp "$dst.rago.XXXXXX")
	if ! cat > "$tmp"; then rm -f "$tmp"; die "écriture impossible : $dst"; fi
	chmod "$mode" "$tmp"
	mv -f "$tmp" "$dst"
}

# Passphrase : jamais dans les arguments d'une commande, jamais dans un journal.
PASS=""
read_pass_file() {
	local f=$1 mode
	[ -r "$f" ] || die "passphrase : fichier illisible : $f"
	mode=$(stat -c %a "$f")
	if [ $((8#$mode & 8#077)) -ne 0 ]; then
		die "passphrase : $f est lisible par d'autres comptes (mode $mode) : chmod 600 $f"
	fi
	PASS=$(cat "$f"; printf x)
	PASS=${PASS%x}
	PASS=${PASS%$'\n'}
	PASS=${PASS%$'\r'}
}

# Un terminal est-il vraiment là ? (/dev/tty existe toujours, mais ne s'ouvre
# pas sans terminal de contrôle : service, installateur, setsid.)
have_tty() { { true < /dev/tty && true > /dev/tty; } 2>/dev/null; }

tty_read_secret() { # tty_read_secret <invite> -> REPLY
	have_tty || die "pas de terminal pour taper la passphrase (--passphrase-file pour l'installateur)"
	printf '%s' "$1" > /dev/tty
	IFS= read -r -s REPLY < /dev/tty || REPLY=""
	printf '\n' > /dev/tty
}

check_pass_quality() {
	local rc=0
	rago_passphrase_check "$PASS" || rc=$?
	case "$rc" in
	0) ;;
	1) die "passphrase de secours trop courte : $RAGO_PASS_MIN caractères au moins" ;;
	2) die "passphrase de secours : caractère de contrôle (retour à la ligne, tabulation…) impossible à taper au démarrage" ;;
	3) warn "passphrase avec des caractères accentués : au démarrage le clavier peut être en QWERTY, préfère lettres sans accent, chiffres, - et _" ;;
	esac
}

# Nouvelle passphrase de secours (format).
get_new_pass() {
	if [ -n "$o_passfile" ]; then
		read_pass_file "$o_passfile"
	else
		local p1
		have_tty || die "pas de terminal pour taper la passphrase (--passphrase-file pour l'installateur)"
		printf 'Passphrase de secours : %d caractères au moins. Elle déverrouille le disque\n' "$RAGO_PASS_MIN" > /dev/tty
		printf 'quand le TPM refuse (mise à jour du BIOS, Secure Boot changé). Note-la en lieu sûr.\n' > /dev/tty
		tty_read_secret "Passphrase de secours : "
		p1=$REPLY
		tty_read_secret "La même, encore : "
		[ "$p1" = "$REPLY" ] || die "les deux passphrases sont différentes"
		PASS=$p1
	fi
	check_pass_quality
}

# Passphrase existante (open, enroll-tpm).
get_pass() {
	if [ -n "$o_passfile" ]; then
		read_pass_file "$o_passfile"
	else
		tty_read_secret "Passphrase de secours du disque : "
		PASS=$REPLY
	fi
	[ -n "$PASS" ] || die "passphrase vide"
}

# La passphrase ouvre-t-elle ce volume ? (rien n'est ouvert)
# --disable-external-tokens : sans lui, cryptsetup essaie d'abord le jeton TPM2
# et réussit sans même lire la passphrase (le test ne prouverait rien).
pass_opens() {
	printf '%s\n' "$PASS" | cryptsetup open --test-passphrase --disable-external-tokens --batch-mode "$1" >/dev/null 2>&1
}

# --- réglages -----------------------------------------------------------------------
load_settings() {
	local c="$R$P_CONF"
	SLOT=$(rago_conf_get "$c" RAGO_ENC_SLOT "")
	ROOT_A_UUID=$(rago_conf_get "$c" RAGO_ENC_ROOT_A_UUID "")
	ROOT_B_UUID=$(rago_conf_get "$c" RAGO_ENC_ROOT_B_UUID "")
	SWAP_UUID=$(rago_conf_get "$c" RAGO_ENC_SWAP_UUID "")
	PCRS=$(rago_conf_get "$c" RAGO_ENC_TPM_PCRS "0+7")
	DISCARD=$(rago_conf_get "$c" RAGO_ENC_DISCARD 1)
	INITRAMFS=$(rago_conf_get "$c" RAGO_ENC_INITRAMFS auto)
	[ -n "$o_pcrs" ] && PCRS=$o_pcrs
	[ -n "$o_discard" ] && DISCARD=$o_discard
	[ -n "$o_initramfs" ] && INITRAMFS=$o_initramfs
	[ -n "$o_slot" ] && SLOT=$o_slot
	PCRS=$(rago_pcrs_normalize "$PCRS") || die "--pcrs invalide : utiliser par ex. 0+7"
	case "$DISCARD" in 0 | 1) ;; *) die "RAGO_ENC_DISCARD invalide (0 ou 1)" ;; esac
	case "$INITRAMFS" in auto | dracut | mkinitcpio) ;; *) die "--initramfs invalide : auto, dracut ou mkinitcpio" ;; esac
	case "$SLOT" in "" | a | b) ;; *) die "--slot invalide : a ou b" ;; esac
	TPM2_DEVICE=${o_tpm:-auto}
	if [ -n "$o_iter" ]; then case "$o_iter" in *[!0-9]* | '') die "--iter-time : nombre de ms" ;; esac; fi
	if [ -n "$o_mem" ]; then case "$o_mem" in *[!0-9]* | '') die "--pbkdf-memory : nombre de Kio" ;; esac; fi
	return 0
}

save_settings() {
	local c="$R$P_CONF"
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] écrire %s (slot %s, A %s, B %s, swap %s, PCR %s)\n' "$c" "${SLOT:-?}" "${ROOT_A_UUID:--}" "${ROOT_B_UUID:--}" "${SWAP_UUID:--}" "$PCRS"
		return 0
	fi
	mkdir -p "$(dirname "$c")"
	if [ ! -f "$c" ]; then
		cat > "$c" <<-EOF
		# Rago OS — volumes chiffrés (module M3). Marqueur : $RAGO_ENC_MARKER
		# Relu par setup_secure_encryption.sh (install, enroll-tpm, reseal, verify, tpm-check).
		#   RAGO_ENC_SLOT         slot de ce système : a ou b (M4)
		#   RAGO_ENC_ROOT_A_UUID  UUID LUKS du slot A ; RAGO_ENC_ROOT_B_UUID : slot B (vide = un seul slot)
		#   RAGO_ENC_SWAP_UUID    UUID LUKS du swap d'hibernation (vide = pas d'hibernation)
		#   RAGO_ENC_TPM_PCRS     PCR liés au TPM (0+7 : firmware + Secure Boot)
		#   RAGO_ENC_DISCARD      1 = TRIM du SSD, 0 = non
		#   RAGO_ENC_INITRAMFS    auto | dracut | mkinitcpio
		EOF
	fi
	rago_conf_set "$c" RAGO_ENC_SLOT "$SLOT"
	rago_conf_set "$c" RAGO_ENC_ROOT_A_UUID "$ROOT_A_UUID"
	rago_conf_set "$c" RAGO_ENC_ROOT_B_UUID "$ROOT_B_UUID"
	rago_conf_set "$c" RAGO_ENC_SWAP_UUID "$SWAP_UUID"
	rago_conf_set "$c" RAGO_ENC_TPM_PCRS "$PCRS"
	rago_conf_set "$c" RAGO_ENC_DISCARD "$DISCARD"
	rago_conf_set "$c" RAGO_ENC_INITRAMFS "$INITRAMFS"
}

# UUID de la racine de CE slot.
this_root_uuid() {
	if [ "$SLOT" = b ]; then echo "$ROOT_B_UUID"; else echo "$ROOT_A_UUID"; fi
}

# --- disques -------------------------------------------------------------------------
# UUID LUKS d'un volume (vide si ce n'est pas du LUKS).
luks_uuid() { cryptsetup luksUUID "$1" 2>/dev/null || true; }

# Volume par son UUID LUKS.
dev_by_uuid() {
	local u=$1 d
	[ -n "$u" ] || return 1
	if [ -e "/dev/disk/by-uuid/$u" ]; then readlink -f "/dev/disk/by-uuid/$u"; return 0; fi
	d=$(blkid -U "$u" 2>/dev/null || true)
	[ -n "$d" ] || return 1
	echo "$d"
}

# Toujours code 0 (vide si ce n'est pas du LUKS) : utilisables dans $(…).
luks_dump() { cryptsetup luksDump "$1" 2>/dev/null || true; }

enroll_list() { { systemd-cryptenroll "$1" 2>/dev/null || true; } | rago_enroll_list_parse; }

sysblock() { echo "$SYS/class/block/$(basename "$(readlink -f "$1")")"; }

# Noms des chemins qui existent (un motif sans correspondance ne donne rien).
# Toujours code 0 : utilisable dans $(…) avec set -e / pipefail.
names_of() {
	local p
	for p in "$@"; do
		if [ -e "$p" ]; then echo "${p##*/}"; fi
	done
}

# Partitions d'un disque : « <dossier sysfs> <nom> » -> noms des partitions.
parts_of() {
	local p
	for p in "$1"/"$2"*; do
		if [ -e "$p/partition" ]; then echo "${p##*/}"; fi
	done
}

# Premier volume sous un volume device-mapper (dm-0 -> vda2).
first_slave() { names_of "$SYS/class/block/$1"/slaves/* | head -1; }

# Refuse tout volume qui sert ou qui contient des données encore utilisées.
# Toujours appliqué, même avec --yes.
check_device_safe() {
	local dev=$1 real name sb holders parts mnt
	[ -b "$dev" ] || die "$dev n'est pas un périphérique bloc"
	real=$(readlink -f "$dev")
	name=$(basename "$real")
	sb=$(sysblock "$real")
	if [ "$o_virtual" = 1 ]; then
		rago_dev_is_virtual "$sb" || die "$dev n'est pas un disque virtuel (mode --virtual-only : loop, virtio, QEMU seulement)"
	fi
	mnt=$(lsblk -nrpo NAME,MOUNTPOINT "$real" 2>/dev/null | awk '$2 != "" { print $1 " sur " $2 }' | head -3 || true)
	[ -z "$mnt" ] || die "$dev (ou une de ses partitions) est monté : $mnt"
	if awk 'NR > 1 { print $1 }' "$PROC/swaps" 2>/dev/null | xargs -r readlink -f | grep -qx "$real"; then
		die "$dev est un swap actif (swapoff d'abord)"
	fi
	holders=$(names_of "$sb"/holders/* | tr '\n' ' ')
	[ -z "$holders" ] || die "$dev est utilisé par : $holders(volume ouvert, LVM, RAID ?)"
	parts=$(parts_of "$sb" "$name" | tr '\n' ' ')
	[ -z "$parts" ] || die "$dev est un disque entier qui a des partitions ($parts) : donne la partition à chiffrer"
	return 0
}

confirm_wipe() {
	local dev=$1 sig
	sig=$(blkid -p -o export "$dev" 2>/dev/null | awk -F= '$1 == "TYPE" || $1 == "LABEL" || $1 == "PTTYPE" { printf "%s=%s ", $1, $2 }' || true)
	if [ -n "$sig" ]; then
		warn "$dev contient déjà : $sig"
	fi
	if [ "$o_yes" = 1 ]; then return 0; fi
	have_tty || die "pas de terminal pour confirmer : --yes (installateur) si c'est voulu"
	printf 'TOUT le contenu de %s sera effacé définitivement.\n' "$dev" > /dev/tty
	printf 'Pour confirmer, tape le chemin du périphérique (%s) : ' "$dev" > /dev/tty
	local ans
	IFS= read -r ans < /dev/tty || ans=""
	[ "$ans" = "$dev" ] || die "confirmation différente : rien n'a été fait"
}

# --- processeur / TPM -------------------------------------------------------------
cpu_report() { # cpu_report <fonction ok> <fonction attention>
	local flags drv
	flags=$(rago_cpu_flags "$PROC/cpuinfo")
	if rago_flag_has "$flags" aes; then "$1" "AES-NI présent (chiffrement accéléré)"; else "$2" "AES-NI absent : chiffrement logiciel, débit bien plus bas (chargements plus lents)"; fi
	if rago_flag_has "$flags" avx2; then "$1" "AVX2 présent"; else "$2" "AVX2 absent : pas de chemin AES-XTS vectorisé (VAES / AVX2) dans le noyau"; fi
	if rago_flag_has "$flags" vaes; then "$1" "VAES présent (AES-XTS vectorisé, noyau ≥ 6.10)"; fi
	drv=$(rago_xts_driver "$PROC/crypto" || true)
	if [ -n "$drv" ]; then
		if rago_xts_driver_accelerated "$drv"; then "$1" "xts(aes) du noyau : $drv"; else "$2" "xts(aes) du noyau : $drv (pas accéléré)"; fi
	fi
}

warn_cpu() {
	cpu_report true warn
}

tpm_kernel_present() { [ -e "$SYS/class/tpm/tpm0" ] && [ "$(cat "$SYS/class/tpm/tpm0/tpm_version_major" 2>/dev/null)" = 2 ]; }

# TCTI pour tpm2-tools selon --tpm2-device.
tpm_tcti() {
	case "$TPM2_DEVICE" in
	auto) echo "device:/dev/tpmrm0" ;;
	/*) echo "device:$TPM2_DEVICE" ;;
	*:*) echo "$TPM2_DEVICE" ;;
	*) echo "device:/dev/tpmrm0" ;;
	esac
}

# Valeurs actuelles des PCR (banque sha256) : lignes « <pcr> <hexa> ».
read_pcrs() {
	local p v ok=1
	if [ "$TPM2_DEVICE" = auto ] && [ -d "$SYS/class/tpm/tpm0/pcr-sha256" ]; then
		for p in ${PCRS//+/ }; do
			v=$(cat "$SYS/class/tpm/tpm0/pcr-sha256/$p" 2>/dev/null) || { ok=0; break; }
			printf '%s %s\n' "$p" "$(printf '%s' "$v" | tr 'A-F' 'a-f')"
		done
		[ "$ok" = 1 ] && return 0
	fi
	have tpm2_pcrread || return 1
	TPM2TOOLS_TCTI=$(tpm_tcti) tpm2_pcrread "sha256:$(rago_pcrs_comma "$PCRS")" 2>/dev/null | rago_pcrread_parse
}

# Dans un chroot (installateur M12) ? La racine vue ici n'est pas celle de PID 1.
# Sans droit de lire /proc/1/root (pas root) : réponse « non ».
in_chroot() {
	local me init
	me=$(stat -Lc %d:%i / 2>/dev/null) || return 1
	init=$(stat -Lc %d:%i "$PROC/1/root/." 2>/dev/null) || return 1
	[ "$me" != "$init" ]
}

secure_boot_state() { # -> on | off | ?
	local f="$SYS/firmware/efi/efivars/SecureBoot-$EFI_GLOBAL" b
	[ -r "$f" ] || { echo "?"; return 0; }
	b=$(od -An -t u1 -j 4 -N 1 "$f" 2>/dev/null | tr -d ' ' || true)
	if [ "$b" = 1 ]; then echo on; else echo off; fi
}

pcr7_warning() {
	warn "Risque PCR 7 : le TPM ne rend la clé que si le firmware (PCR 0) et Secure Boot"
	warn "(PCR 7 : activation, clés PK / KEK / db, liste dbx) sont ceux d'aujourd'hui. Une"
	warn "mise à jour du BIOS / UEFI ou de la dbx, ou un changement de Secure Boot, les"
	warn "modifie : au démarrage suivant la passphrase de secours sera demandée (rien n'est"
	warn "perdu). Ensuite : sudo rago-encryption reseal. Sans la passphrase de secours,"
	warn "un TPM qui refuse = données perdues : garde-la en lieu sûr."
}

# --- initramfs ----------------------------------------------------------------------
detect_initramfs() {
	if [ "$INITRAMFS" != auto ]; then echo "$INITRAMFS"; return 0; fi
	if [ -x "$R/usr/bin/mkinitcpio" ] && [ -f "$R/etc/mkinitcpio.conf" ]; then echo mkinitcpio; return 0; fi
	if [ -x "$R/usr/bin/dracut" ] || [ -x "$R/usr/sbin/dracut" ]; then echo dracut; return 0; fi
	if [ -x "$R/usr/sbin/update-initramfs" ] || [ -x "$R/usr/bin/update-initramfs" ]; then echo initramfs-tools; return 0; fi
	echo none
}

dracut_modules_dir() {
	local d
	for d in "$R/usr/lib/dracut/modules.d" "$R/lib/dracut/modules.d"; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	return 1
}

# HOOKS de /etc/mkinitcpio.conf (fichier du système, lu dans un sous-shell
# comme le fait mkinitcpio ; les drop-ins Rago sont ignorés).
mkinitcpio_hooks_orig() {
	(
		set +eu
		HOOKS=()
		# shellcheck disable=SC1090,SC1091
		. "$R/etc/mkinitcpio.conf" >/dev/null 2>&1
		echo "${HOOKS[*]}"
	)
}

# HOOKS effectifs : mkinitcpio.conf puis les drop-ins dans l'ordre.
mkinitcpio_hooks_effective() {
	(
		set +eu
		HOOKS=()
		# shellcheck disable=SC1090,SC1091
		. "$R/etc/mkinitcpio.conf" >/dev/null 2>&1
		for f in "$R"/etc/mkinitcpio.conf.d/*.conf; do
			# shellcheck disable=SC1090
			[ -f "$f" ] && . "$f" >/dev/null 2>&1
		done
		echo "${HOOKS[*]}"
	)
}

mkinitcpio_has_dropins() {
	grep -qs 'mkinitcpio.conf.d' "$R/usr/bin/mkinitcpio"
}

# Noyaux et leur initramfs : lignes « <version> <chemin initramfs> ».
initramfs_images() {
	local d k img pkgbase
	for d in "$R"/usr/lib/modules/*; do
		[ -d "$d" ] || continue
		k=${d##*/}
		[ -e "$d/modules.dep" ] || [ -e "$d/modules.order" ] || continue
		pkgbase=$(cat "$d/pkgbase" 2>/dev/null || true)
		img=""
		if [ -n "$pkgbase" ] && [ -e "$R/boot/initramfs-$pkgbase.img" ]; then
			img="/boot/initramfs-$pkgbase.img"
		elif [ -n "$pkgbase" ] && [ "$(detect_initramfs)" = mkinitcpio ]; then
			img="/boot/initramfs-$pkgbase.img"
		elif [ -e "$R/boot/initrd.img-$k" ] || [ -e "$R/boot/vmlinuz-$k" ]; then
			img="/boot/initrd.img-$k"
		elif [ -e "$R/boot/initramfs-$k.img" ]; then
			img="/boot/initramfs-$k.img"
		fi
		[ -n "$img" ] && printf '%s %s\n' "$k" "$img"
	done
	return 0
}

regen_initramfs() {
	local gen k img
	gen=$(detect_initramfs)
	case "$gen" in
	dracut)
		while read -r k img; do
			[ -n "$k" ] || continue
			log "dracut : $img (noyau $k)"
			run dracut --force --kver "$k" "$img" || die "dracut a échoué pour $k (voir ci-dessus)"
		done < <(initramfs_images)
		;;
	mkinitcpio)
		log "mkinitcpio -P (tous les préréglages)"
		run mkinitcpio -P || die "mkinitcpio a échoué (voir ci-dessus)"
		;;
	*) die "pas de générateur d'initramfs pris en charge ($gen)" ;;
	esac
}

# Liste des fichiers d'une initramfs.
initramfs_list() {
	local img=$1 gen
	gen=$(detect_initramfs)
	if [ "$gen" = mkinitcpio ] && have lsinitcpio; then
		lsinitcpio "$img" 2>/dev/null
	elif have lsinitrd; then
		lsinitrd "$img" 2>/dev/null
	else
		return 1
	fi
}

initramfs_file() { # initramfs_file <image> <chemin dans l'image>
	local img=$1 path=$2 gen tmp
	gen=$(detect_initramfs)
	if [ "$gen" = mkinitcpio ] && have lsinitcpio; then
		tmp=$(mktemp -d)
		(cd "$tmp" && lsinitcpio -x "$img" "$path" >/dev/null 2>&1) || true
		cat "$tmp/$path" 2>/dev/null || true
		rm -rf "$tmp"
	elif have lsinitrd; then
		lsinitrd -f "$path" "$img" 2>/dev/null || true
	fi
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

version_ge() { # version_ge <a> <b> : a >= b ?
	[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

check_tools() {
	local v gen kmap
	if have cryptsetup; then
		v=$(cryptsetup --version 2>/dev/null | awk '{ print $2 }' || true)
		if version_ge "$v" 2.4; then ok "cryptsetup $v (LUKS2, argon2id, jetons)"; else ko "cryptsetup $v : 2.4 au moins (jetons TPM2)"; fi
	else
		ko "cryptsetup absent (sudo $0 deps)"
	fi
	if have systemd-cryptenroll; then
		v=$(systemd-cryptenroll --version 2>/dev/null | awk 'NR == 1 { print $2 }' || true)
		if version_ge "${v:-0}" 250; then ok "systemd-cryptenroll (systemd $v)"; else ko "systemd $v : 250 au moins"; fi
	else
		ko "systemd-cryptenroll absent"
	fi
	if [ -x "$R/usr/lib/systemd/systemd-cryptsetup" ] || [ -x "$R/lib/systemd/systemd-cryptsetup" ] || have systemd-cryptsetup; then
		ok "systemd-cryptsetup (crypttab, tpm2-device=auto)"
	else
		ko "systemd-cryptsetup absent (paquet systemd-cryptsetup sur Debian / Ubuntu)"
	fi
	if find "$R/usr/lib" "$R/lib" -maxdepth 3 -name 'libcryptsetup-token-systemd-tpm2.so' 2>/dev/null | grep -q .; then
		ok "jeton TPM2 de systemd pour cryptsetup"
	else
		ko "libcryptsetup-token-systemd-tpm2.so absent"
	fi
	if find "$R/usr/lib" "$R/lib" -maxdepth 2 -name 'libtss2-esys.so*' 2>/dev/null | grep -q . &&
		find "$R/usr/lib" "$R/lib" -maxdepth 2 -name 'libtss2-tcti-device.so*' 2>/dev/null | grep -q .; then
		ok "bibliothèques TPM2 (tpm2-tss)"
	else
		ko "bibliothèques tpm2-tss absentes (sudo $0 deps)"
	fi
	gen=$(detect_initramfs)
	case "$gen" in
	dracut)
		ok "initramfs : dracut"
		if [ -x "$R/usr/bin/tpm2" ]; then ok "tpm2-tools (dracut n'ajoute le TPM qu'avec lui)"; else ko "tpm2-tools absent : dracut n'ajoutera pas le TPM à l'initramfs (sudo $0 deps)"; fi ;;
	mkinitcpio)
		if mkinitcpio_has_dropins; then ok "initramfs : mkinitcpio (drop-ins /etc/mkinitcpio.conf.d)"; else ko "mkinitcpio trop ancien : pas de /etc/mkinitcpio.conf.d (mettre à jour)"; fi ;;
	initramfs-tools) ko "initramfs : initramfs-tools ne sait pas déverrouiller par TPM2 : installe dracut (sudo $0 deps)" ;;
	*) ko "aucun générateur d'initramfs (dracut ou mkinitcpio)" ;;
	esac
	kmap=$(rago_conf_get "$R/etc/vconsole.conf" KEYMAP "")
	if [ -n "$kmap" ]; then
		ok "clavier au démarrage : $kmap (/etc/vconsole.conf)"
	else
		att "pas de KEYMAP dans /etc/vconsole.conf : au démarrage le clavier sera QWERTY (US) pour taper la passphrase de secours"
	fi
}

check_tpm() {
	local pcrs sb man n v bad="" tpm=1
	if tpm_kernel_present; then
		man=$(cat "$SYS/class/tpm/tpm0/device/description" 2>/dev/null || true)
		ok "TPM 2.0 présent${man:+ ($man)}"
		[ -e /dev/tpmrm0 ] || [ "$SYS" != /sys ] || att "/dev/tpmrm0 absent"
	elif [ "$TPM2_DEVICE" != auto ]; then
		ok "TPM donné : $TPM2_DEVICE"
	else
		ko "pas de TPM 2.0 : pas de déverrouillage automatique (activer fTPM / PTT dans le BIOS)"
		tpm=0
	fi
	if [ "$tpm" = 1 ]; then
		pcrs=$(read_pcrs || true)
		if [ -z "$pcrs" ]; then
			att "PCR $PCRS illisibles (banque sha256 ; tpm2-tools absent ?)"
		else
			while read -r n v; do
				if rago_pcr_is_unmeasured "$v"; then bad="$bad $n"; fi
			done <<<"$pcrs"
			if [ -n "$bad" ]; then
				ko "PCR${bad} jamais mesurés : le firmware ne mesure pas le démarrage, le TPM ne protégerait rien"
			else
				ok "PCR $PCRS mesurés par le firmware (banque sha256)"
			fi
		fi
	fi
	if [ -d "$SYS/firmware/efi" ]; then ok "démarrage UEFI"; else ko "démarrage BIOS (legacy) : Secure Boot et PCR 7 impossibles"; fi
	sb=$(secure_boot_state)
	case "$sb" in
	on) ok "Secure Boot actif" ;;
	off) att "Secure Boot inactif : quand tu l'activeras (exigé par l'anti-triche), PCR 7 changera → passphrase puis « reseal »" ;;
	*) skip "état Secure Boot illisible" ;;
	esac
}

step_check() {
	load_settings
	n_ok=0 n_fail=0 n_warn=0 n_boot=0 n_skip=0
	printf 'Rago OS — matériel et logiciels pour le chiffrement (M3)\n'
	cpu_report ok att
	if [ -d "$SYS/module/dm_crypt" ] || grep -qs '/dm-crypt\.ko' "$R/usr/lib/modules/$(uname -r)/modules.builtin" ||
		find "$R/usr/lib/modules/$(uname -r)" -name 'dm-crypt.ko*' 2>/dev/null | grep -q .; then
		ok "dm-crypt disponible dans le noyau"
	else
		ko "dm-crypt absent du noyau $(uname -r)"
	fi
	check_tpm
	check_tools
	bilan
}

# =====================================================================================
# format
# =====================================================================================
step_format() {
	need_root format
	load_settings
	[ -z "$R" ] || die "format ne marche pas avec --root"
	[ -n "$o_device" ] || die "format : --device obligatoire"
	local label dev=$o_device tmpname
	case "$o_role" in
	root-a) label=rago-a ;;
	root-b) label=rago-b ;;
	swap) label=rago-swap ;;
	*) die "format : --role root-a, root-b ou swap" ;;
	esac
	have cryptsetup || die "cryptsetup absent (sudo $0 deps)"
	check_device_safe "$dev"
	warn_cpu
	confirm_wipe "$dev"
	get_new_pass
	local args=(--batch-mode --type luks2 --cipher "$RAGO_LUKS_CIPHER" --key-size "$RAGO_LUKS_KEY_SIZE"
		--hash "$RAGO_LUKS_HASH" --pbkdf "$RAGO_LUKS_PBKDF" --label "$label")
	[ -n "$o_iter" ] && args+=(--iter-time "$o_iter")
	[ -n "$o_mem" ] && args+=(--pbkdf-memory "$o_mem")
	log "chiffrement de $dev : LUKS2 $RAGO_LUKS_CIPHER $RAGO_LUKS_KEY_SIZE bits, $RAGO_LUKS_HASH, $RAGO_LUKS_PBKDF, étiquette $label"
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] cryptsetup luksFormat %s %s  (passphrase lue sur stdin)\n' "${args[*]}" "$dev"
		return 0
	fi
	printf '%s\n' "$PASS" | cryptsetup luksFormat "${args[@]}" "$dev" || die "luksFormat a échoué"
	# Contrôle : les paramètres demandés sont bien ceux du volume.
	local sum
	sum=$(luks_dump "$dev" | rago_luks_summary)
	grep -qx 'version 2' <<<"$sum" || die "contrôle : $dev n'est pas en LUKS2"
	grep -qx "cipher $RAGO_LUKS_CIPHER" <<<"$sum" || die "contrôle : chiffrement inattendu"
	grep -Eq "^keyslot 0 $RAGO_LUKS_KEY_SIZE $RAGO_LUKS_PBKDF $RAGO_LUKS_HASH\$" <<<"$sum" || die "contrôle : emplacement 0 inattendu ($(grep '^keyslot' <<<"$sum" | head -1))"
	pass_opens "$dev" || die "contrôle : la passphrase de secours n'ouvre pas $dev"
	log "passphrase de secours posée (emplacement 0) et vérifiée"
	if [ "$o_role" = swap ] && [ "$o_mkswap" = 1 ]; then
		tmpname="rago-format-$$"
		log "création du swap dans le volume chiffré"
		printf '%s\n' "$PASS" | open_with_pass "$dev" "$tmpname" || die "ouverture impossible (dm-crypt absent ?) : relancer avec --no-mkswap"
		if ! mkswap -L rago-swap "/dev/mapper/$tmpname" >/dev/null; then
			cryptsetup close "$tmpname" || true
			die "mkswap a échoué"
		fi
		cryptsetup close "$tmpname"
	fi
	log "fait. Prochaine étape : open (installateur), puis install et, au premier démarrage, enroll-tpm"
}

# =====================================================================================
# open / close
# =====================================================================================
# Ouvre avec la passphrase lue sur l'entrée standard (une ligne) et garde dans
# l'en-tête les réglages de performance (TRIM, sans files d'attente dm-crypt).
open_with_pass() { # open_with_pass <volume> <nom>
	local a=(--disable-external-tokens --perf-no_read_workqueue --perf-no_write_workqueue --persistent)
	[ "$DISCARD" = 1 ] && a+=(--allow-discards)
	cryptsetup open "${a[@]}" "$1" "$2"
}

systemd_cryptsetup_bin() {
	local b
	for b in /usr/lib/systemd/systemd-cryptsetup /lib/systemd/systemd-cryptsetup /usr/bin/systemd-cryptsetup; do
		[ -x "$b" ] && { echo "$b"; return 0; }
	done
	return 1
}

step_open() {
	need_root open
	load_settings
	[ -n "$o_device" ] || die "open : --device obligatoire"
	local dev=$o_device name=$o_name lbl opts scs
	cryptsetup isLuks "$dev" 2>/dev/null || die "$dev n'est pas un volume LUKS"
	if [ -z "$name" ]; then
		lbl=$(luks_dump "$dev" | rago_luks_summary | sed -n 's/^label //p')
		name=${lbl:-luks-$(luks_uuid "$dev")}
	fi
	[ -e "/dev/mapper/$name" ] && die "/dev/mapper/$name existe déjà"
	if [ -n "$o_passfile" ]; then
		get_pass
		log "ouverture de $dev sous /dev/mapper/$name (passphrase)"
		[ "$dry_run" = 1 ] && { echo "[dry-run] cryptsetup open $dev $name"; return 0; }
		printf '%s\n' "$PASS" | open_with_pass "$dev" "$name" || die "ouverture refusée (passphrase ?)"
		return 0
	fi
	# Même chemin qu'au démarrage : TPM d'abord, sinon la passphrase est demandée.
	scs=$(systemd_cryptsetup_bin) || die "systemd-cryptsetup absent"
	opts=$(rago_crypttab_options "$DISCARD")
	opts=${opts%,x-initrd.attach}
	[ "$TPM2_DEVICE" = auto ] || opts=${opts/tpm2-device=auto/tpm2-device=$TPM2_DEVICE}
	log "ouverture de $dev sous /dev/mapper/$name (TPM, sinon passphrase)"
	run "$scs" attach "$name" "$dev" none "$opts" || die "ouverture refusée"
}

# Pourquoi un volume ouvert ne se ferme pas : ce qui s'appuie dessus (holders) et
# où il est encore monté, y compris dans l'espace de montage privé d'un service
# (systemd-udevd, systemd-logind… reçoivent une copie des montages faits après
# leur démarrage).
explain_busy() { # explain_busy <nom>
	local dm mm p mp ns seen=" "
	dm=$(basename "$(readlink -f "/dev/mapper/$1" 2>/dev/null)")
	mm=$(cat "$SYS/class/block/$dm/dev" 2>/dev/null) || return 0
	p=$(names_of "$SYS/class/block/$dm/holders"/* | tr '\n' ' ')
	[ -z "$p" ] || warn "$1 porte encore : $p"
	for p in "$PROC"/[0-9]*; do
		ns=$(readlink "$p/ns/mnt" 2>/dev/null) || continue
		case "$seen" in *" $ns "*) continue ;; esac
		mp=$(awk -v mm="$mm" '$3 == mm { print $5; exit }' "$p/mountinfo" 2>/dev/null || true)
		[ -n "$mp" ] || continue
		seen="$seen$ns "
		warn "$1 encore monté sur $mp (vu par le processus ${p##*/} : $(cat "$p/comm" 2>/dev/null))"
	done
}

step_close() {
	need_root close
	[ -n "$o_name" ] || die "close : --name obligatoire"
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] cryptsetup close %s\n' "$o_name"
		return 0
	fi
	local i rc=0
	# Juste après un démontage, udev peut encore lire le volume : on attend.
	if have udevadm; then udevadm settle 2>/dev/null || true; fi
	for i in 1 2 3 4 5; do
		rc=0
		if [ "$i" -lt 5 ]; then cryptsetup close "$o_name" 2>/dev/null || rc=$?; else cryptsetup close "$o_name" || rc=$?; fi
		[ "$rc" = 0 ] && return 0
		[ "$rc" = 5 ] || break # 5 : encore utilisé ; autre code : inutile de réessayer
		[ "$i" = 5 ] || sleep 1
	done
	[ "$rc" = 5 ] && explain_busy "$o_name"
	die "close : $o_name ne se ferme pas (cryptsetup, code $rc)"
}

# =====================================================================================
# enroll-tpm / reseal
# =====================================================================================
# Volumes Rago à traiter : --device, sinon ceux du fichier de réglages.
target_volumes() {
	local u d
	if [ -n "$o_device" ]; then echo "$o_device"; return 0; fi
	[ -f "$R$P_CONF" ] || die "pas de $P_CONF : donne --device, ou lance install d'abord"
	for u in "$ROOT_A_UUID" "$ROOT_B_UUID" "$SWAP_UUID"; do
		[ -n "$u" ] || continue
		d=$(dev_by_uuid "$u") || { warn "volume UUID=$u introuvable : ignoré"; continue; }
		echo "$d"
	done
}

tpm_unseal_test() { # tpm_unseal_test <volume> : 0 = le TPM ouvre, 1 = refus, 2 = test impossible
	[ "$TPM2_DEVICE" = auto ] || return 2
	tpm_kernel_present || return 2
	cryptsetup open --test-passphrase --token-only --token-type systemd-tpm2 "$1" >/dev/null 2>&1 && return 0
	return 1
}

record_pcrs() {
	local pcrs=$1
	[ "$dry_run" = 1 ] && return 0
	mkdir -p "$R$P_STATE"
	{
		printf '# PCR (sha256) au moment de l'"'"'enrôlement TPM, %s. Valeurs publiques (mesures).\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf '%s\n' "$pcrs"
	} > "$(state pcrs-at-enroll)"
}

step_enroll() {
	need_root "$cmd"
	load_settings
	load_ab
	if [ "$AB" = 1 ]; then step_enroll_ab; return; fi
	have systemd-cryptenroll || die "systemd-cryptenroll absent"
	local vols v pcrs n val bad="" list npw ntpm sb fails=0
	vols=$(target_volumes)
	[ -n "$vols" ] || die "aucun volume à enrôler"
	# Le firmware mesure-t-il vraiment le démarrage ?
	pcrs=$(read_pcrs || true)
	[ -n "$pcrs" ] || die "PCR $PCRS illisibles : TPM absent ? (tpm2-tools pour un TPM non standard)"
	while read -r n val; do
		rago_pcr_is_unmeasured "$val" && bad="$bad $n"
	done <<<"$pcrs"
	if [ -n "$bad" ]; then
		if [ "$o_zero_pcrs" = 1 ]; then
			warn "PCR${bad} jamais mesurés : enrôlement forcé (--allow-zero-pcrs), le TPM ne protège RIEN"
		else
			die "PCR${bad} jamais mesurés par le firmware : lier le TPM ne protégerait rien (n'importe quel système déverrouillerait). Refusé (--allow-zero-pcrs pour forcer)"
		fi
	fi
	sb=$(secure_boot_state)
	[ "$sb" = off ] && warn "Secure Boot est inactif : quand tu l'activeras, PCR 7 changera (passphrase au démarrage suivant, puis « reseal »)"
	get_pass
	# Avant tout : la passphrase de secours doit ouvrir chaque volume.
	for v in $vols; do
		cryptsetup isLuks --type luks2 "$v" 2>/dev/null || die "$v n'est pas un volume LUKS2"
		list=$(enroll_list "$v")
		npw=$(rago_slots_count "$list" password)
		[ "$npw" -ge 1 ] || die "$v n'a AUCUNE passphrase de secours : refusé (jamais le TPM seul). Ajoute-en une : cryptsetup luksAddKey $v"
		pass_opens "$v" || die "la passphrase de secours n'ouvre pas $v : rien n'a été changé"
	done
	for v in $vols; do
		log "$cmd : $v (TPM ${TPM2_DEVICE}, PCR $PCRS, ancien enrôlement TPM remplacé)"
		if [ "$dry_run" = 1 ]; then
			printf '[dry-run] systemd-cryptenroll --tpm2-device=%s --tpm2-pcrs=%s --wipe-slot=tpm2 %s\n' "$TPM2_DEVICE" "$PCRS" "$v"
			continue
		fi
		if ! PASSWORD="$PASS" systemd-cryptenroll --tpm2-device="$TPM2_DEVICE" --tpm2-pcrs="$PCRS" --wipe-slot=tpm2 "$v"; then
			warn "systemd-cryptenroll a échoué sur $v"
			fails=$((fails + 1))
			continue
		fi
		# Contrôles : 1 enrôlement TPM, passphrase toujours là et toujours bonne.
		list=$(enroll_list "$v")
		npw=$(rago_slots_count "$list" password)
		ntpm=$(rago_slots_count "$list" tpm2)
		[ "$npw" -ge 1 ] || die "$v : plus de passphrase après l'enrôlement (ne devrait jamais arriver) : NE PAS redémarrer, cryptsetup luksAddKey $v"
		[ "$ntpm" -eq 1 ] || { warn "$v : $ntpm enrôlements TPM (1 attendu)"; fails=$((fails + 1)); }
		pass_opens "$v" || die "$v : la passphrase de secours ne marche plus : NE PAS redémarrer"
		case "$(tpm_unseal_test "$v"; echo $?)" in
		0) log "$v : le TPM ouvre le volume (PCR actuels)" ;;
		1) warn "$v : le TPM n'ouvre pas le volume"; fails=$((fails + 1)) ;;
		*) log "$v : test d'ouverture par le TPM impossible ici (TPM du noyau requis)" ;;
		esac
	done
	[ "$fails" = 0 ] || die "$fails problème(s) pendant l'enrôlement (voir ci-dessus)"
	record_pcrs "$pcrs"
	[ "$dry_run" = 1 ] || rm -f "$R$P_RUNSTATUS"
	log "TPM enrôlé sur : $(echo "$vols" | tr '\n' ' ')(passphrase de secours gardée)"
	pcr7_warning
}

# =====================================================================================
# M4 : un jeton TPM par entrée de démarrage (UKI signée + PCR 11 prédit)
# =====================================================================================
# M4 en place ? (/etc/rago/update.conf écrit par manage_atomic_updates.sh setup)
ab_active() { grep -qs "$RAGO_AB_MARKER" "$R$P_UPDCONF"; }

pcrs_without() { # pcrs_without <liste 0+7+11> <pcr> -> liste sans ce PCR
	local p out=""
	for p in ${1//+/ }; do [ "$p" = "$2" ] || out="$out+$p"; done
	echo "${out#+}"
}

# systemd-cryptenroll accepte-t-il une valeur de PCR donnée d'avance
# (« 11:sha256=… », systemd ≥ 254) ?
cryptenroll_has_pcr_values() {
	local v
	v=$(systemd-cryptenroll --version 2>/dev/null | awk 'NR == 1 { print $2 }' || true)
	version_ge "${v:-0}" 254
}

# Réglages de M4 : AB=1 si M4 est en place ; ESPDIR, AB_PCR11 (0|1). PCR 11 est
# géré ici (valeur prédite par UKI) : retiré de PCRS, la liste lue sur le TPM.
load_ab() {
	AB=0
	AB_PCR11=0
	ESPDIR=""
	AB_TABLE=""
	PCRV=""
	ab_active || return 0
	AB=1
	AB_PCR11=$(rago_conf_get "$R$P_UPDCONF" RAGO_AB_PCR11 1)
	case "$AB_PCR11" in 0 | 1) ;; *) die "RAGO_AB_PCR11 invalide dans $P_UPDCONF (0 ou 1)" ;; esac
	if [ -n "$o_esp" ]; then
		ESPDIR=${o_esp%/}
	else
		ESPDIR="$R$(rago_conf_get "$R$P_KCONF" RAGO_ESP /boot)"
		ESPDIR=${ESPDIR%/}
	fi
	PCRS=$(pcrs_without "$PCRS" 11)
	[ -n "$PCRS" ] || die "PCR liés au TPM : il faut au moins 0+7 en plus de PCR 11"
	if [ "$AB_PCR11" = 1 ] && have systemd-cryptenroll && ! cryptenroll_has_pcr_values; then
		warn "systemd-cryptenroll trop ancien (< 254) pour lier PCR 11 à une valeur prédite : TPM lié à PCR $PCRS seulement (dégradé, l'UKI reste signée)"
		AB_PCR11=0
	fi
	return 0
}

# Certificat MOK de M0 : seules les UKI qu'il signe reçoivent un jeton (une UKI
# déposée par quelqu'un d'autre sur l'ESP n'est jamais enrôlée).
mok_cert() { echo "${RAGO_MOK_DIR:-$R/etc/rago/secureboot}/MOK.crt"; }

uki_signed_by_mok() { # 0 = signée par la clé MOK ; 1 = non ; 2 = vérification impossible
	local c
	c=$(mok_cert)
	[ -f "$c" ] && have sbverify || return 2
	sbverify --cert "$c" "$1" >/dev/null 2>&1
}

# Table des entrées de démarrage Rago de l'ESP (une fois par commande) :
#   AB_TABLE : lignes « <id> <slot a|b> <uki|conf> <PCR 11 prédit ou -> »
# (l'entrée unique de M0, rago.conf, ouvre le slot de ce système).
ab_build_table() {
	local id slot kind f pred rc meta
	AB_TABLE=""
	while read -r id slot kind; do
		[ -n "$id" ] || continue
		[ "$slot" = m0 ] && slot=${SLOT:-a}
		pred=-
		if [ "$kind" = uki ]; then
			f="$ESPDIR/$(rago_ab_entry_path "$id")"
			rc=0
			uki_signed_by_mok "$f" || rc=$?
			case "$rc" in
			0) ;;
			1) warn "$id : pas signée par la clé MOK ($(mok_cert)) : ignorée (aucun jeton TPM pour elle)"; continue ;;
			*) warn "$id : signature non vérifiable (sbverify ou $(mok_cert) absent) : prise telle quelle" ;;
			esac
			# Une UKI d'un slot copiée sous le nom de l'autre n'ouvre pas ce dernier.
			meta=$(rago_uki_meta "$f" slot)
			if [ -n "$meta" ] && [ "$meta" != "$slot" ]; then
				warn "$id : UKI du slot « $meta » sous le nom du slot $slot : ignorée (aucun jeton TPM pour elle)"
				continue
			fi
			if [ "$AB_PCR11" = 1 ]; then
				rc=0
				pred=$(rago_uki_unlock_pcr11 "$f") || rc=$?
				case "$rc" in
				0) ;;
				2) pred=-; warn "$id : UKI à sections non prises en charge (profils…) : PCR 11 non prédit, jeton PCR $PCRS seulement (dégradé)" ;;
				3) pred=-; warn "$id : UKI sans métadonnées Rago (.rago) : PCR 11 non prédit, jeton PCR $PCRS seulement (dégradé)" ;;
				*) pred=-; warn "$id : UKI illisible : jeton PCR $PCRS seulement (dégradé)" ;;
				esac
			fi
		fi
		AB_TABLE="$AB_TABLE$id $slot $kind $pred"$'\n'
	done < <(rago_ab_entries "$ESPDIR")
	return 0
}

# Empreinte de la politique TPM d'un jeton : PCR de base à leur valeur actuelle
# (PCRV), plus PCR 11 prédit s'il est donné.
ab_policy() { # ab_policy <PCR 11 prédit ou "">
	local a=() n v
	while read -r n v; do
		[ -n "$n" ] && a+=("$n=$v")
	done <<<"$PCRV"
	[ -n "$1" ] && a+=("11=$1")
	rago_tpm2_policy_pcr "${a[@]}"
}

# Jetons attendus pour un volume : une ligne par politique distincte
#   <empreinte> <PCR pour systemd-cryptenroll> <entrées séparées par ,>
#   ab_expected <root-a|root-b|swap>
ab_expected() {
	local role=$1 id slot kind pred pol spec out=""
	while read -r id slot kind pred; do
		[ -n "$id" ] || continue
		case "$role" in
		root-a) [ "$slot" = a ] || continue ;;
		root-b) [ "$slot" = b ] || continue ;;
		esac
		if [ "$pred" = - ]; then
			spec=$PCRS
			pol=$(ab_policy "") || return 1
		else
			spec="$PCRS+11:sha256=$pred"
			pol=$(ab_policy "$pred") || return 1
		fi
		out="$out$pol $spec $id"$'\n'
	done <<<"$AB_TABLE"
	printf '%s' "$out" | awk 'NF {
		if (!($1 in s)) { o[++n] = $1; s[$1] = $2 }
		e[$1] = e[$1] (e[$1] == "" ? "" : ",") $3
	} END { for (i = 1; i <= n; i++) print o[i], s[o[i]], e[o[i]] }'
}

ab_tokens() { luks_dump "$1" | rago_luks_tpm2_tokens; }

has_policy() { awk -v p="$1" '$4 == p { f = 1 } END { exit !f }' <<<"$2"; } # has_policy <empreinte> <jetons>

# Volumes Rago : « <rôle> <uuid> », ou celui de --device.
ab_volumes() {
	local u r
	if [ -n "$o_device" ]; then
		u=$(luks_uuid "$o_device")
		case "$u" in
		"") die "$o_device n'est pas un volume LUKS" ;;
		"$ROOT_A_UUID") r="root-a" ;;
		"$ROOT_B_UUID") r="root-b" ;;
		"$SWAP_UUID") r=swap ;;
		*) die "$o_device (UUID=$u) n'est pas un volume Rago de $P_CONF" ;;
		esac
		echo "$r $u"
		return 0
	fi
	[ -f "$R$P_CONF" ] || die "pas de $P_CONF : lancer install d'abord"
	[ -z "$ROOT_A_UUID" ] || echo "root-a $ROOT_A_UUID"
	[ -z "$ROOT_B_UUID" ] || echo "root-b $ROOT_B_UUID"
	[ -z "$SWAP_UUID" ] || echo "swap $SWAP_UUID"
	return 0
}

# PCR actuels (PCRV) + table des entrées ; refus si l'ESP ne montre aucune entrée
# pour le slot en marche (ESP pas montée : on ne retire jamais rien à l'aveugle).
ab_prepare() {
	local n val bad=""
	PCRV=$(read_pcrs || true)
	[ -n "$PCRV" ] || die "PCR $PCRS illisibles : TPM absent ? (tpm2-tools pour un TPM non standard)"
	while read -r n val; do
		rago_pcr_is_unmeasured "$val" && bad="$bad $n"
	done <<<"$PCRV"
	if [ -n "$bad" ]; then
		if [ "$o_zero_pcrs" = 1 ]; then
			warn "PCR${bad} jamais mesurés : forcé (--allow-zero-pcrs), le TPM ne protège RIEN"
		else
			die "PCR${bad} jamais mesurés par le firmware : lier le TPM ne protégerait rien. Refusé (--allow-zero-pcrs pour forcer)"
		fi
	fi
	[ -d "$ESPDIR" ] || die "ESP introuvable : $ESPDIR (--esp, ou RAGO_ESP dans $P_KCONF)"
	ab_build_table
	awk -v s="${SLOT:-a}" '$2 == s { f = 1 } END { exit !f }' <<<"$AB_TABLE" ||
		die "aucune entrée de démarrage Rago du slot ${SLOT:-a} dans $ESPDIR (ESP pas montée ?) : rien n'est changé"
}

# Combien de jetons attendus manquent sur un volume.
ab_missing() { # ab_missing <rôle> <volume>
	local exp toks pol spec ids n=0
	exp=$(ab_expected "$1") || { echo 0; return 1; }
	toks=$(ab_tokens "$2")
	while read -r pol spec ids; do
		[ -n "$pol" ] || continue
		has_policy "$pol" "$toks" || n=$((n + 1))
	done <<<"$exp"
	echo "$n"
}

# Met les jetons TPM d'un volume en accord avec les entrées de démarrage :
# ajoute ceux qui manquent (si <ajouter> = 1, passphrase dans PASS), puis, si
# chaque entrée a son jeton, retire les jetons qui ne servent plus. Jamais un
# emplacement de passphrase. Code 1 si des jetons manquent encore.
#   ab_sync_volume <rôle> <volume> <ajouter 0|1>
ab_sync_volume() {
	local role=$1 dev=$2 add=$3 exp toks pol spec ids miss=0 tok kslots pcrs ks list npw err
	exp=$(ab_expected "$role") || { warn "$role : politique TPM incalculable"; return 1; }
	toks=$(ab_tokens "$dev")
	[ -n "$exp" ] || log "$role ($dev) : aucune entrée de démarrage ne l'ouvre"
	while read -r pol spec ids; do
		[ -n "$pol" ] || continue
		if has_policy "$pol" "$toks"; then
			log "$role : jeton TPM à jour pour $ids"
			continue
		fi
		if [ "$add" = 0 ]; then
			warn "$role : pas de jeton TPM pour $ids (la passphrase sera demandée au démarrage par cette entrée)"
			miss=$((miss + 1))
			continue
		fi
		case "$spec" in
		*:sha256=*) log "$role ($dev) : enrôlement TPM pour $ids (PCR $PCRS + 11 = mesure prédite de l'UKI)" ;;
		*) log "$role ($dev) : enrôlement TPM pour $ids (PCR $PCRS)" ;;
		esac
		if [ "$dry_run" = 1 ]; then
			printf '[dry-run] systemd-cryptenroll --tpm2-device=%s --tpm2-pcrs=%s %s\n' "$TPM2_DEVICE" "$spec" "$dev"
			continue
		fi
		if ! err=$(PASSWORD="$PASS" systemd-cryptenroll --tpm2-device="$TPM2_DEVICE" --tpm2-pcrs="$spec" "$dev" 2>&1 < /dev/null); then
			warn "systemd-cryptenroll a échoué sur $dev : $(printf '%s' "$err" | tail -1)"
			miss=$((miss + 1))
			continue
		fi
		toks=$(ab_tokens "$dev")
		if ! has_policy "$pol" "$toks"; then
			# La politique calculée ici n'est pas celle de systemd : on ne sait plus
			# reconnaître les jetons, donc on ne retire rien.
			warn "$role : le nouveau jeton n'a pas la politique attendue ($pol) : aucun retrait sur ce volume"
			miss=$((miss + 1))
		fi
	done <<<"$exp"
	[ "$miss" = 0 ] || return 1
	[ "$dry_run" = 1 ] && [ "$add" = 1 ] && return 0
	list=$(enroll_list "$dev")
	while read -r tok kslots pcrs pol; do
		[ -n "$tok" ] || continue
		awk -v p="$pol" '$1 == p { f = 1 } END { exit !f }' <<<"$exp" && continue
		for ks in ${kslots//,/ }; do
			if [ "$(awk -v s="$ks" '$1 == s { print $2 }' <<<"$list")" != tpm2 ]; then
				warn "$role : emplacement $ks du jeton $tok n'est pas un emplacement TPM : laissé"
				continue 2
			fi
		done
		log "$role ($dev) : retrait du jeton TPM qui ne sert plus (emplacement $kslots, PCR $pcrs)"
		if [ "$dry_run" = 1 ]; then
			printf '[dry-run] systemd-cryptenroll --wipe-slot=%s %s\n' "$kslots" "$dev"
			continue
		fi
		systemd-cryptenroll --wipe-slot="$kslots" "$dev" >/dev/null 2>&1 < /dev/null || warn "$role : retrait de l'emplacement $kslots impossible"
	done <<<"$toks"
	[ "$dry_run" = 1 ] && return 0
	npw=$(rago_slots_count "$(enroll_list "$dev")" password)
	[ "$npw" -ge 1 ] || die "$dev : plus de passphrase de secours (ne devrait jamais arriver) : NE PAS redémarrer, cryptsetup luksAddKey $dev"
	return 0
}

ab_report_entries() {
	local id slot kind pred
	while read -r id slot kind pred; do
		[ -n "$id" ] || continue
		if [ "$pred" = - ]; then
			log "entrée $id (slot $slot) : jeton PCR $PCRS"
		else
			log "entrée $id (slot $slot) : jeton PCR $PCRS + 11 (UKI signée, PCR 11 prédit ${pred:0:16}…)"
		fi
	done <<<"$AB_TABLE"
}

step_enroll_ab() {
	have systemd-cryptenroll || die "systemd-cryptenroll absent"
	local vols role u d n need=0 fails=0 sb
	vols=$(ab_volumes)
	[ -n "$vols" ] || die "aucun volume à enrôler"
	ab_prepare
	ab_report_entries
	sb=$(secure_boot_state)
	[ "$sb" = off ] && warn "Secure Boot est inactif : l'UKI n'est pas vérifiée au démarrage et PCR 7 changera à l'activation (passphrase, puis « reseal »)"
	while read -r role u; do
		[ -n "$role" ] || continue
		d=$(dev_by_uuid "$u") || die "$role : volume UUID=$u introuvable"
		cryptsetup isLuks --type luks2 "$d" 2>/dev/null || die "$d n'est pas un volume LUKS2"
		[ "$(rago_slots_count "$(enroll_list "$d")" password)" -ge 1 ] ||
			die "$d n'a AUCUNE passphrase de secours : refusé (jamais le TPM seul). Ajoute-en une : cryptsetup luksAddKey $d"
		n=$(ab_missing "$role" "$d") || die "$role : politique TPM incalculable"
		need=$((need + n))
	done <<<"$vols"
	if [ "$need" -gt 0 ] && [ "$dry_run" = 0 ]; then
		get_pass
		while read -r role u; do
			[ -n "$role" ] || continue
			d=$(dev_by_uuid "$u")
			pass_opens "$d" || die "la passphrase de secours n'ouvre pas $d : rien n'a été changé"
		done <<<"$vols"
	elif [ "$need" = 0 ]; then
		log "chaque entrée de démarrage a déjà son jeton TPM : pas besoin de la passphrase"
	fi
	while read -r role u; do
		[ -n "$role" ] || continue
		d=$(dev_by_uuid "$u")
		ab_sync_volume "$role" "$d" 1 || fails=$((fails + 1))
	done <<<"$vols"
	[ "$fails" = 0 ] || die "$fails volume(s) sans tous leurs jetons TPM (voir ci-dessus) : la passphrase de secours reste demandée par les entrées concernées"
	record_pcrs "$PCRV"
	[ "$dry_run" = 1 ] || rm -f "$R$P_RUNSTATUS"
	log "TPM en accord avec les entrées de démarrage (passphrase de secours gardée)"
	pcr7_warning
}

# prune-tpm : retire seulement (sans passphrase), volume par volume, quand
# chaque entrée de démarrage a déjà son jeton. Code 1 s'il en manque.
step_prune() {
	need_root prune-tpm
	load_settings
	load_ab
	[ "$AB" = 1 ] || die "prune-tpm sert aux mises à jour A/B (M4 : $P_UPDCONF absent) ; sans M4, enroll-tpm / reseal remplacent le jeton"
	have systemd-cryptenroll || die "systemd-cryptenroll absent"
	local vols role u d fails=0
	vols=$(ab_volumes)
	ab_prepare
	while read -r role u; do
		[ -n "$role" ] || continue
		d=$(dev_by_uuid "$u") || { warn "$role : volume UUID=$u introuvable"; continue; }
		ab_sync_volume "$role" "$d" 0 || fails=$((fails + 1))
	done <<<"$vols"
	if [ "$fails" -gt 0 ]; then
		warn "$fails volume(s) n'ont pas un jeton pour chaque entrée : rien n'y est retiré ; sudo rago-encryption reseal"
		return 1
	fi
	log "jetons TPM en accord avec les entrées de démarrage"
}

# =====================================================================================
# install
# =====================================================================================
uuid_of() { # uuid_of <uuid donné> <volume donné> <nom de l'option>
	if [ -n "$1" ]; then echo "$1"; return 0; fi
	[ -n "$2" ] || return 0
	cryptsetup isLuks --type luks2 "$2" 2>/dev/null || die "$3 : $2 n'est pas un volume LUKS2"
	luks_uuid "$2"
}

label_of_uuid() {
	local d
	d=$(dev_by_uuid "$1" 2>/dev/null) || return 0
	luks_dump "$d" | rago_luks_summary | sed -n 's/^label //p'
}

# Volume LUKS sous la racine montée (« / » du système, ou du chroot).
mounted_root_luks_uuid() {
	local src name dev
	src=$(findmnt -no SOURCE / 2>/dev/null || true)
	case "$src" in /dev/mapper/* | /dev/dm-*) ;; *) return 1 ;; esac
	name=$(basename "$(readlink -f "$src")")
	dev=$(first_slave "$name")
	[ -n "$dev" ] || return 1
	luks_uuid "/dev/$dev"
}

resolve_volumes() {
	local r s o lbl other_slot
	r=$(uuid_of "$o_root_uuid" "$o_root_dev" --root-device)
	s=$(uuid_of "$o_swap_uuid" "$o_swap_dev" --swap-device)
	o=$(uuid_of "$o_other_uuid" "$o_other_dev" --other-slot-device)
	# Sans volume donné : la racine montée, sinon les réglages déjà enregistrés.
	if [ -z "$r" ]; then
		[ -n "$R" ] || r=$(mounted_root_luks_uuid || true)
		[ -n "$r" ] || r=$(this_root_uuid)
	fi
	[ -n "$r" ] || die "racine chiffrée introuvable : --root-device ou --root-uuid"
	if [ -z "$SLOT" ]; then
		lbl=$(label_of_uuid "$r")
		case "$lbl" in rago-b) SLOT=b ;; *) SLOT=a ;; esac
	fi
	if [ "$SLOT" = b ]; then
		ROOT_B_UUID=$r
		[ -n "$o" ] && ROOT_A_UUID=$o
		other_slot=$ROOT_A_UUID
	else
		ROOT_A_UUID=$r
		[ -n "$o" ] && ROOT_B_UUID=$o
		other_slot=$ROOT_B_UUID
	fi
	[ -n "$s" ] && SWAP_UUID=$s
	[ "$other_slot" != "$r" ] || die "les deux slots ont le même volume ($r)"
	[ -z "$SWAP_UUID" ] || [ "$SWAP_UUID" != "$r" ] || die "racine et swap sur le même volume"
	THIS_ROOT=$r
}

check_root_is_encrypted() {
	[ -n "$R" ] && return 0
	local u
	u=$(mounted_root_luks_uuid || true)
	[ -n "$u" ] || die "la racine « / » n'est pas sur un volume LUKS : M3 ne chiffre pas un système déjà installé (installateur M12)"
	[ "$u" = "$THIS_ROOT" ] || die "la racine montée est sur UUID=$u, pas sur le volume donné ($THIS_ROOT)"
}

crypttab_lines() {
	local opts
	opts=$(rago_crypttab_options "$DISCARD")
	rago_crypttab_line "$RAGO_MAP_ROOT" "$THIS_ROOT" "$opts"
	[ -n "$SWAP_UUID" ] && rago_crypttab_line "$RAGO_MAP_SWAP" "$SWAP_UUID" "$opts"
	return 0
}

install_crypttab() {
	local lines=() l
	while IFS= read -r l; do lines+=("$l"); done < <(crypttab_lines)
	log "crypttab : ${lines[*]%% *}"
	backup_once "$P_CRYPTTAB"
	{
		if [ ! -s "$R$P_CRYPTTAB" ]; then
			printf '# /etc/crypttab : volumes chiffrés ouverts au démarrage (crypttab(5)).\n'
		fi
		rago_crypttab_merge "$R$P_CRYPTTAB" "${lines[@]}"
	} | put_file "$P_CRYPTTAB" 0600
	# Crypttab de l'initramfs (sd-encrypt de mkinitcpio, module rago-crypttab de
	# dracut) : les volumes du démarrage seulement, pas ceux du joueur.
	log "crypttab de l'initramfs : $P_CRYPTTAB_INITRAMFS"
	backup_once "$P_CRYPTTAB_INITRAMFS"
	rago_crypttab_merge "$R$P_CRYPTTAB_INITRAMFS" "${lines[@]}" | put_file "$P_CRYPTTAB_INITRAMFS" 0600
}

install_fstab_swap() {
	[ -n "$SWAP_UUID" ] || return 0
	local fsu
	fsu=$(blkid -o value -s UUID "/dev/mapper/$RAGO_MAP_SWAP" 2>/dev/null || true)
	log "fstab : swap /dev/mapper/$RAGO_MAP_SWAP (priorité $SWAP_PRIO, sous le zram de M1)"
	backup_once "$P_FSTAB"
	rago_fstab_swap_merge "$R$P_FSTAB" "/dev/mapper/$RAGO_MAP_SWAP" "$SWAP_PRIO" "${fsu:+UUID=$fsu}" | put_file "$P_FSTAB" 0644
}

install_initramfs_conf() {
	local mods kbd=0 orig new why
	[ -n "$(rago_conf_get "$R/etc/vconsole.conf" KEYMAP "")" ] && kbd=1
	case "$GEN" in
	dracut)
		mods=$(rago_dracut_modules "$(dracut_modules_dir)" ) || die "modules dracut introuvables"
		case " $mods " in *" systemd "*) ;; *) die "dracut sans module systemd : pas de TPM2 dans l'initramfs" ;; esac
		case " $mods " in *" tpm2-tss "*) ;; *) warn "module dracut tpm2-tss absent : le TPM ne sera pas dans l'initramfs" ;; esac
		[ -x "$R/usr/bin/tpm2" ] || [ "$apply" = 0 ] || die "tpm2-tools absent : dracut n'ajouterait pas le TPM à l'initramfs (sudo $0 deps)"
		[ -f "$SRC_DRACUT_MOD" ] || die "module dracut rago-crypttab introuvable ($SRC_DRACUT_MOD)"
		log "dracut : $P_DRACUT, module rago-crypttab"
		put_file "$P_DRACUT_MOD" 0755 < "$SRC_DRACUT_MOD"
		mods="$mods rago-crypttab"
		rago_dracut_conf "$mods" "$THIS_ROOT" "$SWAP_UUID" "$kbd" | put_file "$P_DRACUT" 0644
		;;
	mkinitcpio)
		mkinitcpio_has_dropins || [ "$apply" = 0 ] || die "mkinitcpio trop ancien : pas de /etc/mkinitcpio.conf.d"
		orig=$(mkinitcpio_hooks_orig)
		[ -n "$orig" ] || orig="base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck"
		# shellcheck disable=SC2086  # découpage voulu
		new=$(rago_mkinitcpio_hooks $orig)
		# shellcheck disable=SC2086
		why=$(rago_mkinitcpio_hooks_ok $new) || die "HOOKS calculés invalides ($why) : $new"
		log "mkinitcpio : $P_MKINIT (HOOKS=($new))"
		rago_mkinitcpio_dropin "$orig" "$new" | put_file "$P_MKINIT" 0644
		;;
	initramfs-tools) die "initramfs-tools ne sait pas déverrouiller par TPM2 : installe dracut (sudo $0 deps) puis relance" ;;
	*) die "aucun générateur d'initramfs (dracut ou mkinitcpio) : sudo $0 deps" ;;
	esac
}

# Ligne de commande du noyau Rago (M0) : /etc/rago/kernel.conf.
#   RAGO_CMDLINE (base) : root= pointé sur /dev/mapper/rago-root ;
#   RAGO_CMDLINE_EXTRA  : resume= vers le swap chiffré (suivi comme M1).
update_kernel_cmdline() {
	local kc="$R$P_KCONF" base extra nbase nextra want t added=""
	want=$(rago_enc_cmdline "$([ -n "$SWAP_UUID" ] && echo 1 || echo 0)")
	if [ ! -f "$kc" ]; then
		warn "$P_KCONF absent (noyau Rago M0 pas installé) : ajoute « $want » à la ligne de commande de ton chargeur de démarrage"
		return 0
	fi
	base=$(rago_conf_get "$kc" RAGO_CMDLINE "")
	extra=$(rago_conf_get "$kc" RAGO_CMDLINE_EXTRA "")
	nbase=$(rago_cmdline_drop_key "$base" root)
	nbase=$(rago_cmdline_drop_key "$nbase" resume)
	nbase=$(rago_norm_ws "root=/dev/mapper/$RAGO_MAP_ROOT $nbase")
	nextra=$(rago_cmdline_drop_key "$extra" resume)
	nextra=$(rago_cmdline_drop_key "$nextra" root)
	for t in $want; do
		case "$t" in resume=*) nextra=$(rago_cmdline_add "$nextra" "$t"); added="$added $t" ;; esac
	done
	if rago_cmdline_value "$nbase $nextra" rd.luks.uuid >/dev/null || rago_cmdline_value "$nbase $nextra" rd.luks.name >/dev/null; then
		warn "rd.luks.* sur la ligne de commande : seuls ces volumes s'ouvriront au démarrage (le swap doit y être, sinon pas de resume)"
	fi
	if [ "$nbase" = "$base" ] && [ "$nextra" = "$extra" ]; then return 0; fi
	log "ligne de commande du noyau Rago : RAGO_CMDLINE=\"$nbase\" RAGO_CMDLINE_EXTRA=\"$nextra\""
	if [ "$dry_run" = 1 ]; then return 0; fi
	mkdir -p "$R$P_STATE"
	[ -e "$(state kernel-cmdline-before)" ] || printf 'RAGO_CMDLINE="%s"\nRAGO_CMDLINE_EXTRA="%s"\n' "$base" "$extra" > "$(state kernel-cmdline-before)"
	rago_conf_set "$kc" RAGO_CMDLINE "$nbase"
	rago_conf_set "$kc" RAGO_CMDLINE_EXTRA "$nextra"
	printf '%s\n' "${added# }" > "$(state cmdline-tokens)"
	NEED_BOOTLOADER=1
}

install_tool() {
	local f
	log "outil : $P_BIN, $P_LIBDIR/, service rago-tpm-check"
	for f in rago_crypt_lib.sh rago_host_lib.sh rago_uki_lib.sh; do
		put_file "$P_LIBDIR/$f" 0644 < "$libdir/$f"
	done
	put_file "$P_LIBDIR/setup_secure_encryption.sh" 0755 < "$here/$(basename "${BASH_SOURCE[0]}")"
	{
		printf '#!/bin/sh\n'
		printf '# Rago OS — chiffrement LUKS2 + TPM2 (module M3). Marqueur : %s\n' "$RAGO_ENC_MARKER"
		printf 'exec %s/setup_secure_encryption.sh "$@"\n' "$P_LIBDIR"
	} | put_file "$P_BIN" 0755
	put_file "$P_UNIT_SVC" 0644 < "$SRC_UNIT_SVC"
	put_file "$P_UNIT_TIMER" 0644 < "$SRC_UNIT_TIMER"
	if [ "$dry_run" = 1 ]; then
		echo "[dry-run] activer rago-tpm-check.timer"
	elif [ "$apply" = 1 ] && have systemctl; then
		systemctl daemon-reload 2>/dev/null || true
		systemctl enable rago-tpm-check.timer >/dev/null 2>&1 || warn "rago-tpm-check.timer non activé"
	else
		mkdir -p "$R/etc/systemd/system/timers.target.wants"
		ln -sf "$P_UNIT_TIMER" "$R/etc/systemd/system/timers.target.wants/rago-tpm-check.timer"
	fi
}

step_install() {
	need_root install
	load_settings
	GEN=$(detect_initramfs)
	NEED_BOOTLOADER=0
	resolve_volumes
	check_root_is_encrypted
	[ -n "$SWAP_UUID" ] || warn "pas de swap chiffré (--swap-device) : pas d'hibernation, le mode « Session préservée » du Fast OS Switch (M6) sera impossible"
	[ "$dry_run" = 1 ] || mkdir -p "$(state backup)"
	install_initramfs_conf
	install_crypttab
	install_fstab_swap
	update_kernel_cmdline
	save_settings
	install_tool
	if [ "$apply" = 0 ]; then
		log "fichiers écrits dans ${R:-/} (initramfs non régénérée : --no-apply / --root)"
		return 0
	fi
	regen_initramfs
	if [ "$NEED_BOOTLOADER" = 1 ]; then
		if ab_active; then
			warn "ligne de commande changée : sudo rago-update uki (nouvelle UKI du slot, essayée au redémarrage)"
		else
			warn "ligne de commande changée : sudo kernel/build_rago_kernel.sh bootloader, puis redémarrer"
		fi
	elif ab_active && [ "$apply" = 1 ]; then
		warn "initramfs régénérée : elle n'est dans l'UKI qu'après sudo rago-update uki (M4)"
	fi
	log "installation terminée ; vérification :"
	local rc=0
	step_verify || rc=$?
	case "$rc" in
	0) log "tout est en place" ;;
	3) log "tout est en place sauf ce qui attend un redémarrage" ;;
	*) warn "des points sont en échec (voir ci-dessus)" ;;
	esac
	return 0
}

# =====================================================================================
# verify
# =====================================================================================
verify_volume() { # verify_volume <rôle affiché> <uuid> <root-a|root-b|swap>
	local role=$1 u=$2 key=$3 d sum list npw ntpm tokpcrs
	d=$(dev_by_uuid "$u" 2>/dev/null) || { ko "$role : volume UUID=$u introuvable"; return; }
	sum=$(luks_dump "$d" | rago_luks_summary)
	if grep -qx 'version 2' <<<"$sum"; then ok "$role ($d) : LUKS2"; else ko "$role ($d) : pas LUKS2"; return; fi
	if grep -qx "cipher $RAGO_LUKS_CIPHER" <<<"$sum"; then ok "$role : $RAGO_LUKS_CIPHER"; else ko "$role : chiffrement $(sed -n 's/^cipher //p' <<<"$sum") (attendu $RAGO_LUKS_CIPHER)"; fi
	if grep -Eq "^keyslot [0-9]+ $RAGO_LUKS_KEY_SIZE $RAGO_LUKS_PBKDF $RAGO_LUKS_HASH\$" <<<"$sum"; then
		ok "$role : clé $RAGO_LUKS_KEY_SIZE bits, passphrase en $RAGO_LUKS_PBKDF, $RAGO_LUKS_HASH"
	else
		ko "$role : aucun emplacement $RAGO_LUKS_KEY_SIZE bits / $RAGO_LUKS_PBKDF / $RAGO_LUKS_HASH"
	fi
	list=$(enroll_list "$d")
	npw=$(rago_slots_count "$list" password)
	ntpm=$(rago_slots_count "$list" tpm2)
	if [ "$npw" -ge 1 ]; then ok "$role : passphrase de secours présente ($npw)"; else ko "$role : AUCUNE passphrase de secours : le TPM est le seul moyen d'ouvrir ce volume (DANGER : cryptsetup luksAddKey $d)"; fi
	if [ "$AB" = 1 ]; then
		verify_tokens_ab "$role" "$key" "$d"
		return
	fi
	if [ "$ntpm" -eq 1 ]; then
		tokpcrs=$(awk '$1 == "token" && $3 == "systemd-tpm2" { print $5; exit }' <<<"$sum")
		if [ "$(rago_pcrs_normalize "$tokpcrs" 2>/dev/null)" = "$PCRS" ]; then ok "$role : TPM enrôlé (PCR $tokpcrs)"; else att "$role : TPM enrôlé sur les PCR $tokpcrs (réglage : $PCRS)"; fi
		case "$(tpm_unseal_test "$d"; echo $?)" in
		0) ok "$role : le TPM ouvre le volume avec les PCR actuels" ;;
		1) ko "$role : le TPM REFUSE avec les PCR actuels (firmware / Secure Boot changé ?) : passphrase au démarrage ; sudo rago-encryption reseal" ;;
		*) skip "$role : test d'ouverture par le TPM impossible ici" ;;
		esac
	elif [ "$ntpm" -eq 0 ]; then
		att "$role : TPM pas enrôlé : passphrase à chaque démarrage (sudo rago-encryption enroll-tpm)"
	else
		att "$role : $ntpm enrôlements TPM (1 attendu : sudo rago-encryption reseal)"
	fi
}

# M4 : chaque entrée de démarrage qui ouvre ce volume a-t-elle son jeton ?
verify_tokens_ab() { # verify_tokens_ab <rôle affiché> <root-a|root-b|swap> <volume>
	local name=$1 key=$2 d=$3 exp toks pol spec ids stale has_base=0 st
	if [ -z "$AB_TABLE" ]; then skip "$name : jetons TPM non contrôlés (pas d'entrée de démarrage lue)"; return; fi
	exp=$(ab_expected "$key") || { ko "$name : politique TPM incalculable"; return; }
	toks=$(ab_tokens "$d")
	[ -n "$exp" ] || att "$name : aucune entrée de démarrage Rago ne l'ouvre (slot pas encore installé ?)"
	while read -r pol spec ids; do
		[ -n "$pol" ] || continue
		case "$spec" in *:sha256=*) ;; *) has_base=1 ;; esac
		if has_policy "$pol" "$toks"; then
			case "$spec" in
			*:sha256=*) ok "$name : jeton TPM à jour pour $ids (PCR $PCRS + 11 de l'UKI)" ;;
			*) ok "$name : jeton TPM à jour pour $ids (PCR $PCRS)" ;;
			esac
		else
			ko "$name : pas de jeton TPM pour $ids (firmware / Secure Boot changé, ou UKI pas re-scellée) : passphrase au démarrage par cette entrée ; sudo rago-encryption reseal"
		fi
	done <<<"$exp"
	stale=$(awk -v e="$(awk '{ print $1 }' <<<"$exp" | tr '\n' ' ')" 'BEGIN { n = split(e, a, " "); for (i = 1; i <= n; i++) k[a[i]] = 1 } NF && !($4 in k) { c++ } END { print c + 0 }' <<<"$toks")
	[ "$stale" = 0 ] || att "$name : $stale jeton(s) TPM qui ne servent plus (anciennes UKI ou anciens PCR) : sudo rago-encryption prune-tpm"
	if [ "$has_base" = 1 ]; then
		st=0
		tpm_unseal_test "$d" || st=$?
		case "$st" in
		0) ok "$name : le TPM ouvre le volume avec les PCR actuels (jeton PCR $PCRS)" ;;
		1) ko "$name : le TPM REFUSE avec les PCR actuels (jeton PCR $PCRS)" ;;
		*) skip "$name : test d'ouverture par le TPM impossible ici" ;;
		esac
	elif [ -n "$exp" ]; then
		skip "$name : jetons liés à PCR 11 : le TPM ne les descelle que dans l'initramfs (barrière de systemd), contrôle par leur politique"
	fi
}

verify_crypttab() {
	local e opts bad name u
	for name in "$RAGO_MAP_ROOT" "$RAGO_MAP_SWAP"; do
		if [ "$name" = "$RAGO_MAP_ROOT" ]; then u=$(this_root_uuid); else u=$SWAP_UUID; [ -n "$u" ] || continue; fi
		e=$(rago_crypttab_entry "$R$P_CRYPTTAB" "$name" || true)
		if [ -z "$e" ]; then ko "crypttab : pas d'entrée $name"; continue; fi
		# shellcheck disable=SC2086  # découpage voulu
		set -- $e
		[ "$2" = "UUID=$u" ] || [ "$2" = "/dev/disk/by-uuid/$u" ] || ko "crypttab : $name vise $2 (attendu UUID=$u)"
		opts=$4
		case ",$opts," in *,tpm2-device=*) ok "crypttab : $name ($2, ${opts%%,*})" ;; *) ko "crypttab : $name sans tpm2-device=" ;; esac
		[ "$3" = none ] || [ "$3" = - ] || ko "crypttab : $name a un fichier de clé ($3) : il contournerait le TPM"
		bad=$(rago_crypttab_bad_options "$opts")
		[ -z "$bad" ] || ko "crypttab : $name a l'option « $bad » : le volume serait effacé à chaque démarrage (image d'hibernation perdue)"
		e=$(rago_crypttab_entry "$R$P_CRYPTTAB_INITRAMFS" "$name" || true)
		if [ -z "$e" ]; then
			ko "crypttab.initramfs : pas d'entrée $name (relancer install)"
		else
			# shellcheck disable=SC2086  # découpage voulu
			set -- $e
			if [ "$2" = "UUID=$u" ] || [ "$2" = "/dev/disk/by-uuid/$u" ]; then ok "crypttab.initramfs : $name"; else ko "crypttab.initramfs : $name vise $2 (attendu UUID=$u)"; fi
		fi
	done
	if [ -n "$SWAP_UUID" ]; then
		if awk -v d="/dev/mapper/$RAGO_MAP_SWAP" '!/^[[:space:]]*#/ && $1 == d && $3 == "swap"' "$R$P_FSTAB" 2>/dev/null | grep -q .; then
			ok "fstab : swap /dev/mapper/$RAGO_MAP_SWAP"
		else
			ko "fstab : pas de swap /dev/mapper/$RAGO_MAP_SWAP"
		fi
	fi
}

verify_initramfs_conf() {
	local h why
	case "$GEN" in
	dracut)
		if is_ours "$R$P_DRACUT"; then ok "dracut : $P_DRACUT"; else ko "dracut : $P_DRACUT absent (install)"; fi
		if [ -f "$R$P_DRACUT_MOD" ]; then ok "dracut : module rago-crypttab"; else ko "dracut : module rago-crypttab absent (install)"; fi ;;
	mkinitcpio)
		if is_ours "$R$P_MKINIT"; then ok "mkinitcpio : $P_MKINIT"; else ko "mkinitcpio : $P_MKINIT absent (install)"; fi
		h=$(mkinitcpio_hooks_effective)
		# shellcheck disable=SC2086
		if why=$(rago_mkinitcpio_hooks_ok $h); then ok "mkinitcpio : HOOKS=($h)"; else ko "mkinitcpio : $why — HOOKS=($h)"; fi ;;
	*) ko "initramfs : $GEN non pris en charge" ;;
	esac
}

verify_initramfs_images() {
	local k img lst miss builtin ct n=0 u
	lst=$(mktemp)
	while read -r k img; do
		[ -n "$k" ] || continue
		n=$((n + 1))
		if [ ! -e "$R$img" ]; then ko "initramfs $img (noyau $k) absente"; continue; fi
		if [ -n "$R" ]; then skip "initramfs $img : contenu non lu (--root)"; continue; fi
		if ! initramfs_list "$img" > "$lst"; then skip "initramfs $img : lsinitrd / lsinitcpio absent"; continue; fi
		builtin="$R/usr/lib/modules/$k/modules.builtin"
		miss=$(rago_initramfs_missing "$lst" "$([ -n "$SWAP_UUID" ] && echo 1 || echo 0)" "$builtin")
		if [ -z "$miss" ]; then ok "initramfs $img : systemd-cryptsetup, TPM2, dm-crypt$([ -n "$SWAP_UUID" ] && echo ", resume")"; else ko "initramfs $img : manque $miss (relancer install)"; fi
		ct=$(initramfs_file "$img" etc/crypttab)
		for u in "$(this_root_uuid)" "$SWAP_UUID"; do
			[ -n "$u" ] || continue
			if grep -q "$u" <<<"$ct"; then ok "initramfs $img : crypttab ouvre UUID=$u"; else ko "initramfs $img : sa crypttab n'a pas UUID=$u (relancer install)"; fi
		done
	done < <(initramfs_images)
	rm -f "$lst"
	[ "$n" -gt 0 ] || ko "aucune initramfs trouvée"
}

verify_cmdline() {
	local cl kc want t base extra
	want=$(rago_enc_cmdline "$([ -n "$SWAP_UUID" ] && echo 1 || echo 0)")
	cl=$(cat "$PROC/cmdline" 2>/dev/null || true)
	kc="$R$P_KCONF"
	for t in $want; do
		if [ -z "$R" ] && rago_cmdline_has "$cl" "$t"; then
			ok "démarrage : $t"
		elif [ -f "$kc" ]; then
			base=$(rago_conf_get "$kc" RAGO_CMDLINE "")
			extra=$(rago_conf_get "$kc" RAGO_CMDLINE_EXTRA "")
			if rago_cmdline_has "$base $extra" "$t"; then
				if [ -n "$R" ]; then ok "$P_KCONF : $t"; else boot "démarrage : $t est dans $P_KCONF, pas encore actif (build_rago_kernel.sh bootloader + redémarrer)"; fi
			else
				ko "démarrage : $t absent (ni actif, ni dans $P_KCONF)"
			fi
		else
			att "démarrage : $t absent (noyau Rago M0 pas installé ? l'ajouter au chargeur de démarrage)"
		fi
	done
}

verify_live() {
	local src name slave u swapdev res mm pend good lock
	src=$(findmnt -no SOURCE / 2>/dev/null || true)
	name=$(basename "$(readlink -f "$src" 2>/dev/null)")
	slave=$(first_slave "$name")
	u=""
	[ -z "$slave" ] || u=$(luks_uuid "/dev/$slave")
	if [ -n "$u" ] && [ "$u" = "$(this_root_uuid)" ]; then ok "racine : $src sur le volume chiffré du slot ${SLOT:-a}"; else ko "racine : $src n'est pas le volume chiffré du slot ${SLOT:-a}"; fi
	[ -n "$SWAP_UUID" ] || return 0
	# Nouvelle ligne de commande pas encore active (install juste fait) : swap et
	# resume arrivent au redémarrage, ce n'est pas un échec.
	pend=0
	rago_cmdline_has "$(cat "$PROC/cmdline" 2>/dev/null || true)" "resume=/dev/mapper/$RAGO_MAP_SWAP" || pend=1
	swapdev=$(readlink -f "/dev/mapper/$RAGO_MAP_SWAP" 2>/dev/null || true)
	good=0
	if [ -n "$swapdev" ] && awk 'NR > 1 { print $1 }' "$PROC/swaps" | xargs -r readlink -f | grep -qx "$swapdev"; then good=1; fi
	case "$(rago_live_verdict "$good" "$pend")" in
	ok) ok "swap chiffré actif ($swapdev)" ;;
	boot) boot "swap chiffré /dev/mapper/$RAGO_MAP_SWAP : actif après le redémarrage" ;;
	*) ko "swap chiffré /dev/mapper/$RAGO_MAP_SWAP pas actif" ;;
	esac
	if ! rago_hibernation_available "$(cat "$SYS/power/state" 2>/dev/null || true)"; then
		lock=$(rago_lockdown_mode "$(cat "$SYS/kernel/security/lockdown" 2>/dev/null || true)" || true)
		case "$lock" in
		integrity | confidentiality)
			att "hibernation impossible : noyau verrouillé (lockdown $lock, imposé sous Secure Boot par certains noyaux de distribution) ; le Fast OS Switch (M6) en a besoin" ;;
		*) att "hibernation impossible avec ce noyau (« disk » absent de $SYS/power/state : nohibernate ?) ; le Fast OS Switch (M6) en a besoin" ;;
		esac
		return 0
	fi
	res=$(cat "$SYS/power/resume" 2>/dev/null || true)
	mm=""
	[ -z "$swapdev" ] || mm=$(cat "$SYS/class/block/$(basename "$swapdev")/dev" 2>/dev/null || true)
	good=0
	if [ -n "$mm" ] && [ "$res" = "$mm" ]; then good=1; fi
	case "$(rago_live_verdict "$good" "$pend")" in
	ok) ok "hibernation : resume depuis le swap chiffré ($res)" ;;
	boot) boot "hibernation : resume vers le swap chiffré après le redémarrage" ;;
	*) att "hibernation : /sys/power/resume = ${res:-?} (swap chiffré : ${mm:-?})" ;;
	esac
	awk 'NR > 1 { print $1 }' "$PROC/swaps" | while read -r s; do
		case "$s" in /dev/zram* | /dev/dm-* | /dev/mapper/*) ;; *) echo "$s" ;; esac
	done | while read -r s; do att "swap NON chiffré actif : $s (la mémoire y est écrite en clair)"; done
}

verify_pcrs() {
	local f cur changed
	f=$(state pcrs-at-enroll)
	[ -f "$f" ] || return 0
	cur=$(mktemp)
	read_pcrs > "$cur" 2>/dev/null || true
	if [ -s "$cur" ]; then
		changed=$(rago_pcr_changed <(grep -v '^#' "$f") "$cur")
		if [ -z "$changed" ]; then ok "PCR $PCRS identiques à l'enrôlement"; else ko "PCR $changed changés depuis l'enrôlement (mise à jour firmware / Secure Boot) : sudo rago-encryption reseal"; fi
	else
		skip "PCR actuels illisibles : comparaison avec l'enrôlement impossible"
	fi
	rm -f "$cur"
}

step_verify() {
	load_settings
	GEN=$(detect_initramfs)
	n_ok=0 n_fail=0 n_warn=0 n_boot=0 n_skip=0
	printf 'Rago OS — vérification du chiffrement (M3)\n'
	if is_ours "$R$P_CONF"; then ok "réglages : $P_CONF (slot ${SLOT:-?})"; else ko "réglages : $P_CONF absent (install)"; bilan; return; fi
	# Volumes : toujours sur le système vivant ; avec --root (installateur,
	# tests), ceux qui sont branchés.
	local role u key
	load_ab
	if [ "$AB" = 1 ]; then
		PCRV=$(read_pcrs 2>/dev/null || true)
		if [ ! -d "$ESPDIR" ]; then
			ko "M4 : ESP introuvable ($ESPDIR) : jetons TPM des entrées de démarrage non contrôlés"
		elif [ -z "$PCRV" ]; then
			skip "M4 : PCR $PCRS illisibles : jetons TPM des entrées de démarrage non contrôlés"
		else
			ab_build_table
			if [ -n "$AB_TABLE" ]; then ok "M4 : entrées de démarrage : $(awk '{ printf "%s%s", s, $1; s = ", " }' <<<"$AB_TABLE")"; else ko "M4 : aucune entrée de démarrage Rago dans $ESPDIR"; fi
		fi
	fi
	for role in "slot A" "slot B" "swap"; do
		case "$role" in "slot A") u=$ROOT_A_UUID; key="root-a" ;; "slot B") u=$ROOT_B_UUID; key="root-b" ;; *) u=$SWAP_UUID; key=swap ;; esac
		[ -n "$u" ] || continue
		if [ -n "$R" ] && ! dev_by_uuid "$u" >/dev/null 2>&1; then skip "$role : volume UUID=$u pas branché (--root)"; continue; fi
		verify_volume "$role" "$u" "$key"
	done
	verify_crypttab
	verify_initramfs_conf
	verify_initramfs_images
	verify_cmdline
	verify_pcrs
	if [ -z "$R" ]; then
		# Dans le chroot de l'installateur, le nouveau système n'a pas encore démarré.
		if in_chroot; then
			skip "dans un chroot (installateur) : racine, swap et hibernation se vérifient au premier démarrage (sudo rago-encryption verify)"
		else
			verify_live
		fi
		cpu_report ok att
		case "$(secure_boot_state)" in
		on) ok "Secure Boot actif" ;;
		off) att "Secure Boot inactif : l'activer changera PCR 7 (passphrase puis reseal)" ;;
		esac
	fi
	bilan
}

# =====================================================================================
# tpm-check (service rago-tpm-check, après le démarrage)
# =====================================================================================
step_tpm_check() {
	need_root tpm-check
	load_settings
	local u role d list rc=0 report="" st n_ref=0 n_good=0 abok=0 key exp miss
	[ -f "$R$P_CONF" ] || { log "pas de volume Rago ($P_CONF absent)"; return 4; }
	load_ab
	if [ "$AB" = 1 ]; then
		PCRV=$(read_pcrs 2>/dev/null || true)
		if [ -n "$PCRV" ] && [ -d "$ESPDIR" ]; then ab_build_table 2>/dev/null; abok=1; fi
	fi
	for role in a b swap; do
		case "$role" in a) u=$ROOT_A_UUID ;; b) u=$ROOT_B_UUID ;; swap) u=$SWAP_UUID ;; esac
		[ -n "$u" ] || continue
		d=$(dev_by_uuid "$u" 2>/dev/null) || { report="$report${role}=absent"$'\n'; continue; }
		list=$(enroll_list "$d")
		if [ "$(rago_slots_count "$list" tpm2)" -eq 0 ]; then report="$report${role}=not-enrolled"$'\n'; continue; fi
		st=0
		if [ "$AB" = 1 ]; then
			# M4 : jetons liés à PCR 11 (pas de test de descellement possible ici) :
			# un jeton par entrée de démarrage, aux PCR actuels ?
			if [ "$abok" = 0 ]; then
				st=2
			else
				case "$role" in a) key="root-a" ;; b) key="root-b" ;; *) key=swap ;; esac
				# Politique incalculable = « untestable », jamais « no-entry » ni « ok ».
				if ! exp=$(ab_expected "$key"); then
					st=2
				elif [ -z "$exp" ]; then
					report="$report${role}=no-entry"$'\n'
					continue
				elif ! miss=$(ab_missing "$key" "$d"); then
					st=2
				elif [ "$miss" = 0 ]; then
					st=0
				else
					st=1
				fi
			fi
		else
			tpm_unseal_test "$d" || st=$?
		fi
		case "$st" in
		0) report="$report${role}=ok"$'\n'; n_good=$((n_good + 1)) ;;
		1) report="$report${role}=refused"$'\n'; n_ref=$((n_ref + 1)) ;;
		*) report="$report${role}=untestable"$'\n' ;;
		esac
	done
	if [ "$dry_run" = 0 ]; then
		mkdir -p "$(dirname "$R$P_RUNSTATUS")"
		{
			printf '# Rago OS — état du déverrouillage TPM (module M3), %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			printf '%s' "$report"
		} > "$R$P_RUNSTATUS"
	fi
	if [ "$n_ref" -gt 0 ] && [ "$AB" = 1 ]; then
		warn "$n_ref volume(s) Rago sans jeton TPM pour chaque entrée de démarrage : firmware ou Secure Boot"
		warn "changé, ou nouvelle UKI pas re-scellée. La passphrase de secours est demandée par ces entrées."
		warn "Pour retrouver le déverrouillage automatique : sudo rago-encryption reseal"
		rc=1
	elif [ "$n_ref" -gt 0 ]; then
		warn "le TPM refuse $n_ref volume(s) Rago avec les PCR actuels : le firmware ou Secure Boot a changé."
		warn "La passphrase de secours a servi à ce démarrage. Pour retrouver le déverrouillage automatique :"
		warn "  sudo rago-encryption reseal"
		rc=1
	elif [ "$n_good" -gt 0 ]; then
		log "le TPM déverrouille les volumes Rago ($n_good)"
	else
		log "TPM pas enrôlé ou pas testable"
		rc=4
	fi
	printf '%s' "$report" | sed 's/^/  /'
	return "$rc"
}

# =====================================================================================
# cmdline (pour M4 : entrées systemd-boot des slots A et B)
# =====================================================================================
step_cmdline() {
	load_settings
	[ -f "$R$P_CONF" ] || die "pas de $P_CONF : lancer install"
	case "${o_slot:-$SLOT}" in
	b) [ -n "$ROOT_B_UUID" ] || die "slot B non configuré" ;;
	*) [ -n "$ROOT_A_UUID" ] || die "slot A non configuré" ;;
	esac
	rago_enc_cmdline "$([ -n "$SWAP_UUID" ] && echo 1 || echo 0)"
}

# =====================================================================================
# deps
# =====================================================================================
step_deps() {
	need_root deps
	[ -z "$R" ] || die "deps ne marche pas avec --root"
	local p pkgs=""
	if have pacman; then
		# Arch : systemd-cryptenroll et systemd-cryptsetup sont dans systemd.
		run pacman -S --needed --noconfirm cryptsetup tpm2-tss tpm2-tools
	elif have apt-get; then
		for p in cryptsetup cryptsetup-bin systemd-cryptsetup tpm2-tools dracut; do
			apt-cache show "$p" >/dev/null 2>&1 && pkgs="$pkgs $p"
		done
		[ -x /usr/bin/dracut ] || warn "dracut remplace initramfs-tools (qui ne sait pas déverrouiller par TPM2)"
		# shellcheck disable=SC2086
		run apt-get install -y $pkgs
	else
		die "ni pacman ni apt-get : installe cryptsetup, tpm2-tss, tpm2-tools et dracut ou mkinitcpio à la main"
	fi
}

case "$cmd" in
check) step_check ;;
format) step_format ;;
open) step_open ;;
close) step_close ;;
enroll-tpm | reseal) step_enroll ;;
prune-tpm) step_prune ;;
install) step_install ;;
verify | status) step_verify ;;
tpm-check) step_tpm_check ;;
cmdline) step_cmdline ;;
deps) step_deps ;;
esac
