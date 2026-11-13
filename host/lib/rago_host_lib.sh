# SPDX-License-Identifier: GPL-2.0
# shellcheck shell=bash
#
# Rago OS — fonctions pures du tuning hôte (module M1).
#
# Aucune de ces fonctions ne touche au système : elles lisent des fichiers ou
# des chaînes et écrivent sur la sortie standard. Utilisées par
# host/setup_host_tuning.sh et testées par host/tests/test_host_lib.sh.

# Marqueur présent dans chaque fichier installé par M1 : un fichier qui le
# contient est « à nous » (pas de sauvegarde, suppression sans risque).
# shellcheck disable=SC2034  # utilisé par setup_host_tuning.sh
RAGO_HOST_MARKER="rago-host-tuning"

# --- C-states -----------------------------------------------------------------------
# Mode C-states -> valeur de [cpu] force_latency du profil tuned.
#   deep    : aucune limite (None)
#   shallow : comme latency-performance (C1 au plus profond)
#   poll    : aucun C-state (0 µs)
rago_cstates_latency() {
	case "$1" in
	deep) echo "None" ;;
	shallow) echo "cstate.id_no_zero:1|3" ;;
	poll) echo "0" ;;
	*) return 2 ;;
	esac
}

# Valeur lue dans /dev/cpu_dma_latency (µs) -> le mode est-il appliqué ?
#   rago_cstates_check <mode> <valeur>
# Sans aucune demande, le noyau renvoie 2000000000 (PM_QOS_DEFAULT_VALUE).
rago_cstates_check() {
	local mode=$1 val=$2
	case "$val" in '' | *[!0-9]*) return 2 ;; esac
	case "$mode" in
	deep) [ "$val" -ge 2000000000 ] ;;
	shallow) [ "$val" -gt 0 ] && [ "$val" -lt 2000000000 ] ;;
	poll) [ "$val" -eq 0 ] ;;
	*) return 2 ;;
	esac
}

rago_valid_nvme_sched() {
	case "$1" in none | mq-deadline) return 0 ;; *) return 1 ;; esac
}

