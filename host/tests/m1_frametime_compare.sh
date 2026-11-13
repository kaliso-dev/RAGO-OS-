#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — critère « 1 % low MangoHud » du module M1 (test sur matériel).
#
# Compare deux journaux CSV de MangoHud enregistrés dans la même scène du même
# jeu : un AVANT le tuning (ou après « setup_host_tuning.sh uninstall »), un
# APRÈS. Affiche FPS moyen, 1 % low et 0,1 % low, et l'écart.
#
# Usage : m1_frametime_compare.sh [--tolerance PCT] <avant.csv> <après.csv>
#         m1_frametime_compare.sh <journal.csv>        (statistiques seules)
#
# Code retour : 0 si le 1 % low APRÈS n'est pas plus bas que AVANT de plus de
# PCT % (défaut 2 : le bruit d'une mesure à l'autre), 1 sinon, 2 si un journal
# est illisible.
#
# Enregistrer un journal : MANGOHUD=1 MANGOHUD_CONFIG=output_folder=$HOME/mangologs,log_duration=60,autostart_log=5 %command%
# (option de lancement Steam), puis jouer 60 s dans une scène qui se répète.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib/rago_host_lib.sh
. "$here/../lib/rago_host_lib.sh"

tol=2
while [ $# -gt 0 ]; do
	case "$1" in
	--tolerance) tol=$2; shift 2 ;;
	-h | --help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) break ;;
	esac
done
case "$tol" in '' | *[!0-9.]*) echo "--tolerance : nombre attendu" >&2; exit 2 ;; esac
if [ $# -lt 1 ] || [ $# -gt 2 ]; then echo "usage : $0 [--tolerance PCT] <avant.csv> [après.csv]" >&2; exit 2; fi

# stats <csv> : remplit STATS, ou quitte (code 2) si le journal est illisible.
stats() {
	STATS=$(rago_frametime_stats "$1") || { echo "journal illisible ou trop court (< 100 trames, colonne frametime) : $1" >&2; exit 2; }
}

if [ $# = 1 ]; then
	stats "$1"
	read -r n avg l1 l01 <<< "$STATS"
	printf '%s : %d trames, FPS moyen %s, 1 %% low %s, 0,1 %% low %s\n' "$1" "$n" "$avg" "$l1" "$l01"
	exit 0
fi

stats "$1"
read -r na avga l1a l01a <<< "$STATS"
stats "$2"
read -r nb avgb l1b l01b <<< "$STATS"
printf '%-12s %10s %10s %10s\n' "" "avant" "après" "écart"
printf '%-12s %10d %10d\n' "trames" "$na" "$nb"
printf '%-12s %10s %10s %9s%%\n' "FPS moyen" "$avga" "$avgb" "$(rago_pct_delta "$avga" "$avgb")"
printf '%-12s %10s %10s %9s%%\n' "1 % low" "$l1a" "$l1b" "$(rago_pct_delta "$l1a" "$l1b")"
printf '%-12s %10s %10s %9s%%\n' "0,1 % low" "$l01a" "$l01b" "$(rago_pct_delta "$l01a" "$l01b")"

if awk -v a="$l1a" -v b="$l1b" -v t="$tol" 'BEGIN { exit !(b >= a * (1 - t / 100)) }'; then
	echo "RÉUSSI : 1 % low sans régression (tolérance $tol %)"
	exit 0
fi
echo "ÉCHEC : 1 % low plus bas qu'avant de plus de $tol %"
exit 1
