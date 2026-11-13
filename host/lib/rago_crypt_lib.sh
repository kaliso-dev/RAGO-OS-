# SPDX-License-Identifier: GPL-2.0
# shellcheck shell=bash
#
# Rago OS — fonctions pures du chiffrement LUKS2 + TPM2 (module M3).
#
# Aucune de ces fonctions ne touche au système ni à un disque : elles lisent
# des fichiers ou des chaînes et écrivent sur la sortie standard. Utilisées
# par host/setup_secure_encryption.sh et testées par
# host/tests/test_crypt_lib.sh.

# Marqueur présent dans chaque fichier (ou bloc) écrit par M3 : ce qui le
# contient est « à nous ».
# shellcheck disable=SC2034  # utilisé par setup_secure_encryption.sh
RAGO_ENC_MARKER="rago-secure-encryption"

# Paramètres LUKS2 imposés par Rago (bible v7, module M3).
# shellcheck disable=SC2034
RAGO_LUKS_CIPHER="aes-xts-plain64"
# shellcheck disable=SC2034
RAGO_LUKS_KEY_SIZE=512
# shellcheck disable=SC2034
RAGO_LUKS_HASH="sha512"
# shellcheck disable=SC2034
RAGO_LUKS_PBKDF="argon2id"

# Noms des volumes ouverts au démarrage (identiques pour les slots A et B :
# chaque slot a sa propre crypttab, qui nomme SON volume « rago-root »).
# shellcheck disable=SC2034
RAGO_MAP_ROOT="rago-root"
# shellcheck disable=SC2034
RAGO_MAP_SWAP="rago-swap"

# Longueur minimale de la passphrase de secours.
# shellcheck disable=SC2034
RAGO_PASS_MIN=12

# --- processeur ------------------------------------------------------------------
# Drapeaux du premier processeur de /proc/cpuinfo (une ligne, séparés par des espaces).
#   rago_cpu_flags <fichier cpuinfo>
rago_cpu_flags() {
	sed -n 's/^flags[[:space:]]*:[[:space:]]*//p' "$1" 2>/dev/null | head -1
}

# Drapeau présent ?  rago_flag_has <drapeaux> <drapeau>
rago_flag_has() {
	local f
	for f in $1; do
		[ "$f" = "$2" ] && return 0
	done
	return 1
}

# Pilote noyau prioritaire pour xts(aes), lu dans /proc/crypto
# (ex. « xts-aes-vaes-avx2 », « xts-aes-aesni », « xts(ecb(aes-generic)) »).
#   rago_xts_driver <fichier /proc/crypto>
rago_xts_driver() {
	awk '
		/^name[[:space:]]*:/ { sub(/^name[[:space:]]*:[[:space:]]*/, ""); name = $0; next }
		/^driver[[:space:]]*:/ { sub(/^driver[[:space:]]*:[[:space:]]*/, ""); drv = $0; next }
		/^priority[[:space:]]*:/ {
			sub(/^priority[[:space:]]*:[[:space:]]*/, "")
			if (name == "xts(aes)" && ($0 + 0) > best) { best = $0 + 0; pick = drv }
			next
		}
		END { if (pick != "") print pick; else exit 1 }
	' "$1" 2>/dev/null
}

# Le pilote xts(aes) est-il accéléré (instructions AES du processeur) ?
rago_xts_driver_accelerated() {
	case "$1" in
	*aesni* | *vaes* | *avx* | *aes-ce* | *aes-neonbs*) return 0 ;;
	*) return 1 ;;
	esac
}

# --- passphrase de secours --------------------------------------------------------
# Code retour :
#   0 bonne ; 1 trop courte (< RAGO_PASS_MIN) ; 2 caractère de contrôle (retour
#   à la ligne, tabulation...) : impossible à taper au démarrage ;
#   3 caractère non ASCII (é, à, ç...) : acceptée, mais à éviter (au démarrage
#   le clavier peut être en QWERTY) — l'appelant avertit.
#   rago_passphrase_check <passphrase>
rago_passphrase_check() {
	local p=$1 n=${#1}
	local LC_ALL=C
	case "$p" in *[[:cntrl:]]*) return 2 ;; esac
	[ "$n" -ge "$RAGO_PASS_MIN" ] || return 1
	case "$p" in *[![:print:]]*) return 3 ;; esac
	return 0
}

