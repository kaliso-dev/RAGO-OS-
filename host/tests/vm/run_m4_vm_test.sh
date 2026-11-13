#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — test du module M4 dans une VM qemu jetable : UEFI (OVMF) avec Secure
# Boot ACTIF du début à la fin (PK de test + clé MOK de test créée par M0
# « mok-gen », inscrite dans la db), TPM 2.0 émulé (swtpm), disques VIRTUELS
# seulement (fichiers jetables). Jamais de vrai disque, de vrai TPM ni de vraie
# clé : tout est créé ici et jeté à la fin.
#
# Douze démarrages (détail : host/tests/vm/m4_vm_guest.sh) :
#   1  installateur : ESP + systemd-boot, slots A / B et swap chiffrés (M3),
#      noyau signé + entrée rago.conf (M0), TPM en PCR 0+7
#   2  entrée de M0 : le jeton de l'installateur est refusé (démarré par -kernel,
#      il n'a pas l'autorité Secure Boot que systemd-boot met dans PCR 7) :
#      passphrase de secours tapée ; rago-update setup (UKI A signée MOK,
#      jetons PCR 0+7+11 pris sur la vraie chaîne de démarrage)
#   3  essai de l'UKI A : déverrouillée par le TPM avec PCR 11 PRÉDIT,
#      confirmation, entrée de M0 retirée, slot B écrit (apply --clone)
#   4  essai du slot B : confirmation ; slot A réécrit CASSÉ (service bloquant)
#   5  essai de A : bloqué ; le chien de garde redémarre (pas de script invité)
#   6  retour automatique sur B ; slot A réécrit CASSÉ (montage impossible)
#   7  essai de A : mode de secours, redémarrage immédiat (pas de script invité)
#   8  retour sur B ; UKI A MODIFIÉE (rd.shell=1), démarrage unique demandé
#   9  Secure Boot REFUSE l'UKI modifiée (message de systemd-boot)
#  10  B : nouvelle UKI B sans passphrase : TPM pas re-scellé, dit, essai armé
#  11  essai de la nouvelle UKI B : passphrase de secours tapée, reseal
#  12  B : de nouveau déverrouillé par le TPM seul
#
# Le code testé (host/, kernel/) est sur un petit disque à part, refait à chaque
# lancement et monté par l'invité sur /opt/rago-m4. Après chaque démarrage
# réussi, les disques (qcow2), les variables UEFI et l'état du TPM sont gardés
# (instantané pN) : --resume N relance à partir du démarrage N avec le code
# actuel (outils installés dans le slot remis à jour ; pour la mise au point
# seulement : la validation est un passage complet).
#
# Limites : base Ubuntu 26.04 (dracut 110, systemd 259, ukify) et non Arch /
# base Rago (mkinitcpio non testé ici) ; noyau Ubuntu (signé Canonical, embarqué
# tel quel dans l'UKI) et non le noyau Rago ; pas de shim (clé MOK dans la db) ;
# émulation TCG lente ; un vrai firmware, un vrai TPM et le clavier réel restent
# à tester sur le matériel.
#
# Usage (root : chroot, mkfs, qemu) :
#   run_m4_vm_test.sh [--rootfs DIR] [--keep] [--work DIR --resume N]
#   --rootfs DIR   système de base déjà préparé (sinon construit ; ~1 Go)
#   --keep         garde le dossier de travail (journaux, images, instantanés)
#   --work DIR     dossier de travail (avec --resume : celui d'un passage gardé)
#   --resume N     reprend au démarrage N (instantané pN-1 du dossier --work)
#
# Dépendances : debootstrap, qemu-system-x86_64, qemu-img, OVMF (secboot),
# virt-fw-vars (paquet python3-virt-firmware), swtpm, sbsign / sbverify,
# openssl, mkfs.ext4, debugfs, python3, accès au miroir Ubuntu (construction).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
rootfs=""
keep=0
work=""
resume=1
MIRROR=${RAGO_UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
SUITE=${RAGO_M4_SUITE:-resolute}
OVMF_DIR=${RAGO_OVMF_DIR:-/usr/share/OVMF}
OVMF_CODE="$OVMF_DIR/OVMF_CODE_4M.secboot.fd"
OVMF_VARS="$OVMF_DIR/OVMF_VARS_4M.fd"
PASSPHRASE="Rago-secours-M4-test"
# Propriétaire (GUID) des certificats de test dans PK / KEK / db : « RAGO OS M4 ».
OWNER=5241474f-4f53-4d34-8000-000000000001
DISKS="esp a b swap"

while [ $# -gt 0 ]; do
	case "$1" in
	--rootfs) rootfs=$2; shift 2 ;;
	--keep) keep=1; shift ;;
	--work) work=$2; shift 2 ;;
	--resume) resume=$2; shift 2 ;;
	-h | --help) sed -n '3,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) echo "option inconnue : $1" >&2; exit 2 ;;
	esac
