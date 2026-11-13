#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — partie « invité » du test VM du module M3 (lancée au démarrage par
# rago-m3-test.service). La phase vient de la ligne de commande du noyau
# (rago_m3_phase=N, donnée par run_m3_vm_test.sh). Résultats sur la console
# série : « RAGO-M3 PASS / FAIL / INFO … », puis « RAGO-M3 DONE phase N ».
#
# Disques (tous virtuels, virtio, repérés par leur numéro de série) :
#   rago-inst  installateur (ext4 non chiffré) : racine de la phase 1, échanges
#   rago-a     slot A        rago-b  slot B        rago-swap  swap d'hibernation
#   rago-part  disque avec partitions (doit être refusé)
set -u

H=/opt/rago-m3/host
S=$H/setup_secure_encryption.sh
PASSF=/root/m3pass
D_I=/dev/disk/by-id/virtio-rago-inst
D_A=/dev/disk/by-id/virtio-rago-a
D_B=/dev/disk/by-id/virtio-rago-b
D_S=/dev/disk/by-id/virtio-rago-swap
D_P=/dev/disk/by-id/virtio-rago-part
# argon2id raisonnable en émulation (TCG) ; le vrai défaut (2 s, 1 Gio) est pour le matériel.
FAST=(--iter-time 1000 --pbkdf-memory 131072)
LOG=/root/m3-logs
mkdir -p "$LOG"

pass() { echo "RAGO-M3 PASS $*"; }
fail() { echo "RAGO-M3 FAIL $*"; }
info() { echo "RAGO-M3 INFO $*"; }
# Lance le script M3 ; sortie (sans couleurs) dans $OUT et dans $LOG/<n>.log, code dans $RC.
n_run=0
enc() {
	n_run=$((n_run + 1))
	OUT=$(timeout 1800 "$S" "$@" < /dev/null 2>&1)
	RC=$?
	OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
	printf '$ %s\n%s\n(code %s)\n' "$*" "$OUT" "$RC" > "$LOG/$n_run.log"
}
show() { printf '%s\n' "$OUT" | grep -E "${1:-ÉCHEC|ERREUR|!!}" | head -"${2:-15}" | sed 's/^/RAGO-M3 INFO   | /'; }
expect_rc() { # expect_rc <nom> <code attendu>
	if [ "$RC" = "$2" ]; then pass "$1 (code $RC)"; else fail "$1 : code $RC, attendu $2"; show; fi
}
expect_out() { # expect_out <nom> <motif grep -E>
	if grep -Eq -- "$2" <<<"$OUT"; then pass "$1"; else fail "$1 : « $2 » absent"; show '.' 25; fi
}
done_phase() { sync; echo "RAGO-M3 DONE phase $1"; sleep 2; }
off() { sync; systemctl poweroff; exit 0; }