# Retire UN retour à la ligne final (\n ou \r\n) : un fichier écrit avec
# « echo » ne doit pas donner une passphrase différente de celle tapée au
# clavier au démarrage.
#   rago_strip_newline <chaîne>
rago_strip_newline() {
	local s=$1
	s=${s%$'\n'}
	s=${s%$'\r'}
	printf '%s' "$s"
}

# --- PCR ---------------------------------------------------------------------------
# « 0+7 », « 0,7 », « 7+0 », « 07 » refusé -> forme normale « 0+7 » (triée,
# sans doublon). Code 1 si invalide (PCR 0 à 23).
#   rago_pcrs_normalize <liste>
rago_pcrs_normalize() {
	local s=$1 p out=""
	[ -n "$s" ] || return 1
	case "$s" in *[!0-9+,]* | [+,]* | *[+,] | *[+,][+,]*) return 1 ;; esac
	for p in ${s//[+,]/ }; do
		case "$p" in 0?*) return 1 ;; esac
		[ "$p" -le 23 ] || return 1
	done
	# shellcheck disable=SC2086  # découpage voulu
	for p in $(printf '%s\n' ${s//[+,]/ } | sort -n -u); do
		out="$out+$p"
	done
	echo "${out#+}"
}

# « 0+7 » -> « 0,7 » (syntaxe de tpm2_pcrread).
rago_pcrs_comma() { echo "${1//+/,}"; }

# Valeur de PCR vide ? (que des 0, ou que des F : jamais étendu / non mesuré)
#   rago_pcr_is_unmeasured <hexa>
rago_pcr_is_unmeasured() {
	local v=${1#0x}
	v=${v#0X}
	[ -n "$v" ] || return 0
	case "$v" in *[!0]*) ;; *) return 0 ;; esac
	case "$v" in *[!fF]*) return 1 ;; *) return 0 ;; esac
}

# Sortie de « tpm2_pcrread sha256:0,7 » -> lignes « <pcr> <hexa minuscule> ».
rago_pcrread_parse() {
	awk '
		/^[[:space:]]*sha[0-9]+:/ { next }
		/^[[:space:]]*[0-9]+[[:space:]]*:[[:space:]]*0x[0-9A-Fa-f]+/ {
			split($0, a, ":"); n = a[1]; v = a[2]
			gsub(/[[:space:]]/, "", n); gsub(/[[:space:]]/, "", v)
			sub(/^0[xX]/, "", v)
			print n, tolower(v)
		}
	'
}

# Compare deux relevés « <pcr> <hexa> » (fichier enregistré à l'enrôlement,
# relevé actuel) : affiche les numéros de PCR qui ont changé (vide = aucun).
#   rago_pcr_changed <fichier enregistré> <fichier actuel>
rago_pcr_changed() {
	awk '
		NR == FNR { old[$1] = $2; next }
		($1 in old) && old[$1] != $2 { printf "%s%s", sep, $1; sep = "+" }
		END { if (sep != "") print "" }
	' "$1" "$2"
}

