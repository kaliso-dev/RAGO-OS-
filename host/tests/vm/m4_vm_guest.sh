#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — partie « invité » du test VM du module M4 (lancée au démarrage par
# rago-m4-test.service, après rago-update-confirm.service). La phase est lue
# sur le petit disque de contrôle (écrit par run_m4_vm_test.sh avant chaque
# démarrage) : la ligne de commande d'une UKI est signée, on ne peut pas y
# glisser la phase. Résultats sur la console série : « RAGO-M4 PASS / FAIL /
# INFO … », puis « RAGO-M4 DONE phase N ».
#
# Disques (tous virtuels, virtio, repérés par leur numéro de série) :
#   rago-inst  installateur (ext4 non chiffré) : racine de la phase 1, journaux
#   rago-a     slot A        rago-b  slot B        rago-swap  swap d'hibernation
#   rago-esp   ESP (GPT, FAT32) : systemd-boot signé, UKI des slots
#   rago-ctl   numéro de phase (écrit par l'hôte)
#
# Aussi appelé DANS le slot qu'écrit « rago-update apply --run » pour y simuler
# une mise à jour cassée :  m4_vm_guest.sh --break hang|emergency
set -u

# --- pannes simulées (dans le chroot du slot en cours d'écriture) ---------------------
if [ "${1:-}" = --break ]; then
	case "${2:-}" in
	hang)
		# Un service dont multi-user.target attend la fin, et qui ne finit jamais.
		cat > /etc/systemd/system/rago-m4-hang.service <<-'EOF'
		[Unit]
		Description=Rago M4 (test) : mise à jour cassée, bloque multi-user.target
		Before=multi-user.target
		[Service]
		Type=oneshot
		ExecStart=/bin/sh -c 'echo "RAGO-M4 HANG slot $(cat /etc/rago-m4-slot 2>/dev/null)" > /dev/ttyS0; exec sleep infinity'
		TimeoutStartSec=infinity
		[Install]
		WantedBy=multi-user.target
		EOF
		mkdir -p /etc/systemd/system/multi-user.target.wants
		ln -sf /etc/systemd/system/rago-m4-hang.service /etc/systemd/system/multi-user.target.wants/rago-m4-hang.service
		;;
	emergency)
		# Un montage obligatoire dont le disque n'existe pas : mode de secours.
		mkdir -p /mnt/absent
		echo "LABEL=rago-m4-absent /mnt/absent ext4 defaults,x-systemd.device-timeout=10s 0 2" >> /etc/fstab
		;;
	*) echo "--break hang|emergency" >&2; exit 2 ;;
	esac
	echo "${RAGO_UPDATE_TARGET_SLOT:-?}" > /etc/rago-m4-slot
	exit 0
fi

# Montages du test dans leur propre espace (voir m3_vm_guest.sh).
if [ -z "${RAGO_M4_PRIVATE_NS:-}" ]; then
	RAGO_M4_PRIVATE_NS=1 exec unshare --mount --propagation private "$0" "$@"
fi

H=/opt/rago-m4/host
S=$H/setup_secure_encryption.sh
K=/opt/rago-m4/kernel/build_rago_kernel.sh
PASSF=/root/m4pass
D_I=/dev/disk/by-id/virtio-rago-inst
D_A=/dev/disk/by-id/virtio-rago-a
D_B=/dev/disk/by-id/virtio-rago-b
D_S=/dev/disk/by-id/virtio-rago-swap
D_E=/dev/disk/by-id/virtio-rago-esp
D_C=/dev/disk/by-id/virtio-rago-ctl
GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
MOKCRT=/etc/rago/secureboot/MOK.crt
FAST=(--iter-time 1000 --pbkdf-memory 131072)
LOG=/root/m4-logs
rm -rf "$LOG"
mkdir -p "$LOG"

