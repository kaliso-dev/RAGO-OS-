# SPDX-License-Identifier: GPL-2.0
# shellcheck shell=bash
#
# Rago OS — fonctions pures des images UKI et du scellement TPM sur PCR 11
# (module M4, utilisées aussi par le chiffrement M3).
#
# Une UKI (Unified Kernel Image) est un seul fichier EFI signé qui contient le
# noyau, l'initramfs et la ligne de commande. Au démarrage, systemd-stub (le
# début de l'UKI) MESURE ces sections dans le PCR 11 du TPM avant de lancer le
# noyau. Ici, sans TPM ni root, on :
#   - lit les sections d'un fichier PE (UKI) ;
#   - recalcule la valeur que PCR 11 aura dans l'initramfs (prédiction) ;
#   - recalcule l'empreinte de la politique TPM (PolicyPCR) qu'écrit
#     systemd-cryptenroll dans le jeton LUKS2 (« tpm2-policy-hash ») : on sait
#     ainsi quel jeton TPM correspond à quelle UKI, sans rien desceller ;
#   - lit les jetons TPM2 d'un « cryptsetup luksDump ».
# Aucune de ces fonctions ne touche au système : elles lisent des fichiers ou
# des chaînes et écrivent sur la sortie standard. Testées par
# host/tests/test_uki_lib.sh (comparées à systemd-measure et à de vrais jetons
# systemd-cryptenroll sur un TPM émulé).

# Marqueur des fichiers écrits par M4.
# shellcheck disable=SC2034  # utilisé par manage_atomic_updates.sh
RAGO_AB_MARKER="rago-atomic-updates"

# Sections mesurées par systemd-stub dans PCR 11, dans l'ordre où il les mesure
# (ordre de la liste « unified_sections » de systemd, de la v252 à la v259) :
# pour chacune, d'abord son nom (avec le NUL final), puis son contenu.
# « .pcrsig » (signatures) n'est jamais mesurée. Les sections récentes
# (.profile, .dtbauto, .hwids, .efifw : UKI à profils, systemd ≥ 257) changent
# la façon de mesurer : prédiction refusée (on reste alors sur PCR 0+7).
# shellcheck disable=SC2034
RAGO_UKI_MEASURED=".linux .osrel .cmdline .initrd .ucode .splash .dtb .uname .sbat .pcrpkey"
# shellcheck disable=SC2034
RAGO_UKI_UNSUPPORTED=".profile .dtbauto .hwids .efifw"

# Phase où l'initramfs ouvre les volumes : systemd-pcrphase-initrd.service
# étend PCR 11 avec « enter-initrd » AVANT cryptsetup.target, puis le système
# démarré ajoute « leave-initrd », « sysinit », « ready » (barrières : après
# l'initramfs, la clé ne se descelle plus).
# shellcheck disable=SC2034
RAGO_PCR11_UNLOCK_PHASE="enter-initrd"
# shellcheck disable=SC2034
RAGO_PCR11_RUNTIME_PHASES="enter-initrd leave-initrd sysinit ready"

