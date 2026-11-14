#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — lance d'un coup les tests de M7 (bibliothèque partagée) qui
# tournent sous Linux. L'agent Windows (windows/rago-agent) n'est JAMAIS
# exécuté ici : il est seulement lu (syntaxe, règles de Windows PowerShell
# 5.1, contrat avec Linux). Rien ici ne remplace l'essai sur la machine.
#
# Usage : host/tests/run_m7_tests.sh [--vm]
#   sans option : côté Linux (test_library.py : décision lecture / écriture,
#                 lecture du NTFS sur images fabriquées, requêtes, réglages ;
#                 en root en plus : rago-library.sh de bout en bout sur
#                 périphériques loop, en NTFS + ntfs3 si le noyau et mkntfs
#                 sont là, sinon en ext4), agent Windows (test_agent.py),
#                 charge utile Windows (test_payload.py)
#   --vm          en plus, en root : VM qemu, vrai noyau Ubuntu avec ntfs3,
#                 vrai systemd, RAGO-COMM FAT32 + RAGO-LIB NTFS
#                 (host/tests/vm/run_m7_vm_test.sh, ~15 min, système de base
#                 Ubuntu téléchargé)
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
vm=0
while [ $# -gt 0 ]; do
	case "$1" in
	--vm) vm=1; shift ;;
	-h | --help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done
if [ "$vm" = 1 ] && [ "$(id -u)" -ne 0 ]; then
	echo "--vm demande root (debootstrap, chroot, qemu)" >&2
	exit 2
fi
py=${PYTHON:-python3}
fails=0
run() { # run <nom> <commande...>
	local n=$1
	shift
	printf '==> %s\n' "$n"
	if "$@"; then printf '    OK\n'; else printf '    ÉCHEC\n'; fails=$((fails + 1)); fi
}

run "côté Linux (host/tests/test_library.py)" "$py" -I "$here/test_library.py"
run "agent Windows, contrat avec Linux (windows/tests/test_agent.py)" "$py" -I "$repo/windows/tests/test_agent.py"
run "charge utile Windows (windows/tests/test_payload.py)" "$py" -I "$repo/windows/tests/test_payload.py"
if [ "$vm" = 1 ]; then
	run "VM qemu, ntfs3, systemd, RAGO-COMM + RAGO-LIB (vm/run_m7_vm_test.sh, root)" bash "$here/vm/run_m7_vm_test.sh"
fi
if [ "$fails" -eq 0 ]; then echo "==> tout est bon"; else echo "==> $fails suite(s) en échec"; fi
[ "$fails" -eq 0 ]