root_slave() { # disque sous la racine (dm-crypt) : vdb, vdc…
	local dm s
	dm=$(basename "$(readlink -f "$(findmnt -no SOURCE /)")")
	for s in "/sys/class/block/$dm/slaves"/*; do [ -e "$s" ] && { basename "$s"; break; }; done
}
check_root_on() { # check_root_on <slot> <disque>
	local src want
	src=$(findmnt -no SOURCE /)
	want=$(basename "$(readlink -f "$2")")
	if [ "$src" = /dev/mapper/rago-root ] && [ "$(root_slave)" = "$want" ]; then
		pass "racine : /dev/mapper/rago-root sur le slot $1 ($want), déverrouillée au démarrage"
	else
		fail "racine : $src sur $(root_slave) (attendu rago-root sur $want, slot $1)"
	fi
}
check_swap_on() {
	local dev
	dev=$(readlink -f /dev/mapper/rago-swap 2>/dev/null)
	if [ -n "$dev" ] && swapon --show=NAME --noheadings | xargs -r readlink -f | grep -qx "$dev"; then
		pass "swap chiffré actif ($dev), déverrouillé au démarrage"
	else
		fail "swap chiffré pas actif : $(swapon --show=NAME --noheadings | tr '\n' ' ')"
	fi
	if ! grep -qw disk /sys/power/state; then
		# Noyau Ubuntu sous Secure Boot : verrouillé (lockdown), pas d'hibernation.
		HIB_OFF=1
		info "hibernation indisponible avec ce noyau (lockdown : $(cat /sys/kernel/security/lockdown 2>/dev/null)) : resume pas testé à ce démarrage"
	elif [ "$(cat /sys/power/resume)" = "$(cat "/sys/class/block/$(basename "$dev")/dev" 2>/dev/null)" ]; then
		pass "hibernation : resume vers le swap chiffré ($(cat /sys/power/resume))"
	else
		fail "hibernation : /sys/power/resume = $(cat /sys/power/resume)"
	fi
}
HIB_OFF=0
cryptsetup_journal() { # ce que systemd-cryptsetup a dit au démarrage (initramfs compris)
	journalctl -b -o cat --no-pager -t systemd-cryptsetup 2>/dev/null | grep -Ei 'tpm|token|passphrase|password|unlock|fall' | sort | uniq -c | head -8 |
		sed 's/^/RAGO-M3 INFO   journal | /'
}
tpm_status() { grep -v '^#' /run/rago/encryption-status 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }

# Copie du système en marche (ou de l'installateur) dans un slot ouvert sur /mnt.
copy_system() {
	cp -ax / /mnt || return 1
	rm -rf /mnt/export /mnt/inst
	echo "/dev/mapper/rago-root / ext4 rw,errors=remount-ro 0 1" > /mnt/etc/fstab
	mkdir -p /mnt/run /mnt/proc /mnt/sys /mnt/dev /mnt/tmp
}
chroot_mounts() { # chroot_mounts on|off
	local m left
	if [ "$1" = on ]; then
		# rslave : un démontage sous /mnt ne repart pas vers les vrais /dev, /proc…
		for m in dev proc sys run; do mount --rbind "/$m" "/mnt/$m" && mount --make-rslave "/mnt/$m"; done
	else
		for m in run sys proc dev; do umount -R "/mnt/$m" 2>/dev/null || umount -R -l "/mnt/$m" 2>/dev/null; done
		left=$(findmnt -R -n -o TARGET /mnt | tail -n +2 | tr '\n' ' ')
		[ -z "$left" ] || info "montages restants sous /mnt : $left"
	fi
}
# Démonte /mnt ; s'il est occupé, dit par quoi (montages, processus).
release_mnt() {
	local p who=""
	sync
	umount /mnt 2>/dev/null && return 0
	for p in /proc/[0-9]*; do
		if readlink "$p/root" "$p/cwd" "$p"/fd/* 2>/dev/null | grep -q '^/mnt'; then
			who="$who $(basename "$p"):$(cat "$p/comm" 2>/dev/null)"
		fi
	done
	info "/mnt occupé : montages $(findmnt -R -n -o TARGET /mnt | tr '\n' ' '); processus :${who:- aucun}"
	sleep 2
	umount -R /mnt 2>/dev/null && return 0
	fail "démontage de /mnt impossible"
	umount -l /mnt
	return 1
}
# Après « install » dans le chroot : rien en échec, contrôles du système démarré sautés.
check_chroot_install() { # check_chroot_install <slot>
	expect_out "install $1 (chroot) : racine / swap / hibernation laissés au 1er démarrage" 'IGNORÉ.*dans un chroot'
	if grep -q 'ÉCHEC' <<<"$OUT"; then fail "install $1 (chroot) : échec dans la vérification"; show 'ÉCHEC'; else pass "install $1 (chroot) : vérification sans échec"; fi
}
kver() { printf '%s\n' /usr/lib/modules/* | sort -V | tail -1 | xargs basename; }
export_files() { # export_files <dossier d'export> <slot>
	local k
	k=$(kver)
	mkdir -p "$1"
	cp "/mnt/boot/vmlinuz-$k" "$1/vmlinuz"
	cp "/mnt/boot/initrd.img-$k" "$1/initrd-$2.img"
	(
		# shellcheck disable=SC1091
		. /mnt/etc/rago/kernel.conf
		echo "$RAGO_CMDLINE $RAGO_CMDLINE_EXTRA"
	) > "$1/cmdline-$2"
	info "export slot $2 : $(cat "$1/cmdline-$2")"
	lsinitrd "/mnt/boot/initrd.img-$k" > "$1/lsinitrd-$2.txt" 2>/dev/null
	lsinitrd -f etc/crypttab "/mnt/boot/initrd.img-$k" > "$1/initrd-crypttab-$2.txt" 2>/dev/null
	cp -r "$LOG" "$1/logs-$2" 2>/dev/null
}

# Installe le slot B depuis le système en marche (slot A), comme M4 le fera.
install_slot_b() {
	enc --device "$D_B" --name rago-b open
	expect_rc "slot B ouvert par le TPM (systemd-cryptsetup attach)" 0
	mkfs.ext4 -q -F -L rago-b-fs /dev/mapper/rago-b
	mount /dev/mapper/rago-b /mnt || { fail "montage du slot B"; return; }
	copy_system || fail "copie du système dans le slot B"
	chroot_mounts on
	OUT=$(chroot /mnt "$S" --slot b --root-device "$D_B" --other-slot-device "$D_A" --swap-device "$D_S" install 2>&1 < /dev/null)
	RC=$?
	OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
	printf '%s\n' "$OUT" > "$LOG/install-b.log"
	expect_rc "install du slot B (chroot, dracut réel)" 0
	check_chroot_install B
	expect_out "slot B : crypttab rago-root -> volume B" "crypttab : rago-root"
	if grep -q "UUID=$(cryptsetup luksUUID "$D_B")" /mnt/etc/crypttab && ! grep -q "UUID=$(cryptsetup luksUUID "$D_A")" /mnt/etc/crypttab; then
		pass "slot B : sa crypttab ouvre SON volume (et pas celui du slot A)"
	else
		fail "slot B : crypttab inattendue : $(grep -v '^#' /mnt/etc/crypttab | tr '\n' '|')"
	fi
	if grep -q 'RAGO_ENC_SLOT="b"' /mnt/etc/rago/encryption.conf; then pass "slot B : réglages slot b"; else fail "slot B : réglages"; fi
	chroot_mounts off
	mkdir -p /inst
	mount "$D_I" /inst && export_files /inst/export b && umount /inst
	release_mnt
	enc --name rago-b close
	expect_rc "slot B fermé" 0
}

phase=$(sed -n 's/.*rago_m3_phase=\([0-9]*\).*/\1/p' /proc/cmdline)
udevadm settle 2>/dev/null
info "phase ${phase:-?} : noyau $(uname -r), $(systemctl --version | head -1), $(cryptsetup --version)"

case "$phase" in
# ===================================================================================
1) # Installateur : format, copie du système dans le slot A, install, enrôlement TPM.
	enc check
	info "check (code $RC) :"
	printf '%s\n' "$OUT" | grep -E '^\s+\[' | sed 's/^/RAGO-M3 INFO   | /'
	expect_out "check : TPM 2.0 du noyau" '\[ OK \] +TPM 2.0 présent'
	expect_out "check : PCR 0+7 mesurés par OVMF" '\[ OK \] +PCR 0\+7 mesurés'
	expect_out "check : démarrage UEFI" '\[ OK \] +démarrage UEFI'
	expect_out "check : Secure Boot inactif signalé (PCR 7 changera)" 'ATTENTION.*Secure Boot inactif'
	expect_out "check : AES-NI vu" 'AES-NI présent'
	expect_out "check : dm-crypt" '\[ OK \] +dm-crypt disponible'

	# Refus : jamais un disque en service ou un disque entier partitionné.
	enc --virtual-only --device "$D_I" --role root-a --yes --passphrase-file "$PASSF" format
	expect_rc "refus : formater le disque monté (racine de l'installateur)" 1
	expect_out "refus : monté, raison" 'est monté'
	enc --virtual-only --device "$D_P" --role root-a --yes --passphrase-file "$PASSF" format
	expect_rc "refus : disque entier avec des partitions" 1
	expect_out "refus : partitions, raison" 'a des partitions'
	if [ "$(blkid -p -o value -s PTTYPE "$D_P")" = gpt ]; then pass "refus : table de partitions intacte"; else fail "table de partitions du disque refusé abîmée"; fi

	for v in "$D_A:root-a" "$D_B:root-b" "$D_S:swap"; do
		enc --virtual-only --yes --passphrase-file "$PASSF" "${FAST[@]}" --device "${v%%:*}" --role "${v##*:}" format
		expect_rc "format ${v##*:} (LUKS2 aes-xts-plain64 512, sha512, argon2id)" 0
	done
	expect_out "format swap : swap créé dans le volume chiffré" 'création du swap dans le volume chiffré'
	cryptsetup luksDump "$D_A" > "$LOG/luksdump-a-format.txt"
	enc --device "$D_S" --name t-swap --passphrase-file "$PASSF" open
	expect_rc "swap ouvert par la passphrase" 0
	if [ "$(blkid -p -o value -s TYPE /dev/mapper/t-swap)" = swap ]; then pass "swap : signature swap dans le volume"; else fail "swap : pas de signature swap"; fi
	if cryptsetup status t-swap | grep -q 'no_read_workqueue'; then pass "swap : options de performance gardées dans l'en-tête (no_read_workqueue)"; else info "options : $(cryptsetup status t-swap | grep flags)"; fi
	enc --name t-swap close

	# Le slot A, ouvert comme le ferait l'installateur.
	enc --device "$D_A" --name rago-root --passphrase-file "$PASSF" open
	expect_rc "slot A ouvert par la passphrase de secours" 0
	enc --virtual-only --device "$D_A" --role root-a --yes --passphrase-file "$PASSF" format
	expect_rc "refus : formater un volume ouvert" 1
	expect_out "refus : volume ouvert, raison" 'est utilisé par'
	mkfs.ext4 -q -F -L rago-a-fs /dev/mapper/rago-root
	mount /dev/mapper/rago-root /mnt || { fail "montage du slot A"; done_phase 1; off; }
	copy_system || fail "copie du système dans le slot A"
	mkdir -p /mnt/etc/rago
	# Ce qu'écrit le noyau Rago (M0, build_rago_kernel.sh) à l'installation.
	cat > /mnt/etc/rago/kernel.conf <<-'EOF'
	# Rago OS — options de démarrage du noyau Rago (lu par build_rago_kernel.sh).
	RAGO_CMDLINE="root=LABEL=rago-inst rw"
	RAGO_MITIGATIONS=auto
	RAGO_CMDLINE_EXTRA=""
	RAGO_ESP=/boot
	EOF
	chroot_mounts on
	OUT=$(chroot /mnt "$S" --root-device "$D_A" --other-slot-device "$D_B" --swap-device "$D_S" install 2>&1 < /dev/null)
	RC=$?
	OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
	printf '%s\n' "$OUT" > "$LOG/install-a.log"
	expect_rc "install du slot A (chroot de l'installateur, dracut réel)" 0
	check_chroot_install A
	expect_out "install : dracut lancé" '==> dracut : /boot/initrd.img-'
	expect_out "initramfs : systemd-cryptsetup, TPM2, dm-crypt, resume" '\[ OK \] +initramfs /boot/initrd.img-.*: systemd-cryptsetup, TPM2, dm-crypt, resume'
	expect_out "initramfs : crypttab ouvre le slot A" "\[ OK \] +initramfs .*crypttab ouvre UUID=$(cryptsetup luksUUID "$D_A")"
	expect_out "initramfs : crypttab ouvre le swap" "\[ OK \] +initramfs .*crypttab ouvre UUID=$(cryptsetup luksUUID "$D_S")"
	k=$(kver)
	ict=$(lsinitrd -f etc/crypttab "/mnt/boot/initrd.img-$k" 2>/dev/null | grep -v '^#' | awk 'NF { print $1 }' | tr '\n' ' ')
	if [ "$ict" = "rago-root rago-swap " ]; then pass "initramfs : seulement les volumes du démarrage (rago-root, rago-swap)"; else fail "initramfs : crypttab = $ict"; fi
	chroot_mounts off

	# Enrôlement TPM par l'installateur (vrai TPM du noyau, PCR mesurés par OVMF).
	enc --root /mnt --passphrase-file "$PASSF" enroll-tpm
	expect_rc "enroll-tpm (slots A et B, swap)" 0
	n=$(grep -c 'le TPM ouvre le volume (PCR actuels)' <<<"$OUT")
	if [ "$n" = 3 ]; then pass "enroll-tpm : le TPM ouvre les 3 volumes (jeton systemd-tpm2, cryptsetup --token-only)"; else fail "enroll-tpm : le TPM ouvre $n volume(s) sur 3"; show '.' 30; fi
	expect_out "enroll-tpm : risque PCR 7 expliqué" 'Risque PCR 7'
	for d in "$D_A" "$D_B" "$D_S"; do
		t=$(systemd-cryptenroll "$d" | awk 'NR > 1 { print $2 }' | sort | tr '\n' ' ')
		if [ "$t" = "password tpm2 " ]; then pass "$(basename "$d") : passphrase de secours + TPM"; else fail "$(basename "$d") : emplacements $t"; fi
	done
	if printf 'pas-la-bonne-passe-0\n' | cryptsetup open --test-passphrase --disable-external-tokens "$D_A" 2>/dev/null; then fail "une mauvaise passphrase ouvre le slot A"; else pass "mauvaise passphrase refusée"; fi
	cryptsetup luksDump "$D_A" > "$LOG/luksdump-a-enrolled.txt"
	systemd-cryptenroll "$D_A" > "$LOG/cryptenroll-list-a.txt" 2>&1

	export_files /export a
	release_mnt
	enc --name rago-root close
	expect_rc "slot A fermé" 0
	done_phase 1
	off
	;;
