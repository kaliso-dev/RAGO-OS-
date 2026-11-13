# SPDX-License-Identifier: GPL-2.0
# shellcheck shell=bash
#
# Rago OS — fonctions pures du build noyau (sourcées par build_rago_kernel.sh
# et par kernel/tests/test_kernel_lib.sh). Aucune action système ici : ces
# fonctions lisent des fichiers ou des chaînes et écrivent sur stdout, pour
# pouvoir être testées sans root ni matériel.

# Niveau de micro-architecture x86-64 (1 à 4) d'après une ligne « flags »
# de /proc/cpuinfo. Définition : psABI x86-64 (v2, v3, v4).
#   rago_x86_level_from_flags "fpu sse ... avx2 ..."
rago_x86_level_from_flags() {
	local flags=" $1 " f
	local v2="cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3"
	local v3="avx avx2 bmi1 bmi2 f16c fma abm movbe xsave"
	local v4="avx512f avx512bw avx512cd avx512dq avx512vl"
	for f in $v2; do case "$flags" in *" $f "*) ;; *) echo 1; return 0 ;; esac; done
	for f in $v3; do case "$flags" in *" $f "*) ;; *) echo 2; return 0 ;; esac; done
	for f in $v4; do case "$flags" in *" $f "*) ;; *) echo 3; return 0 ;; esac; done
	echo 4
}

# Niveau x86-64 de la machine (fichier cpuinfo en argument pour les tests).
# Prend le minimum sur tous les CPU (un CPU hybride n'expose pas toujours
# les mêmes drapeaux partout).
rago_detect_x86_level() {
	local cpuinfo=${1:-/proc/cpuinfo} min=4 l line
	while IFS= read -r line; do
		case "$line" in
		flags*:*)
			l=$(rago_x86_level_from_flags "${line#*:}")
			[ "$l" -lt "$min" ] && min=$l
			;;
		esac
	done < "$cpuinfo"
	echo "$min"
}

# Niveau effectif : la politique Rago est « v3 par défaut, v4 si détecté ».
# Un CPU sans v3 n'est pas pris en charge (bible v7, M0).
#   rago_choose_x86_level <niveau détecté> <demande : auto|3|4>
rago_choose_x86_level() {
	local detected=$1 want=${2:-auto}
	case "$want" in
	auto)
		if [ "$detected" -ge 4 ]; then echo 4
		elif [ "$detected" -ge 3 ]; then echo 3
		else return 1
		fi
		;;
	3|4)
		if [ "$detected" -lt "$want" ]; then return 1; fi
		echo "$want"
		;;
	*) return 2 ;;
	esac
}

# Valeur d'un symbole dans un .config (« y », « m », « 1000 », « "texte" »)
# ou « n » s'il est absent / « is not set ».
#   rago_cfg_get <.config> <SYMBOLE sans CONFIG_>
rago_cfg_get() {
	local file=$1 sym=$2 line
	line=$(grep -E "^(CONFIG_${sym}=|# CONFIG_${sym} is not set)" "$file" 2>/dev/null | tail -1)
	case "$line" in
	"CONFIG_${sym}="*) echo "${line#CONFIG_"${sym}"=}" ;;
	*) echo n ;;
	esac
}

# Vérifie un .config contre un fragment : chaque ligne « CONFIG_X=v » ou
# « # CONFIG_X is not set » du fragment doit se retrouver telle quelle.
# Les lignes du fragment suivies du commentaire « # rago:optional » sont
# seulement signalées (symbole absent de cette version du noyau).
# Écrit une ligne par écart : « MISSING X want=v got=w » ou
# « OPTIONAL X want=v got=w ». Code retour 1 s'il y a un écart obligatoire.
rago_cfg_verify() {
	local config=$1 fragment=$2 line sym want got optional bad=0
	while IFS= read -r line || [ -n "$line" ]; do
		optional=0
		case "$line" in *"# rago:optional"*) optional=1; line=${line%%#\ rago:optional*}; line=${line%"${line##*[![:space:]]}"} ;; esac
		case "$line" in
		CONFIG_*=*)
			sym=${line%%=*}; sym=${sym#CONFIG_}
			want=${line#*=}
			;;
		"# CONFIG_"*" is not set")
			sym=${line#\# CONFIG_}; sym=${sym%% is not set}
			want=n
			;;
		*) continue ;;
		esac
		got=$(rago_cfg_get "$config" "$sym")
		if [ "$got" != "$want" ]; then
			if [ "$optional" = 1 ]; then
				echo "OPTIONAL $sym want=$want got=$got"
			else
				echo "MISSING $sym want=$want got=$got"
				bad=1
			fi
		fi
	done < "$fragment"
	return "$bad"
}