# --- octets et sha256 ------------------------------------------------------------
# Hexadécimal -> octets sur la sortie standard (petites données : empreintes,
# structures TPM). Code 1 si ce n'est pas de l'hexadécimal pair.
#   rago_hex_bin <hexa>
rago_hex_bin() {
	local h=${1,,}
	case "$h" in *[!0-9a-f]*) return 1 ;; esac
	[ $((${#h} % 2)) -eq 0 ] || return 1
	[ -n "$h" ] || return 0
	# shellcheck disable=SC2059  # format construit : que des \xHH
	printf "$(printf '%s' "$h" | sed 's/../\\x&/g')"
}

# sha256 (hexa minuscule) d'octets donnés en hexa.
#   rago_sha256_hex <hexa>
rago_sha256_hex() {
	local out
	out=$(rago_hex_bin "$1" | sha256sum) || return 1
	echo "${out%% *}"
}

# sha256 d'un texte (sans NUL final) ; rago_sha256_text_nul : avec le NUL.
rago_sha256_text() {
	local out
	out=$(printf '%s' "$1" | sha256sum)
	echo "${out%% *}"
}
rago_sha256_text_nul() {
	local out
	out=$( { printf '%s' "$1"; printf '\0'; } | sha256sum)
	echo "${out%% *}"
}

# Valeur sha256 « hexa » valide (64 caractères hexadécimaux) ?
rago_is_sha256_hex() {
	case "$1" in *[!0-9a-fA-F]* | '') return 1 ;; esac
	[ "${#1}" -eq 64 ]
}

# Extension d'un PCR : nouveau = sha256(ancien || empreinte).
#   rago_pcr_extend <pcr hexa> <empreinte hexa>
rago_pcr_extend() {
	rago_sha256_hex "$1$2"
}

# PCR remis à zéro (au démarrage) : 32 octets nuls.
# shellcheck disable=SC2034
RAGO_PCR_ZERO="0000000000000000000000000000000000000000000000000000000000000000"

# --- fichiers PE (UKI) ------------------------------------------------------------
# Sections d'un fichier PE/COFF : une ligne par section
#   <nom> <taille virtuelle> <adresse virtuelle> <taille brute> <position brute>
# (nombres décimaux). Code 1 si ce n'est pas un fichier PE.
#   rago_pe_sections <fichier>
rago_pe_sections() {
	local f=$1 hdr lfanew sig n optsz tab
	[ -r "$f" ] || return 1
	hdr=$(od -An -v -t u1 -N 64 "$f" 2>/dev/null | tr -s ' \n' '  ') || return 1
	# shellcheck disable=SC2086  # découpage voulu
	set -- $hdr
	[ $# -ge 64 ] || return 1
	[ "$1" = 77 ] && [ "$2" = 90 ] || return 1 # « MZ »
	lfanew=$((${61} + ${62} * 256 + ${63} * 65536 + ${64} * 16777216))
	sig=$(od -An -v -t u1 -j "$lfanew" -N 24 "$f" 2>/dev/null | tr -s ' \n' '  ')
	# shellcheck disable=SC2086
	set -- $sig
	[ $# -ge 24 ] || return 1
	[ "$1 $2 $3 $4" = "80 69 0 0" ] || return 1 # « PE\0\0 »
	n=$((${7} + ${8} * 256))
	optsz=$((${21} + ${22} * 256))
	[ "$n" -ge 1 ] && [ "$n" -le 96 ] || return 1
	tab=$((lfanew + 24 + optsz))
	od -An -v -t u1 -j "$tab" -N $((n * 40)) "$f" 2>/dev/null | awk -v n="$n" '
		{ for (i = 1; i <= NF; i++) b[c++] = $i }
		function le32(o) { return b[o] + b[o + 1] * 256 + b[o + 2] * 65536 + b[o + 3] * 16777216 }
		END {
			if (c < n * 40) exit 1
			for (s = 0; s < n; s++) {
				o = s * 40; name = ""
				for (i = 0; i < 8 && b[o + i] != 0; i++) name = name sprintf("%c", b[o + i])
				if (name == "") name = "-"
				print name, le32(o + 8), le32(o + 12), le32(o + 16), le32(o + 20)
			}
		}'
}

# Contenu d'une section tel que systemd-stub le voit en mémoire : la taille
# virtuelle (données brutes tronquées, ou complétées de zéros).
#   rago_pe_section_dump <fichier> <taille virtuelle> <taille brute> <position brute>
rago_pe_section_dump() {
	local f=$1 vs=$2 rs=$3 off=$4 take
	take=$rs
	[ "$vs" -lt "$take" ] && take=$vs
	# dd et non « tail -c | head -c » : le tail de uutils (coreutils en Rust,
	# Ubuntu ≥ 25.10) plante sur le tube fermé par head (vu dans la VM de M4).
	dd if="$f" bs=65536 iflag=skip_bytes,count_bytes skip="$off" count="$take" status=none 2>/dev/null || return 1
	[ "$vs" -le "$rs" ] || head -c $((vs - rs)) /dev/zero
	return 0
}

# Ligne de rago_pe_sections pour une section donnée (la première de ce nom).
#   rago_pe_section_line <fichier> <nom>
rago_pe_section_line() {
	rago_pe_sections "$1" | awk -v s="$2" '$1 == s { print; found = 1; exit } END { if (!found) exit 1 }'
}

# Contenu d'une section (texte : .cmdline, .osrel, .uname, .rago…).
#   rago_uki_section <fichier> <nom>
rago_uki_section() {
	local line
	line=$(rago_pe_section_line "$1" "$2") || return 1
	# shellcheck disable=SC2086
	set -- "$1" $line
	rago_pe_section_dump "$1" "$3" "$5" "$6"
}

# Valeur « clé=valeur » de la section .rago (métadonnées signées de M4, jamais
# mesurées par systemd-stub : elles ne changent pas PCR 11).
#   rago_uki_meta <fichier> <clé>
rago_uki_meta() {
	{ rago_uki_section "$1" .rago 2>/dev/null || true; } | sed -n "/^$2=/{s/^$2=//p;q;}"
}

# Prédiction de PCR 11 (banque sha256) pour une UKI, après les phases données
# (« enter-initrd » : valeur au moment où l'initramfs ouvre les volumes).
# Code 1 : pas une UKI (pas de .linux) ; 2 : sections non prises en charge ;
# 4 : section illisible.
#   rago_uki_pcr11 <fichier> [phase...]
rago_uki_pcr11() {
	local f=$1 secs name vs va rs off s pcr d line
	shift
	local phases=("$@")
	secs=$(rago_pe_sections "$f") || return 1
	grep -q '^\.linux ' <<<"$secs" || return 1
	for s in $RAGO_UKI_UNSUPPORTED; do
		awk -v s="$s" '$1 == s { found = 1 } END { exit !found }' <<<"$secs" && return 2
	done
	pcr=$RAGO_PCR_ZERO
	for s in $RAGO_UKI_MEASURED; do
		line=$(awk -v s="$s" '$1 == s { print; exit }' <<<"$secs")
		[ -n "$line" ] || continue
		read -r name vs va rs off <<<"$line"
		: "$va"
		pcr=$(rago_pcr_extend "$pcr" "$(rago_sha256_text_nul "$name")")
		d=$(rago_pe_section_dump "$f" "$vs" "$rs" "$off" | sha256sum) || return 4
		pcr=$(rago_pcr_extend "$pcr" "${d%% *}")
	done
	for s in "${phases[@]}"; do
		pcr=$(rago_pcr_extend "$pcr" "$(rago_sha256_text "$s")")
	done
	echo "$pcr"
}

# Toutes les valeurs que PCR 11 peut avoir une fois le système démarré par
# cette UKI : après chaque phase (« enter-initrd », « enter-initrd leave-initrd »…)
# ou sans aucune (initramfs sans systemd-pcrphase : seulement « sysinit »,
# « sysinit ready »). Lignes « <phases séparées par :> <valeur> » ; « - » = aucune.
#   rago_uki_pcr11_runtime_values <fichier>
rago_uki_pcr11_runtime_values() {
	local f=$1 base p acc="" pcr
	base=$(rago_uki_pcr11 "$f") || return $?
	echo "- $base"
	pcr=$base
	for p in $RAGO_PCR11_RUNTIME_PHASES; do
		pcr=$(rago_pcr_extend "$pcr" "$(rago_sha256_text "$p")")
		acc="${acc:+$acc:}$p"
		echo "$acc $pcr"
	done
	pcr=$base
	acc=""
	for p in sysinit ready; do
		pcr=$(rago_pcr_extend "$pcr" "$(rago_sha256_text "$p")")
		acc="${acc:+$acc:}$p"
		echo "$acc $pcr"
	done
}

# --- politique TPM (PolicyPCR) -----------------------------------------------------
# Empreinte de la politique TPM2 « PolicyPCR » sur la banque sha256, celle que
# systemd-cryptenroll met dans « tpm2-policy-hash » quand le jeton est lié à des
# PCR sans PIN ni clé publique :
#   politique = sha256(0…0 || TPM_CC_PolicyPCR || TPML_PCR_SELECTION || sha256(PCR…))
# PCR triés par numéro. Code 1 si une valeur est invalide.
#   rago_tpm2_policy_pcr <pcr>=<hexa>...
rago_tpm2_policy_pcr() {
	local a p v sel0=0 sel1=0 sel2=0 vals="" sorted digest
	# « sort -n » : le numéro du PCR est en tête (« -t= » est refusé par le sort
	# de uutils, coreutils en Rust d'Ubuntu ≥ 25.10 : vu dans la VM de M4).
	sorted=$(for a in "$@"; do echo "$a"; done | sort -n)
	while IFS='=' read -r p v; do
		[ -n "$p" ] || continue
		case "$p" in *[!0-9]* | '') return 1 ;; esac
		[ "$p" -le 23 ] || return 1
		rago_is_sha256_hex "$v" || return 1
		case $((p / 8)) in
		0) sel0=$((sel0 | (1 << (p % 8)))) ;;
		1) sel1=$((sel1 | (1 << (p % 8)))) ;;
		2) sel2=$((sel2 | (1 << (p % 8)))) ;;
		esac
		vals="$vals${v,,}"
	done <<<"$sorted"
	[ -n "$vals" ] || return 1
	digest=$(rago_sha256_hex "$vals") || return 1
	# 0…0 (32 octets) | 0000017f | 00000001 000b 03 <sélection sur 3 octets> | sha256(PCR)
	rago_sha256_hex "${RAGO_PCR_ZERO}0000017f00000001000b03$(printf '%02x%02x%02x' "$sel0" "$sel1" "$sel2")$digest"
}

