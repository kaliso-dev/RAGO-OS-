#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — lance d'un coup les tests de M4 (mises à jour A/B + UKI signée)
# sans matériel. DISQUES VIRTUELS SEULEMENT : aucun test ne touche un vrai
# disque, un vrai TPM ni une vraie clé (fichiers jetables, loop devices ou
# disques de VM, TPM émulé par swtpm, clés de test créées puis jetées).
#
# Usage : host/tests/run_m4_tests.sh [--loop] [--vm] [--chroot DIR]
#   sans option : tests sans root (fonctions UKI / PCR 11, fausses racines avec
#                 de vraies UKI ukify), plus la non-régression de M3 et M0
#   --loop        en plus, en root : loop devices jetables + TPM émulé (~1 min)
#   --vm          en plus, en root : VM qemu UEFI, Secure Boot actif + TPM
#                 émulé, 12 démarrages (host/tests/vm/run_m4_vm_test.sh,
#                 ~1 h 10 en émulation sur 4 cœurs, ~1 Go téléchargé pour le
#                 système de base)
#   --chroot DIR  en plus, en root : les tests sans root relancés dans le système
#                 de fichiers DIR (ex. le système de base de la VM, Ubuntu 26.04,
#                 dont les coreutils en Rust, uutils, ont fait trouver deux
#                 défauts) ; le dépôt y est monté en lecture seule
# EN ATTENTE DE MATÉRIEL : vrai firmware et vrai TPM (mesures PCR 0 / 7 / 11),
# shim + MokManager, noyau Rago dans l'UKI, mkinitcpio réel, clavier réel.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
loop=0
vm=0
chroot_dir=""
while [ $# -gt 0 ]; do
	case "$1" in
	--loop) loop=1; shift ;;
	--vm) vm=1; shift ;;
	--chroot)
		[ $# -ge 2 ] || { echo "--chroot DIR" >&2; exit 2; }
		chroot_dir=$(cd "$2" 2>/dev/null && pwd) || { echo "--chroot : $2 introuvable" >&2; exit 2; }
		shift 2 ;;
	-h | --help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done
if { [ "$loop" = 1 ] || [ "$vm" = 1 ] || [ -n "$chroot_dir" ]; } && [ "$(id -u)" -ne 0 ]; then
	echo "--loop, --vm et --chroot demandent root (loop devices, VM, chroot)" >&2
	exit 2
fi
fails=0
run() { # run <nom> <commande...>
	local n=$1
	shift
	printf '==> %s\n' "$n"
	if "$@"; then printf '    OK\n'; else printf '    ÉCHEC\n'; fails=$((fails + 1)); fi
}

run "UKI et PCR 11 prédit (test_uki_lib.sh)" bash "$here/test_uki_lib.sh"
run "rago-update en fausses racines (test_ab_sysroot.sh)" bash "$here/test_ab_sysroot.sh"
run "non-régression M3 : fonctions (test_crypt_lib.sh)" bash "$here/test_crypt_lib.sh"
run "non-régression M3 : fausses racines (test_encryption_sysroot.sh)" bash "$here/test_encryption_sysroot.sh"
run "non-régression M0 / M1 : fonctions (test_kernel_lib.sh, test_host_lib.sh)" \
	bash -c "bash '$repo/kernel/tests/test_kernel_lib.sh' && bash '$here/test_host_lib.sh'"
if [ "$loop" = 1 ]; then
	run "M4 : jetons TPM par UKI, loop devices + swtpm (test_ab_tpm_loop.sh, root)" bash "$here/test_ab_tpm_loop.sh"
	run "non-régression M3 : loop devices + swtpm (test_encryption_loop.sh, root)" bash "$here/test_encryption_loop.sh"
fi
if [ "$vm" = 1 ]; then
	run "VM UEFI Secure Boot + TPM émulé, 12 démarrages (vm/run_m4_vm_test.sh, root)" bash "$here/vm/run_m4_vm_test.sh"
fi
# Les tests sans root dans un autre système (autres coreutils, autre ukify…).
in_chroot() { # in_chroot <dossier>
	local d=$1 m t rc=0
	[ -x "$d/bin/bash" ] || [ -x "$d/usr/bin/bash" ] || { echo "    pas de bash dans $d"; return 1; }
	mkdir -p "$d/opt/rago-tests"
	mount --bind "$repo" "$d/opt/rago-tests" || return 1
	mount -o remount,bind,ro "$d/opt/rago-tests" || true
	for m in proc dev sys; do mount --rbind "/$m" "$d/$m" && mount --make-rslave "$d/$m"; done
	for t in host/tests/test_uki_lib.sh host/tests/test_ab_sysroot.sh host/tests/test_crypt_lib.sh \
		host/tests/test_encryption_sysroot.sh kernel/tests/test_kernel_lib.sh host/tests/test_host_lib.sh; do
		chroot "$d" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 bash "/opt/rago-tests/$t" 2>&1 |
			grep -aE 'ÉCHEC|OK, |réussis' | sed 's/^/    /' || rc=1
	done
	for m in sys dev proc; do umount -R "$d/$m" 2>/dev/null || umount -R -l "$d/$m" 2>/dev/null || true; done
	umount "$d/opt/rago-tests" 2>/dev/null || umount -l "$d/opt/rago-tests" 2>/dev/null || true
	return "$rc"
}
if [ -n "$chroot_dir" ]; then
	run "tests sans root dans $chroot_dir (chroot, root)" in_chroot "$chroot_dir"
fi
if [ "$fails" -eq 0 ]; then echo "==> tout est bon"; else echo "==> $fails suite(s) en échec"; fi
[ "$fails" -eq 0 ]