pass() { echo "RAGO-M4 PASS $*"; }
fail() { echo "RAGO-M4 FAIL $*"; }
info() { echo "RAGO-M4 INFO $*"; }
n_run=0
# Lance une commande ; sortie (sans couleurs) dans OUT et $LOG/<n>.log, code dans RC.
cmd() {
	n_run=$((n_run + 1))
	OUT=$(timeout 2400 "$@" < /dev/null 2>&1)
	RC=$?
	OUT=$(printf '%s' "$OUT" | sed 's/\x1b\[[0-9;]*m//g')
	printf '$ %s\n%s\n(code %s)\n' "$*" "$OUT" "$RC" > "$LOG/$n_run.log"
}
enc() { cmd "$S" "$@"; }
# rago-update : l'outil installé s'il est là (setup l'installe), sinon celui du dépôt.
upd() { if [ -x /usr/bin/rago-update ]; then cmd /usr/bin/rago-update "$@"; else cmd "$H/manage_atomic_updates.sh" "$@"; fi; }
show() { printf '%s\n' "$OUT" | grep -E "${1:-ÉCHEC|ERREUR|!!}" | head -"${2:-15}" | sed 's/^/RAGO-M4 INFO   | /'; }
show_all() { printf '%s\n' "$OUT" | grep -E '^\s+\[' | sed 's/^/RAGO-M4 INFO   | /'; }
expect_rc() { if [ "$RC" = "$2" ]; then pass "$1 (code $RC)"; else fail "$1 : code $RC, attendu $2"; show '.' 30; fi; }
expect_out() { if grep -Eq -- "$2" <<<"$OUT"; then pass "$1"; else fail "$1 : « $2 » absent"; show '.' 30; fi; }
expect_eq() { if [ "$2" = "$3" ]; then pass "$1 ($3)"; else fail "$1 : « $3 », attendu « $2 »"; fi; }
expect_file() { if [ -e "$2" ]; then pass "$1"; else fail "$1 : $2 absent"; fi; }
expect_nofile() { if [ -e "$2" ]; then fail "$1 : $2 encore là"; else pass "$1"; fi; }
export_logs() { # journaux vers le disque de l'installateur (lus par l'hôte)
	local d=/inst
	if [ "$(readlink -f "$(findmnt -no SOURCE /)")" = "$(readlink -f "$D_I")" ]; then
		d="" # phase 1 : ce disque est la racine
	else
		mkdir -p /inst
		mount "$D_I" /inst 2>/dev/null || return 0
	fi
	mkdir -p "$d/export/logs-$phase"
	cp -r "$LOG"/. "$d/export/logs-$phase/" 2>/dev/null
	journalctl -b -o short-monotonic --no-pager > "$d/export/logs-$phase/journal.txt" 2>/dev/null
	[ -z "$d" ] || umount /inst
}
done_phase() { export_logs; sync; echo "RAGO-M4 DONE phase $1"; sleep 2; }
off() { sync; systemctl poweroff; exit 0; }