done
case "$resume" in '' | *[!0-9]*) echo "--resume : numéro de démarrage" >&2; exit 2 ;; esac
if [ "$resume" -lt 1 ] || [ "$resume" -gt 12 ]; then echo "--resume : 1 à 12" >&2; exit 2; fi
[ "$resume" = 1 ] || [ -n "$work" ] || { echo "--resume va avec --work (dossier d'un passage gardé)" >&2; exit 2; }

[ "$(id -u)" -eq 0 ] || { echo "à lancer en root (chroot, mkfs, qemu)" >&2; exit 2; }
for t in qemu-system-x86_64 qemu-img swtpm virt-fw-vars sbsign sbverify openssl mkfs.ext4 debugfs python3; do
	command -v "$t" >/dev/null || { echo "outil manquant : $t" >&2; exit 2; }
done
for f in "$OVMF_CODE" "$OVMF_VARS"; do
	[ -f "$f" ] || { echo "fichier manquant : $f (paquet ovmf)" >&2; exit 2; }
done

if [ -n "$work" ]; then
	mkdir -p "$work"
	work=$(cd "$work" && pwd)
	keep=1
else
	work=$(mktemp -d /var/tmp/rago-m4-vm.XXXXXX)
fi
mounted=""
# shellcheck disable=SC2317  # appelée par trap
cleanup() {
	local m
	for m in $mounted; do umount "$m" 2>/dev/null || true; done
	pkill -f "swtpm socket --tpmstate dir=$work/tpm" 2>/dev/null || true
	if [ "$keep" = 1 ]; then echo "dossier gardé : $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# --- disque du code testé (refait à chaque lancement) -----------------------------------
mkdir -p "$work/repo"
rm -rf "$work/repo/host" "$work/repo/kernel"
cp -a "$repo/host" "$work/repo/host"
mkdir -p "$work/repo/kernel"
for d in "$repo/kernel"/*; do
	case "${d##*/}" in build | out) continue ;; esac
	cp -a "$d" "$work/repo/kernel/"
done
rm -f "$work/repo.img"
truncate -s 64M "$work/repo.img"
mkfs.ext4 -q -F -L rago-m4-repo -d "$work/repo" "$work/repo.img"
printf '%s' "$PASSPHRASE" > "$work/pass"
chmod 600 "$work/pass"