# --- luksDump / systemd-cryptenroll -----------------------------------------------
# Résume « cryptsetup luksDump » (cryptsetup 2.4 à 2.8) en lignes simples :
#   version <n>
#   uuid <uuid>
#   label <étiquette ou vide>
#   cipher <chiffrement du segment 0>
#   sector <taille de secteur>
#   keyslot <n> <bits> <pbkdf> <af-hash>
#   token <id> <type> <keyslots séparés par ,> <pcrs ou ->
#   digest-hash <hash>
rago_luks_summary() {
	awk '
		function flush_slot() {
			if (slot != "") print "keyslot", slot, (bits == "" ? "?" : bits), (pbkdf == "" ? "?" : pbkdf), (afh == "" ? "?" : afh)
			slot = ""; bits = ""; pbkdf = ""; afh = ""
		}
		function flush_tok() {
			if (tok != "") print "token", tok, ttype, (tks == "" ? "-" : tks), (tpcr == "" ? "-" : tpcr)
			tok = ""; ttype = ""; tks = ""; tpcr = ""
		}
		/^Version:/ { print "version", $2; next }
		/^UUID:/ { print "uuid", $2; next }
		/^Label:/ {
			l = $0; sub(/^Label:[[:space:]]*/, "", l)
			if (l == "(no label)") l = ""
			print "label", l; next
		}
		/^Data segments:/ { sec = "seg"; next }
		/^Keyslots:/ { sec = "ks"; next }
		/^Tokens:/ { flush_slot(); sec = "tok"; next }
		/^Digests:/ { flush_slot(); flush_tok(); sec = "dig"; next }
		sec == "seg" && /^[[:space:]]+cipher:/ && !seen_cipher { print "cipher", $2; seen_cipher = 1; next }
		sec == "seg" && /^[[:space:]]+sector:/ && !seen_sector { print "sector", $2; seen_sector = 1; next }
		sec == "ks" && /^[[:space:]]+[0-9]+: luks2/ { flush_slot(); s = $1; sub(/:$/, "", s); slot = s; next }
		sec == "ks" && /^[[:space:]]+Key:/ { bits = $2; next }
		sec == "ks" && /^[[:space:]]+PBKDF:/ { pbkdf = $2; next }
		sec == "ks" && /^[[:space:]]+AF hash:/ { afh = $3; next }
		sec == "tok" && /^[[:space:]]+[0-9]+: / { flush_tok(); t = $1; sub(/:$/, "", t); tok = t; ttype = $2; next }
		sec == "tok" && /^[[:space:]]+tpm2-hash-pcrs:/ { tpcr = $2; next }
		sec == "tok" && /^[[:space:]]+tpm2-pcrs:/ { if (tpcr == "") tpcr = $2; next }
		sec == "tok" && /^[[:space:]]+Keyslot:/ { tks = (tks == "" ? $2 : tks "," $2); next }
		sec == "dig" && /^[[:space:]]+Hash:/ && !seen_dh { print "digest-hash", $2; seen_dh = 1; next }
		END { flush_slot(); flush_tok() }
	'
}

# Sortie de « systemd-cryptenroll <volume> » (« SLOT TYPE ») -> « <slot> <type> ».
rago_enroll_list_parse() {
	awk '
		/^[[:space:]]*SLOT[[:space:]]+TYPE/ { on = 1; next }
		on && /^[[:space:]]*[0-9]+[[:space:]]+[a-z0-9-]+/ { print $1, $2 }
	'
}

# Nombre de lignes d'un type dans la sortie de rago_enroll_list_parse.
#   rago_slots_count <liste> <type>
rago_slots_count() {
	local n=0 s t
	while read -r s t; do
		[ -n "$s" ] || continue
		[ "$t" = "$2" ] && n=$((n + 1))
	done <<<"$1"
	echo "$n"
}

# --- crypttab ------------------------------------------------------------------------
# Options crypttab de Rago :
#   tpm2-device=auto : TPM d'abord, sinon la passphrase est demandée (secours) ;
#   discard : TRIM du SSD (révèle seulement quels blocs sont libres) ;
#   no-read-workqueue / no-write-workqueue : latence plus basse sur SSD / NVMe ;
#   x-initrd.attach : ouvert dans l'initramfs (racine, et swap avant le resume).
#   rago_crypttab_options <discard 0|1>
rago_crypttab_options() {
	local o="tpm2-device=auto"
	[ "$1" = 1 ] && o="$o,discard"
	echo "$o,no-read-workqueue,no-write-workqueue,x-initrd.attach"
}

# Options interdites pour un volume Rago : « swap » / « tmp » recréent le volume
# (clé aléatoire) à chaque démarrage, l'image d'hibernation serait détruite ;
# « plain » casserait LUKS ; un fichier de clé contournerait le TPM.
#   rago_crypttab_bad_options <options>  -> affiche les options fautives
rago_crypttab_bad_options() {
	local o out=""
	for o in ${1//,/ }; do
		case "$o" in swap | tmp | tmp=* | plain | luks=no) out="$out $o" ;; esac
	done
	echo "${out# }"
}