efivar() { # variable de systemd-boot (UTF-16LE)
	local f="/sys/firmware/efi/efivars/$1-$GUID"
	[ -r "$f" ] || return 0
	od -An -v -t u1 -j 4 "$f" | awk '{ for (i = 1; i <= NF; i++) b[c++] = $i } END { for (i = 0; i + 1 < c; i += 2) { if (b[i] == 0 && b[i + 1] == 0) break; if (b[i + 1] == 0) printf "%c", b[i] } }'
}
types() { systemd-cryptenroll "$1" 2>/dev/null | awk 'NR > 1 { print $2 }' | sort | tr '\n' ' ' | sed 's/ $//'; }
tokpcrs() { cryptsetup luksDump "$1" | awk '/^Tokens:/ { t = 1 } /^Digests:/ { t = 0 } t && /tpm2-hash-pcrs:/ { print $2 }' | sort | tr '\n' ' ' | sed 's/ $//'; }
signed() { sbverify --cert "$MOKCRT" "$1" > /dev/null 2>&1; }
state() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" /var/lib/rago/update/state 2>/dev/null | tail -1; }
root_slave() {
	local dm s
	dm=$(basename "$(readlink -f "$(findmnt -no SOURCE /)")")
	for s in "/sys/class/block/$dm/slaves"/*; do [ -e "$s" ] && { basename "$s"; break; }; done
}
check_root_on() { # check_root_on <slot> <disque>
	local want
	want=$(basename "$(readlink -f "$2")")
	if [ "$(findmnt -no SOURCE /)" = /dev/mapper/rago-root ] && [ "$(root_slave)" = "$want" ]; then
		pass "racine : rago-root sur le slot $1 ($want), déverrouillée au démarrage"
	else
		fail "racine : $(findmnt -no SOURCE /) sur $(root_slave) (attendu rago-root sur $want, slot $1)"
	fi
}
check_swap_on() {
	local dev
	dev=$(readlink -f /dev/mapper/rago-swap 2>/dev/null)
	if [ -n "$dev" ] && swapon --show=NAME --noheadings | xargs -r readlink -f | grep -qx "$dev"; then
		pass "swap chiffré actif, déverrouillé au démarrage"
	else
		fail "swap chiffré pas actif"
	fi
}
check_booted() { # check_booted <entrée attendue>
	expect_eq "systemd-boot a démarré l'entrée attendue (LoaderEntrySelected)" "$1" "$(efivar LoaderEntrySelected)"
}
check_uki_boot() { # démarré par une UKI mesurée, sans shell dans l'initramfs
	if [ -e "/sys/firmware/efi/efivars/StubPcrKernelImage-$GUID" ]; then pass "UKI mesurée par systemd-stub (PCR $(efivar StubPcrKernelImage))"; else fail "pas de mesure systemd-stub (StubPcrKernelImage absente)"; fi
	local c
	c=" $(cat /proc/cmdline) "
	if [[ "$c" == *" rd.shell=0 "* && "$c" == *" rd.emergency=reboot "* ]]; then pass "ligne de commande de l'UKI : rd.shell=0 rd.emergency=reboot"; else fail "ligne de commande : $(cat /proc/cmdline)"; fi
	sb=$(od -An -t u1 -j 4 -N 1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')
	expect_eq "Secure Boot actif" 1 "$sb"
}
check_trial_watchdog() { # check_trial_watchdog <entrée>
	local f=/run/systemd/generator/multi-user.target.d/50-rago-update-trial.conf
	if [ -f "$f" ]; then pass "chien de garde armé pour l'essai de $1 (générateur)"; else fail "chien de garde pas armé ($f absent)"; fi
	expect_eq "multi-user.target : action si pas atteint à temps" reboot-force "$(systemctl show -P JobTimeoutAction multi-user.target)"
	expect_eq "emergency.target -> rago-update-trial-failed" yes "$(systemctl show -P Wants emergency.target | grep -q rago-update-trial-failed && echo yes || echo no)"
}
check_confirmed() { # check_confirmed <entrée par défaut attendue>
	expect_eq "rago-update-confirm.service a réussi" success "$(systemctl show -P Result rago-update-confirm.service)"
	expect_eq "défaut de systemd-boot (variable EFI)" "$1" "$(efivar LoaderEntryDefault)"
	expect_eq "défaut de systemd-boot (loader.conf)" "$1" "$(awk '$1 == "default" { print $2 }' /boot/loader/loader.conf)"
	expect_eq "plus d'essai en cours" "" "$(state RAGO_UPD_TRIAL)"
}
journal_m4() { journalctl -b -o cat --no-pager -t rago-update 2>/dev/null | tail -4 | sed 's/^/RAGO-M4 INFO   journal | /'; }
cryptsetup_journal() {
	journalctl -b -o cat --no-pager -t systemd-cryptsetup 2>/dev/null | grep -Ei 'tpm|token|passphrase|password|unlock' | sort | uniq -c | head -6 |
		sed 's/^/RAGO-M4 INFO   cryptsetup | /'
}

# --- installateur ---------------------------------------------------------------------
copy_system() {
	cp -ax / /mnt || return 1
	rm -rf /mnt/export /mnt/inst
	cat > /mnt/etc/fstab <<-'EOF'
	/dev/mapper/rago-root / ext4 rw,errors=remount-ro 0 1
	PARTLABEL=rago-esp /boot vfat umask=0077,shortname=winnt 0 2
	EOF
	mkdir -p /mnt/run /mnt/proc /mnt/sys /mnt/dev /mnt/tmp
}
chroot_mounts() { # chroot_mounts on|off : /dev, /proc, /sys, /run et le code testé
	local m
	if [ "$1" = on ]; then
		for m in dev proc sys run; do mount --rbind "/$m" "/mnt/$m" && mount --make-rslave "/mnt/$m"; done
		mkdir -p /mnt/opt/rago-m4
		mount --bind /opt/rago-m4 /mnt/opt/rago-m4
	else
		umount /mnt/opt/rago-m4 2>/dev/null || umount -l /mnt/opt/rago-m4 2>/dev/null
		for m in run sys proc dev; do umount -R "/mnt/$m" 2>/dev/null || umount -R -l "/mnt/$m" 2>/dev/null; done
	fi
}
kver() { printf '%s\n' /usr/lib/modules/* | sort -V | tail -1 | xargs basename; }

# PCR 0 / 7 / 11 de ce démarrage et journal des mesures du firmware (dans les
# journaux exportés) : pour comprendre un refus du TPM.
pcr() { tr -d ' \n' < "/sys/class/tpm/tpm0/pcr-sha256/$1" 2>/dev/null | tr 'A-F' 'a-f'; }
tpm_diag() {
	local p
	for p in 0 7 11; do echo "$p $(pcr "$p")"; done > "$LOG/pcrs.txt"
	tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements > "$LOG/eventlog.txt" 2>&1 || true
	[ ! -f /var/lib/rago/encryption/pcrs-at-enroll ] || cp /var/lib/rago/encryption/pcrs-at-enroll "$LOG/"
	info "PCR : 0=$(pcr 0 | cut -c1-12)… 7=$(pcr 7 | cut -c1-12)… 11=$(pcr 11 | cut -c1-12)…"
}

ctl=$(head -c 512 "$D_C" 2>/dev/null | tr -d '\0')
phase=$(sed -n 's/^phase=\([0-9]*\).*/\1/p' <<<"$ctl")
refresh=$(sed -n 's/^refresh=\([01]\).*/\1/p' <<<"$ctl")
udevadm settle 2>/dev/null
info "phase ${phase:-?} : noyau $(uname -r), $(systemctl --version | head -1), $(ukify --version 2>/dev/null)"
tpm_diag
# Reprise (run_m4_vm_test.sh --resume) : outils installés dans le slot remis au
# niveau du code testé. Mise au point seulement.
if [ "$refresh" = 1 ]; then
	if [ -f /usr/lib/rago/setup_secure_encryption.sh ]; then
		install -m 0755 "$S" /usr/lib/rago/setup_secure_encryption.sh
		install -m 0644 "$H"/lib/rago_*.sh /usr/lib/rago/
	fi
	[ ! -f /etc/rago/update.conf ] || "$H/manage_atomic_updates.sh" --quiet install-files > /dev/null 2>&1
	systemctl daemon-reload
	info "reprise : outils du slot remis à jour depuis le code testé"
fi

case "$phase" in
# ===================================================================================
1) # Installateur : ESP + systemd-boot, M3 (slots chiffrés, TPM), M0 (noyau signé, entrée).
	printf 'label: gpt\ntype=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="rago-esp"\n' | sfdisk -q "$D_E"
	udevadm settle
	for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$D_E-part1" ] && break; sleep 1; done
	if mkfs.vfat -F 32 -n RAGOESP "$D_E-part1" > /dev/null; then pass "ESP : GPT + FAT32"; else fail "ESP : mkfs.vfat"; fi
	for v in "$D_A:root-a" "$D_B:root-b" "$D_S:swap"; do
		enc --virtual-only --yes --passphrase-file "$PASSF" "${FAST[@]}" --device "${v%%:*}" --role "${v##*:}" format
		expect_rc "M3 format ${v##*:}" 0
	done
	enc --device "$D_A" --name rago-root --passphrase-file "$PASSF" open
	expect_rc "slot A ouvert (passphrase)" 0
	mkfs.ext4 -q -F -L rago-a-fs /dev/mapper/rago-root
	mount /dev/mapper/rago-root /mnt || { fail "montage du slot A"; done_phase 1; off; }
	copy_system || fail "copie du système dans le slot A"
	k=$(kver)
	# Comme l'installation du noyau par M0 : l'image avec ses modules (pkgbase),
	# une copie à signer et une initramfs sur l'ESP (/boot).
	mv "/mnt/boot/vmlinuz-$k" "/mnt/usr/lib/modules/$k/vmlinuz"
	echo linux-rago > "/mnt/usr/lib/modules/$k/pkgbase"
	rm -rf /mnt/boot/*
	mount "$D_E-part1" /mnt/boot || fail "montage de l'ESP"
	cp "/mnt/usr/lib/modules/$k/vmlinuz" /mnt/boot/vmlinuz-linux-rago
	: > /mnt/boot/initramfs-linux-rago.img
	mkdir -p /mnt/etc/rago/secureboot
	cp /root/mok/MOK.key /root/mok/MOK.crt /root/mok/MOK.cer /mnt/etc/rago/secureboot/
	chmod 600 /mnt/etc/rago/secureboot/MOK.key
	cat > /mnt/etc/rago/kernel.conf <<-'EOF'
	# Rago OS — options de démarrage du noyau Rago (lu par build_rago_kernel.sh).
	RAGO_CMDLINE="root=/dev/mapper/rago-root rw"
	RAGO_MITIGATIONS=auto
	RAGO_CMDLINE_EXTRA="console=ttyS0,115200 loglevel=4"
	RAGO_ESP=/boot
	EOF
	chroot_mounts on
	cmd chroot /mnt "$S" --root-device "$D_A" --other-slot-device "$D_B" --swap-device "$D_S" install
	expect_rc "M3 install du slot A (chroot, dracut réel)" 0
	cmd chroot /mnt bootctl install --esp-path=/boot
	expect_rc "bootctl install (systemd-boot NON signé, comme sur une vraie machine)" 0
	cmd chroot /mnt env RAGO_KERNEL_IMG=/boot/vmlinuz-linux-rago "$K" sign
	expect_rc "M0 sign : noyau signé par la clé MOK" 0
	cmd chroot /mnt "$K" bootloader
	expect_rc "M0 bootloader : entrée rago.conf + systemd-boot signé" 0
	expect_out "M0 bootloader : systemd-boot signé posé explicitement" 'systemd-boot signé : /boot/EFI/systemd/systemd-bootx64.efi'
	chroot_mounts off
	if sbverify --cert /root/mok/MOK.crt /mnt/boot/EFI/systemd/systemd-bootx64.efi > /dev/null 2>&1; then
		pass "systemd-boot sur l'ESP signé par la clé MOK (bootctl update ne l'aurait pas remplacé : même version)"
	else
		fail "systemd-boot sur l'ESP NON signé"
	fi
	if sbverify --cert /root/mok/MOK.crt /mnt/boot/EFI/BOOT/BOOTX64.EFI > /dev/null 2>&1; then pass "EFI/BOOT/BOOTX64.EFI (systemd-boot) signé aussi"; else fail "EFI/BOOT/BOOTX64.EFI non signé"; fi
	expect_file "entrée de M0 : loader/entries/rago.conf" /mnt/boot/loader/entries/rago.conf
	info "rago.conf : $(grep -E '^(linux|initrd|options)' /mnt/boot/loader/entries/rago.conf | tr '\n' '|')"
	enc --root /mnt --passphrase-file "$PASSF" enroll-tpm
	expect_rc "M3 enroll-tpm (PCR 0+7, base sans M4)" 0
	expect_eq "slot A : passphrase + TPM" "password tpm2" "$(types "$D_A")"
	umount /mnt/boot
	sync
	umount /mnt || umount -l /mnt
	enc --name rago-root close
	done_phase 1
	off
	;;
# ===================================================================================
2) # Entrée de M0 (noyau signé + initramfs), premier vrai démarrage : le jeton TPM
	# posé depuis l'installateur ne vaut pas (l'installateur, démarré par -kernel,
	# n'a pas d'autorité Secure Boot dans PCR 7 ; ici systemd-boot signé MOK en a
	# une) : passphrase de secours tapée. Puis mise en place de M4.
	check_booted rago.conf
	check_root_on A "$D_A"
	check_swap_on
	cryptsetup_journal
	enc tpm-check
	expect_rc "M3 tpm-check : le TPM refuse le jeton de l'installateur" 1
	expect_out "tpm-check : a=refused" '^  a=refused$'
	enc verify
	expect_out "M3 verify : PCR 7 changé depuis l'enrôlement (autre chaîne de démarrage)" 'PCR 7 changés depuis l.enrôlement'
	upd check
	info "rago-update check (code $RC) :"
	show_all
	expect_out "check : slot A en marche" '\[ OK \] +slot en marche : A'
	expect_out "check : UKI possible" '\[ OK \] +UKI possible : ukify'
	expect_out "check : systemd-boot signé MOK" '\[ OK \] +systemd-boot signé par la clé MOK'
	expect_out "check : Secure Boot actif" '\[ OK \] +Secure Boot actif'
	upd --passphrase-file "$PASSF" setup
	expect_rc "rago-update setup" 0
	show 'UKI|essai|TPM|!!' 12
	expect_out "setup : UKI du slot A signée avec la clé MOK" 'UKI signée avec la clé MOK'
	expect_file "setup : rago-update installé" /usr/bin/rago-update
	expect_file "setup : UKI sur l'ESP (EFI/Linux/rago-a.efi)" /boot/EFI/Linux/rago-a.efi
	if signed /boot/EFI/Linux/rago-a.efi; then pass "UKI A signée par la clé MOK (sbverify)"; else fail "UKI A pas signée"; fi
	objcopy -O binary --only-section=.rago /boot/EFI/Linux/rago-a.efi /root/rago-a.rago 2>/dev/null
	expect_eq "UKI A : métadonnée slot (section .rago, lue par objcopy)" a "$(sed -n 's/^slot=//p' /root/rago-a.rago 2>/dev/null)"
	expect_eq "essai armé : entrée à usage unique" rago-a.efi "$(efivar LoaderEntryOneShot)"
	expect_eq "repli : l'entrée de M0 reste le défaut" rago.conf "$(efivar LoaderEntryDefault)"
	expect_eq "loader.conf : éditeur coupé" no "$(awk '$1 == "editor" { print $2 }' /boot/loader/loader.conf)"
	expect_eq "slot A : passphrase + jetons M0 (PCR 0+7) et UKI A (PCR 0+7+11)" "0+7 0+7+11" "$(tokpcrs "$D_A")"
	expect_eq "slot A : la passphrase reste" "password tpm2 tpm2" "$(types "$D_A")"
	expect_eq "swap : jetons M0 et UKI A" "0+7 0+7+11" "$(tokpcrs "$D_S")"
	expect_eq "slot B (pas encore écrit) : passphrase seule" "password" "$(types "$D_B")"
	if is=$(systemctl is-enabled rago-update-confirm.service 2>&1); then pass "rago-update-confirm.service activé"; else fail "rago-update-confirm.service : $is"; fi
	sed -i 's/^RAGO_AB_TRIAL_TIMEOUT=.*/RAGO_AB_TRIAL_TIMEOUT="420"/' /etc/rago/update.conf
	upd verify
	expect_rc "rago-update verify : redémarrage attendu (essai armé)" 3
	expect_out "verify : essai de rago-a.efi armé" '\[ REDÉMARRER \] +essai de rago-a\.efi armé'
	expect_out "verify : rago.conf reste le défaut jusqu'à la confirmation" '\[ OK \] +défaut : rago\.conf'
	show_all
	done_phase 2
	off
	;;