if [ "$resume" = 1 ]; then
	# --- système de base (Ubuntu 26.04 : dracut, systemd 259, ukify, systemd-boot) --------
	PKGS="dracut zstd linux-image-virtual cryptsetup cryptsetup-bin systemd-cryptsetup tpm2-tools fdisk e2fsprogs util-linux kbd dbus systemd-boot systemd-boot-efi systemd-ukify python3-pefile sbsigntool dosfstools openssl rsync binutils"
	build_rootfs() {
		local d=$1 script=""
		command -v debootstrap >/dev/null || { echo "outil manquant : debootstrap" >&2; exit 2; }
		[ -e "/usr/share/debootstrap/scripts/$SUITE" ] || script=/usr/share/debootstrap/scripts/gutsy
		echo "==> debootstrap Ubuntu $SUITE dans $d"
		# shellcheck disable=SC2086
		debootstrap --variant=minbase --include=systemd-sysv,udev,dbus,kmod,procps,iproute2 \
			--components=main,universe "$SUITE" "$d" "$MIRROR" $script > "$work/debootstrap.log" 2>&1 ||
			{ tail -20 "$work/debootstrap.log"; exit 1; }
		echo "deb $MIRROR $SUITE main universe" > "$d/etc/apt/sources.list"
		cp /etc/resolv.conf "$d/etc/resolv.conf" 2>/dev/null || true
		for m in proc sys dev; do mount --bind "/$m" "$d/$m"; mounted="$d/$m $mounted"; done
		# dracut d'abord : l'initramfs du noyau est alors faite par dracut.
		chroot "$d" bash -c "export DEBIAN_FRONTEND=noninteractive
			apt-get update -q && apt-get install -y -q --no-install-recommends dracut dracut-core zstd &&
			apt-get install -y -q --no-install-recommends $PKGS" > "$work/apt.log" 2>&1 ||
			{ tail -20 "$work/apt.log"; exit 1; }
		for m in proc sys dev; do umount "$d/$m"; done
		mounted=""
	}
	if [ -z "$rootfs" ]; then rootfs="$work/rootfs"; fi
	if [ ! -x "$rootfs/usr/bin/ukify" ] || [ ! -x "$rootfs/usr/bin/dracut" ] || [ ! -f "$rootfs/usr/lib/systemd/boot/efi/linuxx64.efi.stub" ]; then
		build_rootfs "$rootfs"
	fi
	kernel=$(find "$rootfs/boot" -name 'vmlinuz-*-generic' | sort -V | tail -1)
	kver=${kernel##*/vmlinuz-}
	[ -f "$rootfs/boot/initrd.img-$kver" ] || { echo "initramfs absente pour $kver" >&2; exit 1; }

	# --- clés de TEST : PK (firmware) et clé MOK (créée par M0, comme sur la machine) -----
	echo "==> clés de test (dans $work) : PK + MOK (M0 mok-gen), Secure Boot actif"
	openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 30 -subj "/CN=Rago OS M4 test PK (VM, jetable)" \
		-keyout "$work/pk.key" -out "$work/pk.crt" > /dev/null 2>&1
	RAGO_MOK_DIR="$work/mok" bash "$repo/kernel/build_rago_kernel.sh" mok-gen > "$work/mok-gen.log" 2>&1 ||
		{ cat "$work/mok-gen.log"; exit 1; }
	virt-fw-vars --input "$OVMF_VARS" --output "$work/vars.fd" --enroll-cert "$work/pk.crt" --no-microsoft \
		--add-db "$OWNER" "$work/mok/MOK.crt" --sb > "$work/vars.log" 2>&1 || { cat "$work/vars.log"; exit 1; }
	# Noyau de l'installateur signé avec la clé MOK (démarrage 1 : Secure Boot actif).
	sbsign --key "$work/mok/MOK.key" --cert "$work/mok/MOK.crt" --output "$work/vmlinuz-inst" "$kernel" > /dev/null 2>&1
	sbverify --cert "$work/mok/MOK.crt" "$work/vmlinuz-inst" > /dev/null 2>&1 || { echo "signature du noyau impossible" >&2; exit 1; }
	cp "$rootfs/boot/initrd.img-$kver" "$work/initrd-inst.img"

	# --- image de l'installateur ----------------------------------------------------------
	echo "==> préparation des disques virtuels (dans $work)"
	img="$work/instroot"
	rm -rf "$img"
	cp -a "$rootfs" "$img"
	mkdir -p "$img/opt/rago-m4" "$img/export" "$img/root/mok"
	cp "$work/mok/MOK.key" "$work/mok/MOK.crt" "$work/mok/MOK.cer" "$img/root/mok/"
	chmod 600 "$img/root/mok/MOK.key"
	cp "$work/pass" "$img/root/m4pass"
	chmod 600 "$img/root/m4pass"
	echo "LABEL=rago-inst / ext4 rw,errors=remount-ro 0 1" > "$img/etc/fstab"
	echo rago-m4-vm > "$img/etc/hostname"
	rm -rf "$img/var/lib/rago" "$img/etc/rago" "$img/etc/crypttab"
	ln -sf /dev/null "$img/etc/systemd/system/serial-getty@ttyS0.service"
	mkdir -p "$img/usr/local/sbin"
	cat > "$img/usr/local/sbin/rago-m4-boot" <<-'EOF'
	#!/bin/sh
	# Rago OS — test VM M4 : monte le disque du code testé, puis lance la phase.
	mkdir -p /opt/rago-m4
	for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e /dev/disk/by-id/virtio-rago-repo ] && break; udevadm settle; sleep 1; done
	mountpoint -q /opt/rago-m4 || mount -o ro /dev/disk/by-id/virtio-rago-repo /opt/rago-m4 ||
		{ echo "RAGO-M4 FAIL disque du code testé introuvable"; echo "RAGO-M4 DONE phase ?"; exit 1; }
	exec /opt/rago-m4/host/tests/vm/m4_vm_guest.sh
	EOF
	chmod 755 "$img/usr/local/sbin/rago-m4-boot"
	cat > "$img/etc/systemd/system/rago-m4-test.service" <<-'EOF'
	[Unit]
	Description=Rago OS : test VM du module M4
	After=multi-user.target rago-update-confirm.service
	[Service]
	Type=oneshot
	ExecStart=/usr/local/sbin/rago-m4-boot
	TimeoutStartSec=infinity
	StandardOutput=tty
	StandardError=tty
	TTYPath=/dev/ttyS0
	[Install]
	WantedBy=multi-user.target
	EOF
	ln -sf /etc/systemd/system/rago-m4-test.service "$img/etc/systemd/system/multi-user.target.wants/rago-m4-test.service"
	rm -f "$work/inst.img"
	truncate -s 4G "$work/inst.img"
	mkfs.ext4 -q -F -L rago-inst -d "$img" "$work/inst.img"
	rm -rf "$img"
	for d in $DISKS; do rm -f "$work/$d.qcow2"; done
	qemu-img create -q -f qcow2 "$work/esp.qcow2" 1G
	qemu-img create -q -f qcow2 "$work/a.qcow2" 4G
	qemu-img create -q -f qcow2 "$work/b.qcow2" 4G
	qemu-img create -q -f qcow2 "$work/swap.qcow2" 1G
	rm -rf "$work/tpm"
	mkdir -p "$work/tpm"
	rm -f "$work"/serial*.log "$work"/serial*.txt "$work"/agent* "$work/results"
