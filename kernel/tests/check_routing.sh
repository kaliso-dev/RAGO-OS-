#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — mesure où tournent les threads d'un processus (et de ses enfants).
#
#   check_routing.sh <pid> <masque CPU> <secondes> [motif de comm]
#
# Échantillonne toutes les 100 ms le CPU courant (champ 39 de
# /proc/<pid>/task/<tid>/stat) de chaque thread de <pid> et de ses
# descendants. Seuls les threads en cours d'exécution (état R) comptent.
# Si un motif est donné, seuls les threads dont le nom commence par ce motif
# sont comptés.
#
# Affiche : « samples=N inside=M pct=P » (P = % d'échantillons dans le masque).
# Compatible busybox (sh + awk), utilisé par la VM de test et par le test
# matériel.
set -eu

pid=${1:?pid}
mask=${2:?masque CPU, ex. 0-7,16-23}
secs=${3:?secondes}
pat=${4:-}

# Développe « 0-3,8 » en « 0 1 2 3 8 ».
expand() {
	echo "$1" | tr ',' '\n' | while IFS=- read -r a b; do
		[ -n "$a" ] || continue
		[ -n "${b:-}" ] || b=$a
		i=$a
		while [ "$i" -le "$b" ]; do printf '%s ' "$i"; i=$((i + 1)); done
	done
}

cpus=" $(expand "$mask")"

# PID + descendants : un seul passage awk sur /proc/*/stat (champ 4 = PPID).
tree() {
	cat /proc/[0-9]*/stat 2>/dev/null | sed 's/ (.*) / X /' | awk -v root="$1" '
		{ parent[$1] = $4 }
		END {
			out = root; seen[root] = 1; changed = 1
			while (changed) {
				changed = 0
				for (p in parent) if (!(p in seen) && (parent[p] in seen)) {
					seen[p] = 1; out = out " " p; changed = 1
				}
			}
			print out
		}'
}

samples=0
inside=0
pids=$(tree "$pid")
end=$(( $(date +%s) + secs ))
n=0
while [ "$(date +%s)" -lt "$end" ]; do
	# Rafraîchir l'arbre toutes les ~2 s (enfants tardifs).
	n=$((n + 1))
	if [ $((n % 20)) -eq 0 ]; then pids=$(tree "$pid"); fi
	for p in $pids; do
		for t in /proc/"$p"/task/*; do
			[ -r "$t/stat" ] || continue
			if [ -n "$pat" ]; then
				c=$(cat "$t/comm" 2>/dev/null || true)
				case "$c" in "$pat"*) ;; *) continue ;; esac
			fi
			# Après la dernière « ) » : $1=état ... $37=processor (champ 39).
			line=$(sed 's/.*) //' "$t/stat" 2>/dev/null || true)
			[ -n "$line" ] || continue
			sc=$(echo "$line" | awk '{print $1 ":" $37}')
			[ "${sc%%:*}" = "R" ] || continue
			cpu=${sc#*:}
			samples=$((samples + 1))
			case "$cpus " in *" $cpu "*) inside=$((inside + 1)) ;; esac
		done
	done
	sleep 0.1
done

if [ "$samples" -eq 0 ]; then
	echo "samples=0 inside=0 pct=0"
	exit 1
fi
echo "samples=$samples inside=$inside pct=$((inside * 100 / samples))"