# --- jetons TPM2 d'un volume LUKS2 -------------------------------------------------
# « cryptsetup luksDump » -> une ligne par jeton systemd-tpm2 :
#   <id du jeton> <emplacements séparés par ,> <PCR « 0+7+11 »> <empreinte de politique hexa ou ->
# (cryptsetup 2.7 et 2.8 : l'empreinte est sur plusieurs lignes ; l'ordre des
# champs change d'une version à l'autre.)
rago_luks_tpm2_tokens() {
	awk '
		function flush() {
			if (tok != "" && ttype == "systemd-tpm2")
				print tok, (ks == "" ? "-" : ks), (pcrs == "" ? "-" : pcrs), (ph == "" ? "-" : ph)
			tok = ""; ttype = ""; ks = ""; pcrs = ""; ph = ""; inph = 0
		}
		/^Tokens:/ { on = 1; next }
		/^Digests:/ { flush(); on = 0; next }
		!on { next }
		/^  [0-9]+: / { flush(); t = $1; sub(/:$/, "", t); tok = t; ttype = $2; next }
		/^[[:space:]]+tpm2-policy-hash:/ {
			inph = 1; rest = $0; sub(/^[[:space:]]+tpm2-policy-hash:[[:space:]]*/, "", rest)
			gsub(/[[:space:]]/, "", rest); ph = ph rest; next
		}
		inph && /^[[:space:]]+([0-9a-f][0-9a-f][[:space:]]*)+$/ { l = $0; gsub(/[[:space:]]/, "", l); ph = ph l; next }
		{ inph = 0 }
		/^[[:space:]]+tpm2-hash-pcrs:/ { pcrs = $2; next }
		/^[[:space:]]+tpm2-pcrs:/ { if (pcrs == "") pcrs = $2; next }
		/^[[:space:]]+Keyslot:/ { ks = (ks == "" ? $2 : ks "," $2); next }
		END { flush() }
	'
}