else
	# --- reprise : instantané du démarrage précédent --------------------------------------
	p=$((resume - 1))
	echo "==> reprise au démarrage $resume (instantané p$p de $work)"
	for d in $DISKS; do qemu-img snapshot -a "p$p" "$work/$d.qcow2" || { echo "instantané p$p absent ($d)" >&2; exit 1; }; done
	cp "$work/vars-p$p.fd" "$work/vars.fd"
	rm -rf "$work/tpm"
	cp -a "$work/tpm-p$p" "$work/tpm"
	sed -i "/^${resume}[ :]/,\$d" "$work/results" 2>/dev/null || true
fi
truncate -s 1M "$work/ctl.img"

# Fichier de l'image de l'installateur (lu sans la monter).
inst_rdump() { debugfs -R "rdump $1 $2" "$work/inst.img" > /dev/null 2>&1 || true; }

snapshot() { # instantané pN : disques, variables UEFI, TPM
	local n=$1 d
	for d in $DISKS; do
		qemu-img snapshot -d "p$n" "$work/$d.qcow2" 2>/dev/null || true
		qemu-img snapshot -c "p$n" "$work/$d.qcow2"
	done
	cp "$work/vars.fd" "$work/vars-p$n.fd"
	rm -rf "$work/tpm-p$n"
	cp -a "$work/tpm" "$work/tpm-p$n"
	rm -f "$work/tpm-p$n/sock"
}