#   rago_crypttab_line <nom> <uuid> <options>
rago_crypttab_line() {
	printf '%-10s UUID=%s none %s\n' "$1" "$2" "$3"
}

# Champs d'une entrée crypttab (sans commentaires) : « nom périphérique clé options ».
#   rago_crypttab_entry <fichier> <nom>
rago_crypttab_entry() {
	awk -v n="$2" '
		/^[[:space:]]*(#|$)/ { next }
		$1 == n { print $1, $2, ($3 == "" ? "-" : $3), ($4 == "" ? "-" : $4); found = 1; exit }
		END { if (!found) exit 1 }
	' "$1" 2>/dev/null
}

# Contenu d'une crypttab où les entrées Rago sont remplacées par celles
# données. Une entrée existante est retirée si elle porte le même nom OU vise le
# même volume (UUID=… ou /dev/disk/by-uuid/…) : deux entrées pour un volume
# feraient deux ouvertures concurrentes. Tout le reste (entrées du joueur,
# commentaires) est gardé. Chaque entrée Rago est précédée d'une ligne
# « # rago-secure-encryption : … ».
#   rago_crypttab_merge <fichier ou /dev/null> <ligne crypttab>...
rago_crypttab_merge() {
	local file=$1 l names="" devs="" dev
	shift
	[ -r "$file" ] || file=/dev/null # pas encore de crypttab (Ubuntu) : vide
	for l in "$@"; do
		names="$names ${l%% *}"
		dev=$(echo "$l" | awk '{ print $2 }')
		devs="$devs $dev"
		case "$dev" in UUID=*) devs="$devs /dev/disk/by-uuid/${dev#UUID=}" ;; esac
	done
	awk -v names="$names" -v devs="$devs" -v marker="$RAGO_ENC_MARKER" '
		BEGIN {
			n = split(names, a, " "); for (i = 1; i <= n; i++) ours[a[i]] = 1
			n = split(devs, b, " "); for (i = 1; i <= n; i++) ourdev[tolower(b[i])] = 1
		}
		index($0, "# " marker) == 1 { next }
		/^[[:space:]]*(#|$)/ { print; next }
		($1 in ours) { next }
		(tolower($2) in ourdev) { next }
		{ print }
	' "$file"
	for l in "$@"; do
		printf '# %s : volume %s (module M3 ; ne pas ajouter « swap » / « tmp » ni de fichier de clé)\n' "$RAGO_ENC_MARKER" "${l%% *}"
		printf '%s\n' "$l"
	done
}

# Retire les entrées Rago (lignes marquées et entrées aux noms donnés).
#   rago_crypttab_remove <fichier> <nom>...
rago_crypttab_remove() {
	local file=$1
	shift
	[ -r "$file" ] || file=/dev/null
	awk -v names="$*" -v marker="$RAGO_ENC_MARKER" '
		BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) ours[a[i]] = 1 }
		index($0, "# " marker) == 1 { next }
		/^[[:space:]]*(#|$)/ { print; next }
		($1 in ours) { next }
		{ print }
	' "$file"
}

# --- fstab (swap d'hibernation) -----------------------------------------------
#   rago_fstab_swap_line <périphérique> <priorité>
rago_fstab_swap_line() {
	printf '%s none swap defaults,pri=%s 0 0\n' "$1" "$2"
}