# --- tuned ----------------------------------------------------------------------------
# Dossier où installer un profil utilisateur, selon la version de tuned :
#   tuned >= 2.23 : /etc/tuned/profiles (profils système dans /usr/lib/tuned/profiles)
#   avant         : /etc/tuned
# Si /etc/tuned/tuned-main.conf fixe « profile_dirs », on prend le dernier
# dossier de la liste qui est sous /etc (le plus prioritaire pour l'utilisateur).
#   rago_tuned_profile_dir <racine>
rago_tuned_profile_dir() {
	local root=${1%/} line dirs d pick=""
	line=$(grep -E '^[[:space:]]*profile_dirs[[:space:]]*=' "$root/etc/tuned/tuned-main.conf" 2>/dev/null | tail -1)
	if [ -n "$line" ]; then
		dirs=${line#*=}
		for d in ${dirs//,/ }; do
			case "$d" in /etc/*) pick=${d%/} ;; esac
		done
		if [ -n "$pick" ]; then echo "$pick"; return 0; fi
	fi
	if [ -d "$root/usr/lib/tuned/profiles" ]; then
		echo /etc/tuned/profiles
	else
		echo /etc/tuned
	fi
}

# Sortie de « tuned-adm active » -> nom du profil actif (vide si aucun).
rago_tuned_active_from_output() {
	sed -n 's/^Current active profile:[[:space:]]*//p' | head -1
}

# --- fichiers KEY=valeur (style shell, jamais exécutés) ---------------------------
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

# Remplace (ou ajoute) CLE="valeur" ; le reste du fichier est gardé tel quel.
# La valeur ne doit contenir ni guillemet double ni retour à la ligne.
#   rago_conf_set <fichier> <CLE> <valeur>
rago_conf_set() {
	local file=$1 key=$2 val=$3 tmp
	case "$val" in *'"'* | *$'\n'*) return 2 ;; esac
	tmp=$(mktemp "${file}.XXXXXX") || return 1
	if [ -f "$file" ]; then
		awk -v k="$key" -v v="$val" '
			BEGIN { done = 0 }
			$0 ~ "^[[:space:]]*" k "=" {
				if (!done) { print k "=\"" v "\""; done = 1 }
				next
			}
			{ print }
			END { if (!done) print k "=\"" v "\"" }
		' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
		chmod --reference="$file" "$tmp" 2>/dev/null || true
	else
		printf '%s="%s"\n' "$key" "$val" > "$tmp"
	fi
	mv "$tmp" "$file"
}

# --- ligne de commande du noyau -----------------------------------------------------
# Jeton présent ? (« threadirqs », « zswap.enabled=0 »)
#   rago_cmdline_has <ligne> <jeton>
rago_cmdline_has() {
	local w
	for w in $1; do
		[ "$w" = "$2" ] && return 0
	done
	return 1
}

# Ajoute des jetons absents, dans l'ordre, sans doublon.
#   rago_cmdline_add <ligne> <jeton>...
rago_cmdline_add() {
	local out=$1 t
	shift
	for t in "$@"; do
		rago_cmdline_has "$out" "$t" || out="$out $t"
	done
	rago_norm_ws "$out"
}

# Retire des jetons (toutes leurs occurrences).
#   rago_cmdline_remove <ligne> <jeton>...
rago_cmdline_remove() {
	local line=$1 w t out="" keep
	shift
	for w in $line; do
		keep=1
		for t in "$@"; do [ "$w" = "$t" ] && keep=0; done
		[ "$keep" = 1 ] && out="$out $w"
	done
	echo "${out# }"
}

# Isolation stricte de cœurs détectée dans la ligne de commande ? (refusée par M1)
rago_cmdline_isolation() {
	local w out=""
	for w in $1; do
		case "$w" in isolcpus=* | nohz_full=* | rcu_nocbs=* | irqaffinity=*) out="$out $w" ;; esac
	done
	echo "${out# }"
}

# --- ordonnanceur d'E/S ---------------------------------------------------------------
# « none [mq-deadline] kyber bfq » -> mq-deadline
rago_sched_current() {
	local w
	for w in $1; do
		case "$w" in \[*\]) w=${w#[}; echo "${w%]}"; return 0 ;; esac
	done
	return 1
}

# Ordonnanceur disponible dans la liste du noyau ?
#   rago_sched_available <liste> <nom>
rago_sched_available() {
	local w
	for w in $1; do
		w=${w#[}; w=${w%]}
		[ "$w" = "$2" ] && return 0
	done
	return 1
}

# Ordonnanceur attendu par 60-rago-iosched.rules pour un disque entier.
#   rago_expected_sched <nom noyau> <rotational 0|1> <choix NVMe>
# Vide (code 1) si le disque n'est pas géré (zram, loop, dm, md...).
rago_expected_sched() {
	local name=$1 rot=$2 nvme=$3
	case "$name" in
	nvme[0-9]*n[0-9]*)
		case "$name" in *p[0-9]*) return 1 ;; esac
		echo "$nvme" ;;
	sd[a-z]* | mmcblk[0-9]* | vd[a-z]*)
		case "$name" in
		sd*[0-9] | vd*[0-9] | mmcblk*p[0-9]* | mmcblk*boot* | mmcblk*rpmb) return 1 ;;
		esac
		if [ "$rot" = 0 ]; then
			echo mq-deadline
		elif [ "$rot" = 1 ]; then
			case "$name" in sd*) echo bfq ;; *) return 1 ;; esac
		else
			return 1
		fi ;;
	*) return 1 ;;
	esac
}

