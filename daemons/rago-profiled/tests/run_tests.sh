#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — M14 : lance tous les tests de rago-profiled qui tournent sans matériel.
#
#   1. cargo test -p rago-profiled (unitaires + intégration, dont le bout en
#      bout avec rago-sched-hint de M0, compilé d'abord) ;
#   2. profiles/tests/test_schema.py (schéma JSON et profils d'accord) ;
#   3. rago-profiled validate sur la base communautaire ;
#   4. en root seulement : tests/real_kernel_test.sh (vrai THP, vraie PM QoS).
# Le test VM (tests/vm/run_m14_vm_test.sh) se lance à part (root, ~10 min).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
cd "$repo" || exit 2
fail=0
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

step "compilation (rago-sched-hint de M0 pour le test de bout en bout, rago-profiled)"
cargo build -q -p rago-sched-hint -p rago-profiled || exit 1

step "cargo test -p rago-profiled"
cargo test -q -p rago-profiled || fail=1

step "schéma JSON"
if python3 -c 'import jsonschema, tomllib' 2>/dev/null; then
	python3 profiles/tests/test_schema.py | tail -1 || fail=1
else
	echo "SAUTÉ : python3 >= 3.11 avec le module jsonschema requis"
fi

step "validate : base communautaire"
target/debug/rago-profiled validate profiles/community profiles/schema/exemple-complet.toml | tail -1 || fail=1

if [ "$(id -u)" -eq 0 ]; then
	step "vrai noyau (root)"
	"$here/real_kernel_test.sh" --bin target/debug/rago-profiled | tail -1 || fail=1
else
	step "vrai noyau : SAUTÉ (relancer en root : sudo $here/real_kernel_test.sh)"
fi

echo
if [ "$fail" -eq 0 ]; then echo "TOUT EST VERT"; else echo "ÉCHEC"; fi
exit "$fail"
