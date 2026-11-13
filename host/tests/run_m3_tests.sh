#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — lance d'un coup les tests de M3 (chiffrement LUKS2 + TPM) sans
# matériel. DISQUES VIRTUELS SEULEMENT : aucun test ne touche un vrai disque
# (fichiers jetables en loop devices ou en disques de VM, TPM émulé par swtpm).
#
# Usage : host/tests/run_m3_tests.sh [--loop] [--vm]
#   sans option : tests sans root (fonctions, fausses racines dracut / mkinitcpio)
#   --loop        en plus, en root : loop devices jetables + TPM émulé (~1 min)
#   --vm          en plus, en root : VM qemu UEFI + TPM émulé, 6 démarrages
#                 (host/tests/vm/run_m3_vm_test.sh, ~30 min en émulation,
#                 ~900 Mo téléchargés pour le système de base)
# EN ATTENTE DE MATÉRIEL : vrai TPM / firmware, passphrase au vrai clavier,
# mkinitcpio réel, débit et FPS.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
loop=0
vm=0
for a in "$@"; do
	case "$a" in
	--loop) loop=1 ;;
	--vm) vm=1 ;;
	-h | --help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $a" >&2; exit 2 ;;
	esac
done
if { [ "$loop" = 1 ] || [ "$vm" = 1 ]; } && [ "$(id -u)" -ne 0 ]; then
	echo "--loop et --vm demandent root (loop devices, VM)" >&2
	exit 2
fi
fails=0
run() { # run <nom> <commande...>
	local n=$1
	shift
	printf '==> %s\n' "$n"
	if "$@"; then printf '    OK\n'; else printf '    ÉCHEC\n'; fails=$((fails + 1)); fi
}

run "fonctions (test_crypt_lib.sh)" bash "$here/test_crypt_lib.sh"
run "install / verify / check en fausses racines (test_encryption_sysroot.sh)" bash "$here/test_encryption_sysroot.sh"
if [ "$loop" = 1 ]; then
	run "loop devices + TPM émulé swtpm (test_encryption_loop.sh, root)" bash "$here/test_encryption_loop.sh"
fi
if [ "$vm" = 1 ]; then
	run "VM UEFI + TPM émulé, 6 démarrages (vm/run_m3_vm_test.sh, root)" bash "$here/vm/run_m3_vm_test.sh"
fi
if [ "$fails" -eq 0 ]; then echo "==> tout est bon"; else echo "==> $fails suite(s) en échec"; fi
[ "$fails" -eq 0 ]