# fstab avec l'entrée swap Rago : retire une entrée swap existante pour le même
# périphérique (ou pour l'UUID du swap, 4e argument facultatif), garde le reste.
#   rago_fstab_swap_merge <fichier ou /dev/null> <périphérique> <priorité> [UUID=…]
rago_fstab_swap_merge() {
	local file=$1
	[ -r "$file" ] || file=/dev/null
	awk -v dev="$2" -v alt="${4:-}" -v marker="$RAGO_ENC_MARKER" '
		index($0, "# " marker) == 1 { next }
		/^[[:space:]]*(#|$)/ { print; next }
		$3 == "swap" && ($1 == dev || (alt != "" && $1 == alt)) { next }
		{ print }
	' "$file"
	printf '# %s : swap chiffré de l'"'"'hibernation (Fast OS Switch, M6)\n' "$RAGO_ENC_MARKER"
	rago_fstab_swap_line "$2" "$3"
}

# Point de montage « / » et sa source dans un fstab (pour vérifier la racine).
#   rago_fstab_root_source <fichier>
rago_fstab_root_source() {
	awk '/^[[:space:]]*(#|$)/ { next } $2 == "/" { print $1; exit }' "$1" 2>/dev/null
}

# --- mkinitcpio -------------------------------------------------------------------
# HOOKS d'origine -> HOOKS systemd avec sd-encrypt (TPM2 + passphrase).
#   base reste en tête, systemd juste après (udev -> systemd) ;
#   encrypt -> sd-encrypt ; keymap / consolefont -> sd-vconsole (clavier du
#   joueur pour la passphrase) ; resume et usr retirés (systemd s'en charge : le
#   resume attend le swap déchiffré) ;
#   keyboard AVANT autodetect : tous les pilotes clavier, pour que la passphrase
#   de secours se tape même avec un autre clavier qu'à l'installation ;
#   sd-vconsole, block puis sd-encrypt avant le premier lvm2 / mdadm_udev /
#   btrfs / filesystems / fsck (qui ont besoin du volume ouvert).
#   rago_mkinitcpio_hooks <hook>...
rago_mkinitcpio_hooks() {
	local h list=() head=() pre=() post=() in_post=0 i out=()
	for h in "$@"; do
		case "$h" in
		udev) h=systemd ;;
		encrypt | sd-encrypt | resume | usr | keyboard | block) continue ;;
		keymap | consolefont) h=sd-vconsole ;;
		esac
		[ "$h" = sd-vconsole ] && continue
		case " ${list[*]} " in *" $h "*) continue ;; esac
		list+=("$h")
	done
	# base en tête, systemd juste après.
	case " ${list[*]} " in *" base "*) head+=(base) ;; esac
	head+=(systemd)
	for h in "${list[@]}"; do
		case "$h" in base | systemd) continue ;; esac
		case "$h" in lvm2 | mdadm_udev | btrfs | filesystems | fsck) in_post=1 ;; esac
		if [ "$in_post" = 1 ]; then post+=("$h"); else pre+=("$h"); fi
	done
	# keyboard avant autodetect, sinon juste après systemd.
	out=("${head[@]}")
	case " ${pre[*]} " in
	*" autodetect "*)
		for h in "${pre[@]}"; do
			[ "$h" = autodetect ] && out+=(keyboard)
			out+=("$h")
		done ;;
	*) out+=(keyboard "${pre[@]}") ;;
	esac
	out+=(sd-vconsole block sd-encrypt "${post[@]}")
	for i in "${!out[@]}"; do
		[ -n "${out[$i]}" ] || continue
		printf '%s' "${out[$i]}"
		[ "$i" -lt $((${#out[@]} - 1)) ] && printf ' '
	done
	printf '\n'
}

# Ordre des HOOKS acceptable pour M3 ? Code 0 = bon ; sinon la raison est affichée.
#   rago_mkinitcpio_hooks_ok <hook>...
rago_mkinitcpio_hooks_ok() {
	local h i=0 p_sys=-1 p_enc=-1 p_blk=-1 p_fs=-1 p_vc=-1 p_kbd=-1
	for h in "$@"; do
		case "$h" in
		udev) echo "hook udev (busybox) : sd-encrypt demande systemd"; return 1 ;;
		encrypt) echo "hook encrypt (busybox) : pas de TPM2, un seul volume"; return 1 ;;
		systemd) p_sys=$i ;;
		sd-encrypt) p_enc=$i ;;
		block) p_blk=$i ;;
		filesystems) p_fs=$i ;;
		sd-vconsole) p_vc=$i ;;
		keyboard) p_kbd=$i ;;
		esac
		i=$((i + 1))
	done
	if [ "$p_sys" -lt 0 ]; then echo "hook systemd absent"; return 1; fi
	if [ "$p_enc" -lt 0 ]; then echo "hook sd-encrypt absent"; return 1; fi
	if [ "$p_blk" -lt 0 ] || [ "$p_blk" -gt "$p_enc" ]; then echo "block doit précéder sd-encrypt"; return 1; fi
	if [ "$p_fs" -ge 0 ] && [ "$p_fs" -lt "$p_enc" ]; then echo "sd-encrypt doit précéder filesystems"; return 1; fi
	if [ "$p_kbd" -lt 0 ] || [ "$p_kbd" -gt "$p_enc" ]; then echo "keyboard doit précéder sd-encrypt (passphrase de secours)"; return 1; fi
	if [ "$p_vc" -ge 0 ] && [ "$p_vc" -gt "$p_enc" ]; then echo "sd-vconsole doit précéder sd-encrypt (clavier du joueur)"; return 1; fi
	return 0
}