# ===================================================================================
3) # Essai de l'UKI A : TPM par PCR 11 prédit, confirmation, M0 retiré, slot B écrit.
	check_booted rago-a.efi
	check_uki_boot
	check_root_on A "$D_A"
	check_swap_on
	cryptsetup_journal
	check_trial_watchdog rago-a.efi
	check_confirmed rago-a.efi
	journal_m4
	expect_nofile "entrée de M0 retirée" /boot/loader/entries/rago.conf
	expect_nofile "noyau nu signé de M0 retiré de l'ESP" /boot/vmlinuz-linux-rago
	expect_nofile "initramfs de M0 retirée" /boot/initramfs-linux-rago.img
	expect_eq "slot A : seul le jeton de l'UKI reste (PCR 0+7+11)" "0+7+11" "$(tokpcrs "$D_A")"
	expect_eq "slot A : passphrase gardée" "password tpm2" "$(types "$D_A")"
	upd verify
	expect_rc "rago-update verify (UKI A)" 0
	expect_out "verify : PCR 11 mesuré = PCR 11 prédit" '\[ OK \] +PCR 11 mesuré = prédit pour rago-a.efi'
	show_all
	upd --passphrase-file "$PASSF" apply --clone --run 'echo slot-b > /etc/rago-m4-mark'
	expect_rc "rago-update apply --clone (slot B)" 0
	show 'slot B|essai|!!' 12
	expect_file "UKI B sur l'ESP" /boot/EFI/Linux/rago-b.efi
	if signed /boot/EFI/Linux/rago-b.efi; then pass "UKI B signée par la clé MOK"; else fail "UKI B pas signée"; fi
	expect_eq "essai de B armé" rago-b.efi "$(efivar LoaderEntryOneShot)"
	expect_eq "défaut toujours A (dernier bon connu)" rago-a.efi "$(efivar LoaderEntryDefault)"
	expect_eq "slot B : jeton de son UKI" "0+7+11" "$(tokpcrs "$D_B")"
	expect_eq "swap : jetons des UKI A et B" "0+7+11 0+7+11" "$(tokpcrs "$D_S")"
	expect_nofile "slot B refermé après écriture" /dev/mapper/rago-update-b
	if ! findmnt -rn -o TARGET | grep -q '/run/rago/update'; then pass "aucun montage laissé par apply"; else fail "montages laissés : $(findmnt -rn -o TARGET | grep /run/rago/update | tr '\n' ' ')"; fi
	done_phase 3
	off
	;;