# La liste de PCR « 0+7+11 » contient-elle ce PCR ?
#   rago_pcrs_have <liste> <pcr>
rago_pcrs_have() {
	case "+$1+" in *"+$2+"*) return 0 ;; esac
	return 1
}

# --- variables EFI de systemd-boot ---------------------------------------------------
# Contenu d'une variable EFI (fichier efivarfs : 4 octets d'attributs, puis une
# chaîne UTF-16LE terminée par NUL) -> texte ASCII. Vide si absente.
#   rago_efivar_string <fichier efivarfs>
rago_efivar_string() {
	[ -r "$1" ] || return 0
	od -An -v -t u1 -j 4 "$1" 2>/dev/null | awk '
		{ for (i = 1; i <= NF; i++) b[c++] = $i }
		END { for (i = 0; i + 1 < c; i += 2) { if (b[i] == 0 && b[i + 1] == 0) break; if (b[i + 1] == 0) printf "%c", b[i] } }'
	return 0
}

# --- slots A/B : entrées de démarrage ---------------------------------------------------
# Identifiants des entrées systemd-boot de Rago (l'identifiant d'une entrée est
# le nom de son fichier) :
#   rago-a.efi, rago-b.efi            UKI d'un slot (type 2, dans EFI/Linux/)
#   rago-a.next.efi                   UKI reconstruite du slot en marche, à l'essai
#   rago-a.conf, rago-a.next.conf     repli sans UKI (type 1 : noyau signé +
#                                     initramfs du slot, dans loader/entries/)
#   rago.conf                         entrée unique de M0 (avant M4)
# Entrée d'un slot :
#   rago_ab_entry_id <a|b> <uki|conf> [next]
rago_ab_entry_id() {
	case "$1" in a | b) ;; *) return 1 ;; esac
	local ext
	case "$2" in uki) ext=efi ;; conf) ext=conf ;; *) return 1 ;; esac
	if [ "${3:-}" = next ]; then echo "rago-$1.next.$ext"; else echo "rago-$1.$ext"; fi
}