# Contenu du fichier /etc/mkinitcpio.conf.d/90-rago-encryption.conf.
#   rago_mkinitcpio_dropin <HOOKS d'origine> <HOOKS Rago>
rago_mkinitcpio_dropin() {
	printf '# Rago OS — chiffrement LUKS2 + TPM2 (module M3). Marqueur : %s\n' "$RAGO_ENC_MARKER"
	printf '# Écrit par host/setup_secure_encryption.sh install ; ne pas modifier à la main.\n'
	printf '# systemd + sd-encrypt : TPM2 puis passphrase de secours, swap déchiffré avant\n'
	printf '# le resume de l'"'"'hibernation ; /etc/crypttab.initramfs copiée dans l'"'"'image.\n'
	printf '# HOOKS d'"'"'origine : (%s)\n' "$1"
	printf 'HOOKS=(%s)\n' "$2"
}

# --- dracut -----------------------------------------------------------------------
# Contenu de /etc/dracut.conf.d/90-rago-encryption.conf.
#   rago_dracut_conf <modules disponibles (liste)> <uuid racine> <uuid swap ou ""> <clavier 0|1>
# Les modules demandés qui n'existent pas dans cette version de dracut sont
# omis (dracut refuse un module inconnu). rago-crypttab (host/dracut/) met
# /etc/crypttab.initramfs dans l'image : seulement les volumes du démarrage.
rago_dracut_conf() {
	local avail=" $1 " root=$2 swap=$3 kbd=$4 m mods="" devs
	for m in systemd crypt systemd-cryptsetup tpm2-tss resume rago-crypttab; do
		case "$avail" in *" $m "*) mods="$mods $m" ;; esac
	done
	if [ "$kbd" = 1 ]; then
		case "$avail" in *" i18n "*) mods="$mods i18n" ;; esac
	fi
	devs="/dev/disk/by-uuid/$root"
	[ -n "$swap" ] && devs="$devs /dev/disk/by-uuid/$swap"
	printf '# Rago OS — chiffrement LUKS2 + TPM2 (module M3). Marqueur : %s\n' "$RAGO_ENC_MARKER"
	printf '# Écrit par host/setup_secure_encryption.sh install ; ne pas modifier à la main.\n'
	printf '# systemd dans l'"'"'initramfs : systemd-cryptsetup (TPM2 puis passphrase de secours),\n'
	printf '# swap déchiffré AVANT le resume de l'"'"'hibernation (Fast OS Switch, M6) ;\n'
	printf '# rago-crypttab : /etc/crypttab.initramfs devient la crypttab de l'"'"'image.\n'
	printf 'add_dracutmodules+=" %s "\n' "${mods# }"
	printf '# Volumes ouverts dans l'"'"'initramfs même hors détection « hostonly » (chroot de\n'
	printf '# l'"'"'installateur, swap pas encore actif).\n'
	printf 'add_device+=" %s "\n' "$devs"
}