# ===================================================================================
4) # Essai du slot B : sa racine, son UKI ; confirmation ; slot A réécrit CASSÉ (blocage).
	check_booted rago-b.efi
	check_uki_boot
	check_root_on B "$D_B"
	check_swap_on
	check_trial_watchdog rago-b.efi
	check_confirmed rago-b.efi
	expect_eq "contenu du nouveau slot (apply --run)" slot-b "$(cat /etc/rago-m4-mark 2>/dev/null)"
	expect_eq "réglages M3 du slot B" b "$(sed -n 's/^RAGO_ENC_SLOT="\(.*\)"$/\1/p' /etc/rago/encryption.conf)"
	upd verify
	expect_rc "rago-update verify (slot B)" 0
	upd --passphrase-file "$PASSF" apply --clone --bind /opt/rago-m4 --run '/opt/rago-m4/host/tests/vm/m4_vm_guest.sh --break hang'
	expect_rc "apply --clone d'un slot A cassé (service qui bloque le démarrage)" 0
	expect_eq "essai de A armé" rago-a.efi "$(efivar LoaderEntryOneShot)"
	expect_eq "défaut : B" rago-b.efi "$(efivar LoaderEntryDefault)"
	done_phase 4
	off
	;;
# ===================================================================================
6) # Retour automatique sur B après le blocage de A (chien de garde).
	check_booted rago-b.efi
	check_root_on B "$D_B"
	expect_out_state=$(state RAGO_UPD_LAST)
	if grep -q "ÉCHEC de l'essai de rago-a.efi" <<<"$expect_out_state"; then pass "échec de l'essai de A constaté sur B : $expect_out_state"; else fail "état : $expect_out_state"; fi
	journal_m4
	upd status
	info "rago-update status :"
	printf '%s\n' "$OUT" | sed 's/^/RAGO-M4 INFO   | /'
	upd --passphrase-file "$PASSF" apply --clone --bind /opt/rago-m4 --run '/opt/rago-m4/host/tests/vm/m4_vm_guest.sh --break emergency'
	expect_rc "apply --clone d'un slot A cassé (montage impossible : mode de secours)" 0
	expect_eq "essai de A armé" rago-a.efi "$(efivar LoaderEntryOneShot)"
	done_phase 6
	off
	;;