QRC=0
boot() { # boot <n> <agent : forbid|type|refuse> <délai s> <refresh 0|1>
	local n=$1 mode=$2 tmo=$3 refresh=$4 qpid arc=0 t0 kargs=()
	echo "==> démarrage $n de la VM ($(date +%H:%M:%S), TCG : plusieurs minutes)"
	dd if=/dev/zero of="$work/ctl.img" bs=512 count=1 conv=notrunc status=none
	printf 'phase=%s\nrefresh=%s\n' "$n" "$refresh" | dd of="$work/ctl.img" conv=notrunc status=none
	swtpm socket --tpmstate dir="$work/tpm" --ctrl type=unixio,path="$work/tpm/sock" --tpm2 \
		--terminate --daemon --log file="$work/swtpm$n.log"
	rm -f "$work/serial$n.sock"
	if [ "$n" = 1 ]; then
		kargs=(-kernel "$work/vmlinuz-inst" -initrd "$work/initrd-inst.img"
			-append "root=LABEL=rago-inst rw console=ttyS0,115200 loglevel=4")
	fi
	t0=$(date +%s)
	# L'ESP en premier : sans entrée UEFI (bootctl dans un chroot n'en crée pas),
	# OVMF essaie les disques dans l'ordre et démarre EFI/BOOT/BOOTX64.EFI.
	# -no-reboot : un redémarrage du système (chien de garde) arrête qemu.
	timeout "$tmo" qemu-system-x86_64 \
		-machine q35,smm=on -accel tcg,thread=multi -cpu max -smp 4 -m 3072 \
		-global driver=cfi.pflash01,property=secure,value=on \
		-drive "if=pflash,format=raw,unit=0,file=$OVMF_CODE,readonly=on" \
		-drive "if=pflash,format=raw,unit=1,file=$work/vars.fd" \
		-chardev "socket,id=chrtpm,path=$work/tpm/sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
		-display none -monitor none -no-reboot -nic none \
		-chardev "socket,id=ser0,path=$work/serial$n.sock,server=on,wait=off,logfile=$work/serial$n.log" -serial chardev:ser0 \
		"${kargs[@]}" \
		-drive "file=$work/esp.qcow2,if=none,id=de,format=qcow2" -device virtio-blk-pci,drive=de,serial=rago-esp \
		-drive "file=$work/inst.img,if=none,id=di,format=raw" -device virtio-blk-pci,drive=di,serial=rago-inst \
		-drive "file=$work/a.qcow2,if=none,id=da,format=qcow2" -device virtio-blk-pci,drive=da,serial=rago-a \
		-drive "file=$work/b.qcow2,if=none,id=db,format=qcow2" -device virtio-blk-pci,drive=db,serial=rago-b \
		-drive "file=$work/swap.qcow2,if=none,id=ds,format=qcow2" -device virtio-blk-pci,drive=ds,serial=rago-swap \
		-drive "file=$work/ctl.img,if=none,id=dc,format=raw" -device virtio-blk-pci,drive=dc,serial=rago-ctl \
		-drive "file=$work/repo.img,if=none,id=dr,format=raw,readonly=on" -device virtio-blk-pci,drive=dr,serial=rago-repo \
		> "$work/qemu$n.log" 2>&1 &
	qpid=$!
	python3 "$here/m3_serial_agent.py" "$work/serial$n.sock" "$mode" "$work/pass" "$tmo" "$work/agent$n" || arc=$?
	case "$arc" in
	10) echo "    passphrase demandée alors que le TPM devait déverrouiller (ou l'image devait être refusée) : VM arrêtée"; kill "$qpid" 2>/dev/null || true ;;
	11) echo "    refus du firmware vu sur la console : VM arrêtée"; kill "$qpid" 2>/dev/null || true ;;
	esac
	QRC=0
	wait "$qpid" || QRC=$?
	[ "$QRC" = 124 ] && echo "    qemu $n : délai de $tmo s dépassé"
	pkill -f "swtpm socket --tpmstate dir=$work/tpm" 2>/dev/null || true
	tr -d '\r' < "$work/serial$n.log" > "$work/serial$n.txt" 2>/dev/null || true
	grep -a 'RAGO-M4 \|RAGO-UPDATE' "$work/serial$n.txt" || true
	echo "    console : $(cat "$work/agent$n" 2>/dev/null) ; qemu : code $QRC ; $(($(date +%s) - t0)) s"
	mkdir -p "$work/guest"
	inst_rdump "/export/logs-$n" "$work/guest"
	[ ! -d "$work/guest/logs-$n" ] || echo "    journaux de l'invité : $work/guest/logs-$n"
	return 0
}

