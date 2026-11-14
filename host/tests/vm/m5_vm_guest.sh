#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — partie « invité » du test VM du côté Linux du module M5.
#
# Tourne dans la VM (service rago-m5-test, sortie sur /dev/ttyS0), lancé par
# host/tests/vm/run_m5_vm_test.sh. Chaque résultat est une ligne
# « RAGO-M5 PASS|FAIL|INFO ... ». Disque /dev/vdb : GPT, partition 1 « Microsoft
# basic data » en FAT32 nommée RAGO-COMM.
set -u

O=/opt/rago
DEV=/dev/disk/by-label/RAGO-COMM
MNT=/run/rago/comm
OUT=/var/tmp/m5
mkdir -p "$OUT"

say() { echo "RAGO-M5 $*"; }
check() { # check <nom> <attendu> <obtenu>
	if [ "$2" = "$3" ]; then say "PASS $1 ($3)"; else say "FAIL $1 : attendu « $2 », obtenu « $3 »"; fi
}
check_true() {
	local n=$1
	shift
	if "$@"; then say "PASS $n"; else say "FAIL $n"; fi
}
show() { sed 's/^/RAGO-M5 LOG /'; }
finish() {
	say "DONE"
	sync
	systemctl poweroff --no-block
	exit 0
}
mounted() { findmnt -n "$MNT" > /dev/null 2>&1; }
not_mounted() { ! mounted; }
# Lecture « comme Windows » : directement sur la partition, sans le pilote vfat de Linux.
fat_cat() { mtype -i "$(readlink -f "$DEV")" "::$1" 2>/dev/null; }
json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("/"): d=d[k]
print(d)' "$1" 2>/dev/null; }
switch() { # switch <jeu> : prepare-switch, sortie dans $OUT/<jeu>.log, code renvoyé
	rago-profiled prepare-switch --id "$1" > "$OUT/$1.log" 2>&1
}

say "INFO noyau $(uname -r), systemd $(systemctl --version | head -1 | awk '{print $2}')"
udevadm settle
for _ in $(seq 50); do [ -e "$DEV" ] && break; sleep 0.2; done
check_true "udev : $DEV présent" test -e "$DEV"
check "partition = vdb1" "/dev/vdb1" "$(readlink -f "$DEV")"

# --- installation M14 puis M5 -------------------------------------------------------------
if "$O/daemons/rago-profiled/install.sh" install --bin "$O/bin/rago-profiled" > "$OUT/m14.log" 2>&1; then
	say "PASS M14 installé (rago-profiled)"
else
	say "FAIL installation M14"; show < "$OUT/m14.log"
fi
if "$O/host/setup_windows_security.sh" install > "$OUT/m5.log" 2>&1; then
	say "PASS M5 installé (setup_windows_security.sh install)"
else
	say "FAIL installation M5"; show < "$OUT/m5.log"
fi
check "hook : propriétaire et mode" "0 755" "$(stat -c '%u %a' /usr/lib/rago/hooks/windows-security)"
check "réglages posés" "/run/rago/comm" "$(sed -n 's/^RAGO_COMM_DIR=//p' /etc/rago/rago-comm.conf)"
systemd-analyze verify /usr/lib/systemd/system/run-rago-comm.mount > "$OUT/verify.log" 2>&1
check "systemd-analyze verify run-rago-comm.mount" "0" "$?"
[ -s "$OUT/verify.log" ] && show < "$OUT/verify.log"
check "unité jamais activée au démarrage" "static" "$(systemctl is-enabled run-rago-comm.mount 2>&1)"
check "unité inactive après installation" "inactive" "$(systemctl is-active run-rago-comm.mount 2>&1)"
check_true "Conflicts=sleep.target dans l'unité" sh -c 'systemctl show -p Conflicts run-rago-comm.mount | grep -qw sleep.target'
check_true "Before=sleep.target dans l'unité" sh -c 'systemctl show -p Before run-rago-comm.mount | grep -qw sleep.target'
if "$O/host/setup_windows_security.sh" check > "$OUT/check.log" 2>&1; then
	say "PASS check : tout prêt"
else
	say "FAIL check"
fi
show < "$OUT/check.log"
check_true "check : type GPT basic data reconnu" grep -q "Microsoft basic data (Windows la voit)" "$OUT/check.log"
check_true "check : FAT32 reconnue" grep -q "FAT32 (vfat)" "$OUT/check.log"
check_true "check : rago-profiled voit le hook" grep -q "rago-profiled voit le hook" "$OUT/check.log"
check_true "RAGO-COMM pas montée au départ" not_mounted