# ===================================================================================
8) # Retour sur B après le mode de secours de A ; puis UKI A MODIFIÉE (evil maid).
	check_booted rago-b.efi
	check_root_on B "$D_B"
	st=$(state RAGO_UPD_LAST)
	if grep -q "ÉCHEC de l'essai de rago-a.efi" <<<"$st"; then pass "2e échec de l'essai de A constaté : $st"; else fail "état : $st"; fi
	python3 - /boot/EFI/Linux/rago-a.efi <<-'EOF'
	import sys
	p = sys.argv[1]
	d = bytearray(open(p, "rb").read())
	i = d.find(b"rd.shell=0")
	d[i + 9] = ord("1")  # rd.shell=1 : un shell dans l'initramfs après le déverrouillage
	open(p, "wb").write(bytes(d))
	EOF
	if signed /boot/EFI/Linux/rago-a.efi; then fail "UKI A modifiée : sbverify l'accepte encore"; else pass "UKI A modifiée (rd.shell=0 -> rd.shell=1) : signature invalide (sbverify)"; fi
	upd verify
	expect_rc "verify : UKI modifiée détectée" 1
	expect_out "verify : rago-a.efi PAS signée" 'ÉCHEC.*rago-a.efi : PAS signée par la clé MOK'
	bootctl set-oneshot rago-a.efi
	expect_eq "démarrage unique de l'UKI modifiée demandé" rago-a.efi "$(efivar LoaderEntryOneShot)"
	done_phase 8
	off
	;;