# ===================================================================================
2) # Slot A, Secure Boot inactif : tout doit s'ouvrir par le TPM, sans passphrase.
	check_root_on A "$D_A"
	check_swap_on
	cryptsetup_journal
	enc verify
	expect_rc "verify (slot A)" 0
	printf '%s\n' "$OUT" | grep -E '^\s+\[' | sed 's/^/RAGO-M3 INFO   | /'
	expect_out "verify : TPM ouvre le slot A (PCR actuels)" '\[ OK \] +slot A : le TPM ouvre le volume'
	enc tpm-check
	expect_rc "tpm-check : le TPM déverrouille" 0
	if [ "$(tpm_status)" = "a=ok b=ok swap=ok" ]; then pass "état pour l'interface (/run/rago/encryption-status) : a=ok b=ok swap=ok"; else fail "état : $(tpm_status)"; fi
	if systemctl is-enabled rago-tpm-check.timer > /dev/null 2>&1; then pass "minuterie rago-tpm-check activée"; else fail "minuterie rago-tpm-check pas activée"; fi
	enc --device "$D_B" --name t-b open
	expect_rc "open du slot B par le TPM" 0
	enc --name t-b close
	enc --device "$D_B" --name t-b --passphrase-file "$PASSF" open
	expect_rc "open du slot B par la passphrase de secours (jeton TPM ignoré)" 0
	enc --name t-b close
	printf 'pas-la-bonne-passe-0' > /root/wrong && chmod 600 /root/wrong
	enc --device "$D_B" --name t-b --passphrase-file /root/wrong open
	expect_rc "open avec une mauvaise passphrase refusé" 1
	enc --virtual-only --device "$D_S" --role swap --yes --passphrase-file "$PASSF" format
	expect_rc "refus : formater le swap en service" 1

	# Hibernation vers le swap chiffré, puis reprise (démarrage 3).
	info "logind CanHibernate : $(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate 2>&1)"
	bid=$(cat /proc/sys/kernel/random/boot_id)
	echo "$bid" > /run/rago-m3-hibernate
	echo shutdown > /sys/power/disk
	sync
	echo "RAGO-M3 HIBERNATE"
	if echo disk > /sys/power/state; then
		sleep 3
		echo "RAGO-M3 INFO reprise : $(uptime)"
		if [ "$(cat /proc/sys/kernel/random/boot_id)" = "$bid" ] && [ "$(cat /run/rago-m3-hibernate 2>/dev/null)" = "$bid" ]; then
			pass "reprise après hibernation : même session (boot_id, /run gardés), swap chiffré ouvert par le TPM avant le resume"
		else
			fail "reprise : session différente"
		fi
		check_swap_on
		check_root_on A "$D_A"
		install_slot_b
		done_phase 3
	else
		fail "hibernation refusée par le noyau (echo disk > /sys/power/state)"
		dmesg | grep -i -E 'PM:|hibernat|swsusp' | tail -5 | sed 's/^/RAGO-M3 INFO   | /'
		done_phase 2
	fi
	off
	;;