# Retire d'une ligne de commande noyau les paramètres que Rago gère lui-même
# (BOOT_IMAGE, initrd, mitigations) pour en faire la base d'une entrée.
rago_cmdline_base() {
	local out="" w
	for w in $1; do
		case "$w" in
		BOOT_IMAGE=*|initrd=*|mitigations=*) ;;
		*) out="$out $w" ;;
		esac
	done
	echo "${out# }"
}

# Ligne de commande finale :
#   rago_cmdline <base> <mitigations : auto|off> [extra]
rago_cmdline() {
	local base=$1 mit=${2:-auto} extra=${3:-} out
	out=$base
	case "$mit" in
	auto) ;;
	off) out="$out mitigations=off" ;;
	*) return 2 ;;
	esac
	[ -n "$extra" ] && out="$out $extra"
	echo "${out# }"
}

# Entrée systemd-boot (Boot Loader Specification, type 1).
#   rago_loader_entry <titre> <version> <chemin noyau> <chemin initramfs> <options>
# Les chemins sont relatifs à la racine de l'ESP / XBOOTLDR (« /vmlinuz-linux-rago »).
rago_loader_entry() {
	local title=$1 version=$2 kernel=$3 initrd=$4 options=$5 ucode
	printf 'title   %s\n' "$title"
	printf 'version %s\n' "$version"
	printf 'linux   %s\n' "$kernel"
	for ucode in ${RAGO_UCODE_IMAGES:-}; do
		printf 'initrd  %s\n' "$ucode"
	done
	printf 'initrd  %s\n' "$initrd"
	printf 'options %s\n' "$options"
}

# Lit une valeur KEY=valeur d'un fichier de type shell sans l'exécuter
# (/etc/rago/kernel.conf). Guillemets simples ou doubles retirés.
#   rago_conf_get <fichier> <CLE> [défaut]
rago_conf_get() {
	local file=$1 key=$2 def=${3:-} line val
	line=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -1)
	if [ -z "$line" ]; then echo "$def"; return 0; fi
	val=${line#*=}
	val=${val#\"}; val=${val%\"}
	val=${val#\'}; val=${val%\'}
	echo "$val"
}

# Version noyau « 6.18.44 » -> URL du tarball kernel.org.
rago_kernel_url() {
	local v=$1 major=${1%%.*}
	echo "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/linux-${v}.tar.xz"
}

# Compare deux versions « a.b.c » : succès si $1 >= $2.
rago_version_ge() {
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}

# Lit kernel/patches/sources.lock : lignes « nom url sha256 » (commentaires
# « # » ; les lignes « CLE=valeur » sont des variables, ignorées ici).
# Écrit « nom url sha256 » nettoyé, une ligne par patch.
rago_series_entries() {
	local file=$1 line
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%%#*}
		# shellcheck disable=SC2086  # découpage voulu en mots
		set -- $line
		[ $# -eq 0 ] && continue
		case "$1" in *=*) [ $# -eq 1 ] && continue ;; esac
		if [ $# -ne 3 ]; then
			echo "ligne invalide dans $file : $line" >&2
			return 1
		fi
		echo "$1 $2 $3"
	done < "$file"
}

# Vrai si la chaîne est un sha256 hexadécimal (64 caractères).
rago_is_sha256() {
	case "$1" in
	*[!0-9a-f]*) return 1 ;;
	esac
	[ "${#1}" -eq 64 ]
}

# Variable « CLE=valeur » de sources.lock.
rago_lock_var() {
	sed -n "s/^$2=//p" "$1" | tail -1
}
