#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — lance d'un coup les tests de M2 (couche Proton) sans matériel.
#
# Usage : host/tests/run_m2_tests.sh [--chroot]
#   sans option : tests sans root (fonctions, Steam, fausse racine, câblage
#                 réel avec les binaires de M14 / M0 construits par cargo)
#   --chroot      en plus, le test root avec les vrais paquets d'Ubuntu 25.10
#                 (host/tests/chroot/run_m2_chroot_test.sh, ~1 Go téléchargé)
# EN ATTENTE DE MATÉRIEL : affichage, VRR, HDR, tearing, --rt, FPS.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
chroot=0
[ "${1:-}" = --chroot ] && chroot=1
fails=0
run() { # run <nom> <commande...>
	local n=$1
	shift
	printf '==> %s\n' "$n"
	if "$@"; then printf '    OK\n'; else printf '    ÉCHEC\n'; fails=$((fails + 1)); fi
}

run "fonctions (test_proton_lib.sh)" bash "$here/test_proton_lib.sh"
run "configuration Steam / Heroic / Lutris (test_steam_config.py)" python3 "$here/test_steam_config.py"
run "install / verify / uninstall en fausse racine (test_proton_sysroot.sh)" bash "$here/test_proton_sysroot.sh"
if command -v cargo >/dev/null; then
	run "construction de rago-profiled (M14) et rago-sched-hint (M0)" \
		cargo build -q --manifest-path "$repo/Cargo.toml" -p rago-profiled -p rago-sched-hint
fi
run "câblage réel profil M14 + hint M0, pré-chauffage (test_rago_launch.sh)" bash "$here/test_rago_launch.sh"
if [ "$chroot" = 1 ]; then
	run "vrais paquets Ubuntu 25.10 (chroot, root)" bash "$here/chroot/run_m2_chroot_test.sh"
fi
if [ "$fails" -eq 0 ]; then echo "==> tout est bon"; else echo "==> $fails suite(s) en échec"; fi
[ "$fails" -eq 0 ]