# Slot d'une entrée : a | b | m0 (entrée de M0) ; code 1 si ce n'est pas une
# entrée Rago.
#   rago_ab_entry_slot <id>
rago_ab_entry_slot() {
	case "$1" in
	rago-a.efi | rago-a.next.efi | rago-a.conf | rago-a.next.conf) echo a ;;
	rago-b.efi | rago-b.next.efi | rago-b.conf | rago-b.next.conf) echo b ;;
	rago.conf) echo m0 ;;
	*) return 1 ;;
	esac
}

# Nom définitif d'une entrée à l'essai (rago-a.next.efi -> rago-a.efi).
#   rago_ab_entry_final <id>
rago_ab_entry_final() {
	case "$1" in
	*.next.efi) echo "${1%.next.efi}.efi" ;;
	*.next.conf) echo "${1%.next.conf}.conf" ;;
	*) echo "$1" ;;
	esac
}

# Type d'une entrée : uki | conf.
rago_ab_entry_kind() {
	case "$1" in *.efi) echo uki ;; *.conf) echo conf ;; *) return 1 ;; esac
}

# Chemin du fichier d'une entrée, relatif à la racine de l'ESP.
#   rago_ab_entry_path <id>
rago_ab_entry_path() {
	case "$1" in
	*.efi) echo "EFI/Linux/$1" ;;
	*.conf) echo "loader/entries/$1" ;;
	*) return 1 ;;
	esac
}

# Dossier des fichiers d'une entrée de repli (type 1) : noyau et initramfs du slot.
#   rago_ab_conf_dir <id>   (rago-a.conf -> rago/a ; rago-a.next.conf -> rago/a.next)
rago_ab_conf_dir() {
	case "$1" in
	rago-[ab].conf) local s=${1#rago-}; echo "rago/${s%.conf}" ;;
	rago-[ab].next.conf) local s=${1#rago-}; echo "rago/${s%.conf}" ;;
	*) return 1 ;;
	esac
}

