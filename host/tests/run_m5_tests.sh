#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — lance d'un coup les tests de M5 (micro-Windows) qui tournent sous
# Linux. Windows n'est JAMAIS exécuté ici : les scripts PowerShell sont
# seulement lus (syntaxe, règles de Windows PowerShell 5.1, renvois entre
# fichiers) ; l'ablation DISM, l'installation, le démarrage et la taille
# finale se testent sur la machine du joueur (windows/README.md).
#
# Usage : host/tests/run_m5_tests.sh [--vm]
#   sans option : hook windows-security (règles, réglages ; en root en plus :
#                 vraie partition sur fichier image et bout en bout avec
#                 rago-profiled si target/release/rago-profiled existe), plan
#                 d'ablation, autounattend.xml, charge utile Windows
#   --vm          en plus, en root : VM qemu, vrai systemd, vraie FAT32
#                 RAGO-COMM (host/tests/vm/run_m5_vm_test.sh, ~10 min,
#                 système de base Ubuntu téléchargé)
# Analyse PowerShell complète : si pwsh est installé, test_payload.py s'en
# sert ; sinon il prend tree-sitter (pip install tree-sitter-language-pack)
# ou saute ce test et le dit.
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

run "hook windows-security (test_windows_security_hook.py)" "$py" -I "$here/test_windows_security_hook.py"
run "plan d'ablation (windows/tests/test_plan.py)" "$py" -I "$repo/windows/tests/test_plan.py"
run "autounattend.xml (windows/tests/test_unattend.py)" "$py" -I "$repo/windows/tests/test_unattend.py"
run "charge utile Windows (windows/tests/test_payload.py)" "$py" -I "$repo/windows/tests/test_payload.py"
if [ "$vm" = 1 ]; then
	run "VM qemu, vrai systemd, FAT32 RAGO-COMM (vm/run_m5_vm_test.sh, root)" bash "$here/vm/run_m5_vm_test.sh"
fi
if [ "$fails" -eq 0 ]; then echo "==> tout est bon"; else echo "==> $fails suite(s) en échec"; fi
[ "$fails" -eq 0 ]