host_ok() { echo "HÔTE PASS démarrage $1 : $2"; echo "$1: PASS $2" >> "$work/results"; }
host_ko() { echo "HÔTE FAIL démarrage $1 : $2"; echo "$1: FAIL $2" >> "$work/results"; }
gfails() { grep -ac 'RAGO-M4 FAIL' "$work/serial$1.txt" 2>/dev/null || true; }
gpass() { grep -ac 'RAGO-M4 PASS' "$work/serial$1.txt" 2>/dev/null || true; }
done_ok() { grep -aq "RAGO-M4 DONE phase $1" "$work/serial$1.txt" 2>/dev/null; }
agent_said() { cat "$work/agent$1" 2>/dev/null || echo "?"; }

# Démarrage avec script invité : fini, sans échec, sans passphrase (ou tapée).
# Code 1 = échec dur (script pas fini, passphrase inattendue) : on s'arrête là.
check_guest() { # check_guest <n> <forbid|type>
	local n=$1 mode=$2 f hard=0
	f=$(gfails "$n")
	case "$mode" in
	forbid) if grep -q '^prompts=0 ' "$work/agent$n" 2>/dev/null; then host_ok "$n" "aucune passphrase demandée (TPM seul)"; else host_ko "$n" "console : $(agent_said "$n")"; hard=1; fi ;;
	type) if grep -q '^prompts=[1-9].* typed=[1-9]' "$work/agent$n" 2>/dev/null; then host_ok "$n" "passphrase de secours demandée puis tapée ($(agent_said "$n"))"; else host_ko "$n" "passphrase de secours pas demandée ($(agent_said "$n"))"; hard=1; fi ;;
	esac
	if ! done_ok "$n"; then host_ko "$n" "le script invité n'a pas fini (qemu : code $QRC)"; return 1; fi
	if [ "$f" -eq 0 ]; then host_ok "$n" "$(gpass "$n") vérifications de l'invité, aucune en échec"; else host_ko "$n" "$f vérification(s) de l'invité en échec"; fi
	[ "$hard" = 0 ]
}