# Entrées Rago présentes sur l'ESP : une ligne par entrée
#   <id> <slot a|b|m0> <uki|conf>
#   rago_ab_entries <dossier de l'ESP>
rago_ab_entries() {
	local esp=$1 f id
	for f in "$esp"/EFI/Linux/rago-[ab].efi "$esp"/EFI/Linux/rago-[ab].next.efi \
		"$esp"/loader/entries/rago-[ab].conf "$esp"/loader/entries/rago-[ab].next.conf \
		"$esp"/loader/entries/rago.conf; do
		[ -f "$f" ] || continue
		id=${f##*/}
		echo "$id $(rago_ab_entry_slot "$id") $(rago_ab_entry_kind "$id")"
	done
	return 0
}

# Valeur de PCR 11 au moment où l'initramfs de cette UKI ouvre les volumes :
# sections mesurées + phases notées par M4 dans la section .rago
# (« pcr11-phases=enter-initrd », ou vide si l'initramfs n'a pas
# systemd-pcrphase). Codes : 1 pas une UKI, 2 sections non prises en charge,
# 3 pas une UKI de Rago (pas de .rago : on ne devine pas les phases).
#   rago_uki_unlock_pcr11 <fichier>
rago_uki_unlock_pcr11() {
	local f=$1 meta phases
	meta=$(rago_uki_section "$f" .rago 2>/dev/null) || return 3
	grep -q '^pcr11-phases=' <<<"$meta" || return 3
	phases=$(sed -n '/^pcr11-phases=/{s/^pcr11-phases=//p;q;}' <<<"$meta")
	local list=()
	read -r -a list <<<"$phases" || true
	rago_uki_pcr11 "$f" "${list[@]}"
}

# Une liste de fichiers d'initramfs (lsinitrd, lsinitcpio, cpio -t) contient-elle
# la barrière TPM de systemd (systemd-pcrphase-initrd.service activé et son
# programme) ? Alors PCR 11 reçoit « enter-initrd » avant l'ouverture des volumes.
#   rago_initramfs_has_pcrphase <fichier liste>
rago_initramfs_has_pcrphase() {
	grep -Eq 'initrd\.target\.wants/systemd-pcrphase-initrd\.service' "$1" &&
		grep -Eq '(^|[ /])systemd-pcrphase-initrd\.service( |$)' "$1" &&
		grep -Eq '/systemd-(pcrextend|pcrphase)( |$)' "$1"
}

# Ligne de commande d'une UKI (comme M0, rago_cmdline) : base, mitigations=off
# si demandé, paramètres en plus, puis ceux de M4.
#   rago_uki_cmdline <base> <mitigations auto|off> <en plus> <en plus M4>
rago_uki_cmdline() {
	local out=$1
	case "${2:-auto}" in
	auto) ;;
	off) out="$out mitigations=off" ;;
	*) return 2 ;;
	esac
	[ -n "${3:-}" ] && out="$out $3"
	[ -n "${4:-}" ] && out="$out $4"
	# espaces multiples -> un seul (read : pas d'expansion de « * » ou « ? »)
	local words=()
	read -r -a words <<<"$out" || true
	echo "${words[*]}"
}

# os-release d'une UKI : celui du slot, avec un titre qui dit le slot (menu de
# systemd-boot) et la version de l'image.
#   rago_uki_os_release <os-release du slot> <slot> <version>
rago_uki_os_release() {
	local src=$1 slot=$2 ver=$3 S
	S=$(printf '%s' "$slot" | tr 'ab' 'AB')
	if [ -r "$src" ]; then
		grep -Ev '^(PRETTY_NAME|IMAGE_VERSION)=' "$src" || true
	else
		printf 'NAME="Rago OS"\nID=rago\n'
	fi
	printf 'PRETTY_NAME="Rago OS — slot %s%s"\n' "$S" "${ver:+ ($ver)}"
	[ -n "$ver" ] && printf 'IMAGE_VERSION="%s"\n' "$ver"
	return 0
}

# loader.conf de systemd-boot avec la clé donnée réglée (« clé valeur ») :
# première occurrence remplacée, doublons retirés, sinon ajoutée à la fin.
#   rago_loader_conf_set <fichier ou /dev/null> <clé> <valeur>
rago_loader_conf_set() {
	local file=$1
	[ -r "$file" ] || file=/dev/null
	awk -v k="$2" -v v="$3" '
		$1 == k { if (!done) { print k " " v; done = 1 } next }
		{ print }
		END { if (!done) print k " " v }
	' "$file"
}

# Valeur d'une clé de loader.conf (vide si absente).
#   rago_loader_conf_get <fichier> <clé>
rago_loader_conf_get() {
	[ -r "$1" ] || return 0
	awk -v k="$2" '$1 == k { $1 = ""; sub(/^ +/, ""); v = $0 } END { print v }' "$1" 2>/dev/null
}