3) # Atteint seulement si la reprise a échoué (démarrage neuf au lieu du resume).
	fail "reprise de l'hibernation : démarrage neuf au lieu de la reprise"
	journalctl -b -o cat --no-pager | grep -i -E 'resum|hibernat' | head -5 | sed 's/^/RAGO-M3 INFO   | /'
	install_slot_b
	done_phase 3
	off
	;;
# ===================================================================================
4) # Slot B : sa propre crypttab, même swap.
	check_root_on B "$D_B"
	check_swap_on
	enc verify
	expect_rc "verify (slot B)" 0
	expect_out "verify : réglages slot b" 'réglages : /etc/rago/encryption.conf \(slot b\)'
	expect_out "verify : TPM ouvre le slot B" '\[ OK \] +slot B : le TPM ouvre le volume'
	enc tpm-check
	expect_rc "tpm-check (slot B)" 0
	done_phase 4
	off
	;;
# ===================================================================================
5) # Slot A, Secure Boot ACTIVÉ : PCR 7 a changé, le TPM refuse, passphrase tapée.
	sb=$(od -An -t u1 -j 4 -N 1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')
	if [ "$sb" = 1 ]; then pass "Secure Boot actif (clés de test OVMF) : PCR 7 différent de l'enrôlement"; else fail "Secure Boot pas actif ($sb)"; fi
	check_root_on A "$D_A"
	check_swap_on
	cryptsetup_journal
	enc tpm-check
	expect_rc "tpm-check : le TPM refuse, signalé" 1
	if [ "$(tpm_status)" = "a=refused b=refused swap=refused" ]; then pass "état pour l'interface : a=refused b=refused swap=refused"; else fail "état : $(tpm_status)"; fi
	expect_out "tpm-check : commande reseal donnée" 'sudo rago-encryption reseal'
	enc verify
	expect_rc "verify : échec tant que le TPM refuse" 1
	expect_out "verify : PCR 7 changé repéré" 'ÉCHEC.*PCR 7 changés depuis l.enrôlement'
	expect_out "verify : TPM refuse expliqué" 'ÉCHEC.*slot A : le TPM REFUSE'
	if [ "$HIB_OFF" = 1 ]; then expect_out "verify : hibernation impossible signalée (noyau verrouillé)" 'ATTENTION.*hibernation impossible : noyau verrouillé'; fi
	enc --passphrase-file "$PASSF" reseal
	expect_rc "reseal (passphrase de secours)" 0
	n=$(grep -c 'le TPM ouvre le volume (PCR actuels)' <<<"$OUT")
	if [ "$n" = 3 ]; then pass "reseal : le TPM rouvre les 3 volumes avec les nouveaux PCR"; else fail "reseal : $n volume(s) sur 3"; show '.' 30; fi
	enc tpm-check
	expect_rc "tpm-check après reseal" 0
	enc verify
	expect_rc "verify après reseal" 0
	expect_out "verify : Secure Boot actif" '\[ OK \] +Secure Boot actif'
	done_phase 5
	off
	;;
# ===================================================================================
6) # Slot A, Secure Boot actif, après reseal : de nouveau sans passphrase.
	check_root_on A "$D_A"
	check_swap_on
	enc tpm-check
	expect_rc "tpm-check" 0
	enc verify
	expect_rc "verify" 0
	done_phase 6
	off
	;;
*)
	fail "phase inconnue : ${phase:-aucune} (rago_m3_phase=)"
	;;
esac