# --- prepare-switch → hook (dans le bac à sable du service) → RAGO-COMM ---------------
for game in fortnite:perf:fortnite valorant:compat_max:valorant jeu-inconnu:compat_max:_fallback; do
	g=${game%%:*}; rest=${game#*:}; want=${rest%%:*}; pid=${rest#*:}
	switch "$g"; rc=$?
	check "prepare-switch $g : code" "0" "$rc"
	check_true "prepare-switch $g : « $want transmis au micro-Windows »" grep -q "$want transmis au micro-Windows" "$OUT/$g.log"
	[ "$rc" = 0 ] || show < "$OUT/$g.log"
	check_true "$g : RAGO-COMM démontée après l'écriture" not_mounted
	fat_cat /security/profile.json > "$OUT/$g.json"
	check "$g : security (lu sur la FAT sans Linux)" "$want" "$(json_get security < "$OUT/$g.json")"
	check "$g : profile_id" "$pid" "$(json_get profile_id < "$OUT/$g.json")"
	check "$g : profil joint (windows_security)" "$want" "$(json_get profile/windows_security < "$OUT/$g.json")"
done
check_true "fichier en ASCII pur" sh -c "LC_ALL=C grep -qP '[^\\x00-\\x7F]' $OUT/fortnite.json && exit 1 || exit 0"
check "rago-comm.json (repère de la partition)" "1" "$(fat_cat /rago-comm.json | json_get layout)"
check_true "pas de fichier temporaire oublié" sh -c "! mdir -b -i $(readlink -f "$DEV") ::/security | grep -q tmp"
check_true "journal du démon : switch tracé" sh -c 'journalctl -u rago-profiled -b --no-pager | grep -q "windows_security"'

# --- déjà montée AVANT le démarrage du service (bac à sable déjà en place) ---------------
systemctl start run-rago-comm.mount
systemctl restart rago-profiled.service
sleep 1
switch valorant; rc=$?
check "déjà montée avant le service : prepare-switch code" "0" "$rc"
[ "$rc" = 0 ] || show < "$OUT/valorant.log"
check_true "déjà montée : laissée montée (pas à nous de la démonter)" mounted
check "déjà montée : écrit" "valorant" "$(json_get profile_id < $MNT/security/profile.json)"
systemctl stop run-rago-comm.mount
check_true "arrêt de l'unité : démontée" not_mounted

# --- montée PENDANT que le service tourne (propagation dans son espace de montage) ------
systemctl restart rago-profiled.service
sleep 1
systemctl start run-rago-comm.mount
switch fortnite; rc=$?
check "montée après le démarrage du service : prepare-switch code" "0" "$rc"
[ "$rc" = 0 ] || show < "$OUT/fortnite.log"
check "montée après le démarrage du service : écrit" "fortnite" "$(json_get profile_id < $MNT/security/profile.json)"
systemctl stop run-rago-comm.mount

# --- retour « de Windows » : status.json et rapport écrits sur la FAT (mtools) -----------
cat > "$OUT/status.json" <<'EOF'
{"schema":1,"kind":"rago-windows-security-status","requested":"perf","applied":"perf","effective":"perf","reboot":"none"}
EOF
printf '\xef\xbb\xbf{"schema":1,"kind":"rago-m5-engine-report","explorer_running":false}\n' > "$OUT/m5-engine.json"
p=$(readlink -f "$DEV")
mcopy -o -i "$p" "$OUT/status.json" ::/security/status.json
mmd -i "$p" ::/reports 2>/dev/null || true
mcopy -o -i "$p" "$OUT/m5-engine.json" ::/reports/m5-engine.json
"$O/host/setup_windows_security.sh" status > "$OUT/status.out" 2> "$OUT/status.err"
check "status : code" "0" "$?"
check "status : état écrit par Windows relu" "perf" "$(json_get windows_status/effective < "$OUT/status.out")"
check "status : rapport M5 relu (BOM UTF-8 accepté)" "False" "$(json_get reports/m5-engine.json/explorer_running < "$OUT/status.out")"
check_true "status : RAGO-COMM démontée après lecture" not_mounted

# --- erreurs ------------------------------------------------------------------------------
cp /etc/rago/rago-comm.conf "$OUT/conf.bak"
sed -i 's|^RAGO_COMM_DEVICE=.*|RAGO_COMM_DEVICE=/dev/disk/by-label/ABSENTE|' /etc/rago/rago-comm.conf
switch valorant; rc=$?
check "partition absente : prepare-switch en erreur (code 1)" "1" "$rc"
check_true "partition absente : message clair" grep -q "partition RAGO-COMM introuvable" "$OUT/valorant.log"
cp "$OUT/conf.bak" /etc/rago/rago-comm.conf
chmod 0666 /etc/rago/rago-comm.conf
switch valorant; rc=$?
check "réglages modifiables par tous : refusés (code 1)" "1" "$rc"
chmod 0644 /etc/rago/rago-comm.conf
check_true "toujours démontée après les erreurs" not_mounted

# --- désinstallation ----------------------------------------------------------------------
"$O/host/setup_windows_security.sh" uninstall > "$OUT/un.log" 2>&1
check "désinstallation : code" "0" "$?"
check_true "hook retiré" test ! -e /usr/lib/rago/hooks/windows-security
check_true "réglages gardés" test -f /etc/rago/rago-comm.conf
switch valorant; rc=$?
check "sans hook : prepare-switch code 4 (en attente)" "4" "$rc"
# Dernier profil bien écrit : fortnite (les essais en erreur et la désinstallation n'écrivent rien).
check "la partition n'a pas été touchée (dernier profil écrit encore là)" "fortnite" "$(fat_cat /security/profile.json | json_get profile_id)"
finish