# --- listes de CPU ----------------------------------------------------------------------
# « 0-7,16-23 » valide ?
rago_cpulist_valid() {
	local part a b
	[ -n "$1" ] || return 1
	case "$1" in *[!0-9,-]*) return 1 ;; esac
	for part in ${1//,/ }; do
		case "$part" in
		*-*)
			a=${part%-*}; b=${part#*-}
			case "$a$b" in '' | *-*) return 1 ;; esac
			[ -n "$a" ] && [ -n "$b" ] && [ "$a" -le "$b" ] || return 1 ;;
		'') return 1 ;;
		esac
	done
	case "$1" in ,* | *, | *,,*) return 1 ;; esac
	return 0
}

# --- sysctl ------------------------------------------------------------------------------
# Lignes utiles d'un fichier sysctl.d : « clé<TAB>valeur<TAB>optionnel(0|1) »,
# valeur aux espaces normalisés.
rago_sysctl_entries() {
	awk '
		/^[[:space:]]*($|#|;)/ { next }
		{
			line = $0
			eq = index(line, "=")
			if (eq == 0) next
			k = substr(line, 1, eq - 1); v = substr(line, eq + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
			gsub(/[[:space:]]+/, " ", v)
			opt = 0
			if (substr(k, 1, 1) == "-") { opt = 1; k = substr(k, 2) }
			printf "%s\t%s\t%d\n", k, v, opt
		}
	' "$1"
}

# Clé sysctl -> chemin relatif sous /proc/sys (« net.ipv4.tcp_rmem » ->
# « net/ipv4/tcp_rmem »). Une clé déjà écrite avec des « / » est gardée.
rago_sysctl_path() {
	case "$1" in
	*/*) echo "$1" ;;
	*) echo "${1//.//}" ;;
	esac
}

rago_norm_ws() {
	# shellcheck disable=SC2086  # découpage voulu
	echo $1
}

# --- temps de trame (MangoHud) ----------------------------------------------
# Statistiques d'un journal CSV MangoHud (colonne « frametime », en ms) :
#   rago_frametime_stats <csv>  ->  « trames fps_moyen low_1 low_0.1 »
# 1 % low = 1000 / (temps de trame au 99e centile), comme le résumé MangoHud.
# Code 1 si le fichier n'a pas de colonne frametime ou trop peu de trames.
rago_frametime_stats() {
	local col
	col=$(awk -F, '
		{
			for (i = 1; i <= NF; i++) {
				f = $i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f)
				if (f == "frametime") { print NR ":" i; exit }
			}
		}' "$1")
	[ -n "$col" ] || return 1
	awk -F, -v hdr="${col%%:*}" -v c="${col#*:}" '
		NR <= hdr { next }
		{
			v = $c + 0
			if (v > 0) { n++; ft[n] = v; sum += v }
		}
		END {
			if (n < 100) exit 1
			# Tri décroissant par fusion itérative (pas de tri en awk POSIX).
			m = n
			for (w = 1; w < m; w *= 2) {
				for (lo = 1; lo <= m; lo += 2 * w) {
					mid = lo + w; hi = lo + 2 * w
					if (mid > m + 1) mid = m + 1
					if (hi > m + 1) hi = m + 1
					i = lo; j = mid; k = lo
					while (i < mid && j < hi) {
						if (ft[i] >= ft[j]) { tmp[k++] = ft[i++] } else { tmp[k++] = ft[j++] }
					}
					while (i < mid) tmp[k++] = ft[i++]
					while (j < hi) tmp[k++] = ft[j++]
					for (k = lo; k < hi; k++) ft[k] = tmp[k]
				}
			}
			i1 = int(n * 0.01); if (i1 < 1) i1 = 1
			i01 = int(n * 0.001); if (i01 < 1) i01 = 1
			printf "%d %.1f %.1f %.1f\n", n, 1000 * n / sum, 1000 / ft[i1], 1000 / ft[i01]
		}' "$1"
}

# Variation en % de b par rapport à a (une décimale), ex. « +4.2 » / « -1.0 ».
rago_pct_delta() {
	awk -v a="$1" -v b="$2" 'BEGIN { if (a == 0) exit 1; printf "%+.1f\n", (b - a) * 100 / a }'
}