# Modules dracut disponibles dans <dossier modules.d> : « 90crypt » -> « crypt ».
#   rago_dracut_modules <dossier>
rago_dracut_modules() {
	local d n out=""
	for d in "$1"/[0-9][0-9]*; do
		[ -d "$d" ] || continue
		n=${d##*/}
		out="$out ${n#[0-9][0-9]}"
	done
	echo "${out# }"
}

# --- initramfs : contenu attendu ------------------------------------------------
# Liste de fichiers d'une initramfs (« lsinitrd » : style ls -l ; « lsinitcpio » :
# un chemin par ligne) -> éléments manquants pour M3 (vide = rien ne manque).
#   rago_initramfs_missing <fichier liste> <swap 0|1> <fichier modules.builtin ou "">
# dm-crypt et le pilote TPM (tpm_crb ou tpm_tis) peuvent être intégrés au noyau
# (noyau Rago de M0) : on regarde alors modules.builtin.
rago_initramfs_missing() {
	local lst=$1 swap=$2 builtin=${3:-} out=""
	_has() { grep -Eq "$1" "$lst"; }
	_builtin() { [ -n "$builtin" ] && grep -Eq "$1" "$builtin" 2>/dev/null; }
	_has '(^|[ /])etc/crypttab( |$)' || out="$out etc/crypttab"
	_has '(^|[ /])systemd-cryptsetup( |$)' || out="$out systemd-cryptsetup"
	_has 'libcryptsetup-token-systemd-tpm2\.so' || out="$out libcryptsetup-token-systemd-tpm2.so"
	_has 'libtss2-esys\.so' || out="$out libtss2-esys"
	_has 'libtss2-tcti-device\.so' || out="$out libtss2-tcti-device"
	_builtin '/dm-crypt\.ko' || _has '/dm-crypt\.ko' || out="$out dm-crypt.ko"
	_builtin '/tpm_(crb|tis)\.ko' || _has '/tpm_(crb|tis)\.ko' || out="$out tpm_crb.ko|tpm_tis.ko"
	if [ "$swap" = 1 ]; then
		_has 'systemd-hibernate-resume' || out="$out systemd-hibernate-resume"
	fi
	unset -f _has _builtin
	echo "${out# }"
}

# --- ligne de commande du noyau -------------------------------------------------
# Jetons voulus par M3 : racine chiffrée et resume depuis le swap chiffré.
# Identiques pour les deux slots (chaque slot nomme son volume rago-root).
#   rago_enc_cmdline <swap 0|1>
rago_enc_cmdline() {
	local t="root=/dev/mapper/$RAGO_MAP_ROOT"
	[ "$1" = 1 ] && t="$t resume=/dev/mapper/$RAGO_MAP_SWAP"
	echo "$t"
}

# Valeur d'un paramètre « clé=valeur » (dernière occurrence, comme le noyau).
#   rago_cmdline_value <ligne> <clé>
rago_cmdline_value() {
	local w v="" found=1
	for w in $1; do
		case "$w" in "$2="*) v=${w#"$2="}; found=0 ;; esac
	done
	[ "$found" = 0 ] || return 1
	echo "$v"
}

# Retire toutes les occurrences d'un paramètre « clé=… ».
#   rago_cmdline_drop_key <ligne> <clé>
rago_cmdline_drop_key() {
	local w out=""
	for w in $1; do
		case "$w" in "$2="*) ;; *) out="$out $w" ;; esac
	done
	echo "${out# }"
}

# --- disques : virtuel ou réel ? -------------------------------------------------
# Le périphérique (dossier /sys/class/block/<nom>) est-il un disque virtuel ?
# loop, nbd, virtio, zram, disques QEMU (SATA / NVMe émulés). Une partition est
# jugée sur son disque parent. Sert au mode --virtual-only des tests : JAMAIS
# de vrai disque.
#   rago_dev_is_virtual <dossier sysfs du périphérique>
rago_dev_is_virtual() {
	local d=$1 name drv model vendor
	if [ -e "$d/partition" ]; then
		d=$(cd -P "$d" 2>/dev/null && cd .. && pwd -P) || return 1
	fi
	name=${d##*/}
	case "$name" in loop[0-9]* | nbd[0-9]* | zram[0-9]* | vd[a-z]*) return 0 ;; esac
	[ -e "$d/loop/backing_file" ] && return 0
	drv=$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null)
	case "$drv" in virtio_blk | virtio_scsi) return 0 ;; esac
	model=$(cat "$d/device/model" 2>/dev/null)
	vendor=$(cat "$d/device/vendor" 2>/dev/null)
	case "$vendor $model" in *QEMU*) return 0 ;; esac
	return 1
}