# ===================================================================================
10) # L'UKI modifiée a été refusée par Secure Boot : B démarre. Re-scellement impossible.
	check_booted rago-b.efi
	check_root_on B "$D_B"
	expect_eq "entrée unique consommée" "" "$(efivar LoaderEntryOneShot)"
	rm -f /boot/EFI/Linux/rago-a.efi
	sed -i 's/^RAGO_CMDLINE_EXTRA=.*/RAGO_CMDLINE_EXTRA="console=ttyS0,115200 loglevel=4 rago.m4=next"/' /etc/rago/kernel.conf
	upd uki
	expect_rc "rago-update uki sans passphrase ni terminal : pas bloquant" 0
	expect_out "uki : TPM pas re-scellé, dit" 'TPM pas re-scellé'
	expect_out "uki : la passphrase sera demandée au démarrage" 'passphrase de secours sera demandée'
	expect_file "UKI reconstruite à l'essai" /boot/EFI/Linux/rago-b.next.efi
	expect_eq "essai armé" rago-b.next.efi "$(efivar LoaderEntryOneShot)"
	expect_eq "slot B : pas de jeton pour la nouvelle UKI, l'ancien reste" "0+7+11" "$(tokpcrs "$D_B")"
	journal_m4
	done_phase 10
	off
	;;