# --- les douze démarrages --------------------------------------------------------------------
refresh=0
[ "$resume" = 1 ] || refresh=1
stop=0
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
	[ "$n" -ge "$resume" ] || continue
	[ "$stop" = 0 ] || break
	case "$n" in
	1 | 3 | 4 | 6) boot "$n" forbid 2700 "$refresh"; check_guest "$n" forbid || stop=1 ;;
	8 | 10 | 12) boot "$n" forbid 1800 "$refresh"; check_guest "$n" forbid || stop=1 ;;
	2) boot "$n" type 2700 "$refresh"; check_guest "$n" type || stop=1 ;;
	11) boot "$n" type 1800 "$refresh"; check_guest "$n" type || stop=1 ;;
	5)
		# Le slot A cassé bloque multi-user.target : le chien de garde de l'essai
		# (JobTimeoutSec) redémarre ; -no-reboot arrête alors qemu.
		boot "$n" forbid 1800 "$refresh"
		if grep -aq 'RAGO-M4 HANG slot a' "$work/serial$n.txt"; then host_ok "$n" "slot A cassé démarré (service bloquant atteint), déverrouillé par le TPM"; else host_ko "$n" "le service bloquant du slot A n'a pas démarré"; stop=1; fi
		if [ "$QRC" = 0 ] && ! done_ok "$n"; then
			host_ok "$n" "multi-user.target jamais atteint : redémarrage forcé par le chien de garde ($(grep -aoE 'Forcibly rebooting[^.]*|timed out[^.]*' "$work/serial$n.txt" | head -1))"
		else
			host_ko "$n" "pas de redémarrage par le chien de garde (qemu : code $QRC)"; stop=1
		fi
		grep -q '^prompts=0 ' "$work/agent$n" 2>/dev/null || { host_ko "$n" "console : $(agent_said "$n")"; stop=1; }
		;;
	7)
		boot "$n" forbid 1200 "$refresh"
		if grep -aqE "RAGO-UPDATE : d.*rago-a\.efi en mode de secours" "$work/serial$n.txt"; then host_ok "$n" "mode de secours pendant l'essai de A : rago-update-trial-failed l'a noté"; else host_ko "$n" "pas de message de rago-update-trial-failed sur la console"; stop=1; fi
		if [ "$QRC" = 0 ] && ! done_ok "$n"; then host_ok "$n" "redémarrage immédiat (SuccessAction=reboot-force)"; else host_ko "$n" "pas de redémarrage après le mode de secours (qemu : code $QRC)"; stop=1; fi
		grep -q '^prompts=0 ' "$work/agent$n" 2>/dev/null || { host_ko "$n" "console : $(agent_said "$n")"; stop=1; }
		;;
	9)
		# Entrée unique = l'UKI A modifiée : le firmware (Secure Boot) doit la refuser.
		boot "$n" refuse 900 "$refresh"
		if grep -q '^refused ' "$work/agent$n" 2>/dev/null; then
			host_ok "$n" "Secure Boot refuse l'UKI modifiée : « $(grep -aoiE '(error loading|security violation|access denied).*' "$work/serial$n.txt" | head -1 | cut -c1-120) »"
		else
			host_ko "$n" "UKI modifiée pas refusée (console : $(agent_said "$n"))"; stop=1
		fi
		;;
	esac
	refresh=0
	[ "$stop" = 1 ] || snapshot "$n"
done

# --- bilan ---------------------------------------------------------------------------------
cat "$work"/serial[0-9]*.txt > "$work/all.log" 2>/dev/null || true
npass=$(grep -ac 'RAGO-M4 PASS' "$work/all.log" || true)
nfail=$(grep -ac 'RAGO-M4 FAIL' "$work/all.log" || true)
hpass=$(grep -c ': PASS' "$work/results" 2>/dev/null || true)
hko=$(grep -c ': FAIL' "$work/results" 2>/dev/null || true)
echo "Bilan VM M4 : invité $npass PASS / $nfail FAIL ; hôte $hpass PASS / $hko FAIL"
if [ "$nfail" -eq 0 ] && [ "$hko" -eq 0 ] && [ "$stop" = 0 ] && [ "$resume" = 1 ]; then
	echo "RÉUSSI"
	exit 0
fi
if [ "$nfail" -eq 0 ] && [ "$hko" -eq 0 ] && [ "$stop" = 0 ]; then
	echo "RÉUSSI depuis le démarrage $resume (reprise : refaire un passage complet pour valider)"
	exit 0
fi
echo "ÉCHEC (journaux : relancer avec --keep, ou voir $work si gardé)"
exit 1