# ===================================================================================
11) # Essai de la nouvelle UKI B sans jeton : passphrase de secours tapée, puis reseal.
	check_booted rago-b.next.efi
	check_uki_boot
	check_root_on B "$D_B"
	cryptsetup_journal
	check_trial_watchdog rago-b.next.efi
	check_confirmed rago-b.efi
	expect_nofile "UKI à l'essai renommée" /boot/EFI/Linux/rago-b.next.efi
	case " $(cat /proc/cmdline) " in *" rago.m4=next "*) pass "nouvelle ligne de commande en place" ;; *) fail "ligne de commande : $(cat /proc/cmdline)" ;; esac
	enc tpm-check
	expect_rc "tpm-check : jeton manquant signalé" 1
	expect_out "tpm-check : b=refused" '^  b=refused$'
	enc --passphrase-file "$PASSF" reseal
	expect_rc "rago-encryption reseal (passphrase de secours)" 0
	expect_eq "slot B : un jeton (nouvelle UKI), ancien retiré" "0+7+11" "$(tokpcrs "$D_B")"
	expect_eq "slot B : passphrase gardée" "password tpm2" "$(types "$D_B")"
	expect_eq "slot A (aucune UKI valide) : passphrase seule, jamais de jeton pour l'UKI modifiée" "password" "$(types "$D_A")"
	expect_eq "swap : un jeton (UKI B)" "0+7+11" "$(tokpcrs "$D_S")"
	enc tpm-check
	expect_rc "tpm-check après reseal" 0
	done_phase 11
	off
	;;
# ===================================================================================
12) # Slot B, nouvelle UKI : de nouveau sans passphrase. Bilan.
	check_booted rago-b.efi
	check_uki_boot
	check_root_on B "$D_B"
	check_swap_on
	upd verify
	expect_rc "rago-update verify final" 0
	show_all
	enc tpm-check
	expect_rc "tpm-check final" 0
	done_phase 12
	off
	;;
*)
	fail "phase inattendue : ${phase:-aucune} (disque de contrôle)"
	done_phase "${phase:-0}"
	off
	;;
esac
