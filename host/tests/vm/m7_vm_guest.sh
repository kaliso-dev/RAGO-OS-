#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — partie « invité » du test VM du côté Linux du module M7.
#
# Tourne dans la VM (service rago-m7-test, sortie sur /dev/ttyS0), lancé par
# host/tests/vm/run_m7_vm_test.sh. Chaque résultat est une ligne
# « RAGO-M7 PASS|FAIL|INFO ... ». Disque /dev/vdb : GPT, partition 1
# « Microsoft basic data » FAT32 RAGO-COMM (faite par l'hôte), partition 2
# « Microsoft basic data » vide, formatée ici en NTFS (mkntfs de ntfs-3g,
# seulement pour CRÉER le volume ; Rago le monte avec ntfs3).
#
# Vérifié ici, avec le vrai noyau, le vrai pilote ntfs3 et le vrai systemd :
#   - tests de host/tests/test_library.py, cette fois avec NTFS + ntfs3 (dont
#     le bit « sale » et le journal « cache de Windows », recoupés avec ntfs3
#     et ntfscat) ;
#   - installation (M5 puis M7), rago-library check ;
#   - montage par étiquette (udev), PARTUUID réel noté pour Windows ;
#   - lecture seule sans état de Windows, écriture refusée ; « off » écrit sur
#     la partition sans Linux (mtools, comme Windows) → écriture permise, type
#     ntfs3 (pas fuseblk) ; « running » → lecture seule ;
#   - fichiers écrits par ntfs3 relus par ntfs-3g (ntfsls) : NTFS valide ;
#   - requête relue sur la FAT32 sans Linux (mtools, comme Windows) ;
#   - garde d'hibernation sous systemd : systemd-hibernate.service refusé
#     tant que RAGO-LIB est montée, sans toucher RAGO-COMM ;
#   - désinstallation.
set -u

O=/opt/rago
COMM=/dev/disk/by-label/RAGO-COMM
LIBDEV=/dev/vdb2
MNT=/run/rago/lib
OUT=/var/tmp/m7
mkdir -p "$OUT"

say() { echo "RAGO-M7 $*"; }
check() { # check <nom> <attendu> <obtenu>
	if [ "$2" = "$3" ]; then say "PASS $1 ($3)"; else say "FAIL $1 : attendu « $2 », obtenu « $3 »"; fi
}
check_true() {
	local n=$1
	shift
	if "$@"; then say "PASS $n"; else say "FAIL $n"; fi
}
show() { sed 's/^/RAGO-M7 LOG /'; }
finish() {
	say "DONE"
	sync
	systemctl poweroff --no-block
	exit 0
}
lib_fstype() { findmnt -n -o FSTYPE "$MNT" 2>/dev/null; }
lib_mode() { findmnt -n -o OPTIONS "$MNT" 2>/dev/null | tr ',' '\n' | grep -xE 'ro|rw' | head -1; }
# shellcheck disable=SC2329  # appelées par check_true
not_mounted() { ! findmnt -n "$MNT" > /dev/null 2>&1; }
# shellcheck disable=SC2329
comm_not_mounted() { ! findmnt -n /run/rago/comm > /dev/null 2>&1; }
# Écriture / lecture « comme Windows » : directement sur la FAT32, sans le pilote de Linux.
fat_put() { # fat_put <fichier local> <chemin dans RAGO-COMM>
	mmd -i "$(readlink -f "$COMM")" ::/library 2>/dev/null
	mcopy -o -i "$(readlink -f "$COMM")" "$1" "::$2"
}
fat_cat() { mtype -i "$(readlink -f "$COMM")" "::$1" 2>/dev/null; }
json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("/"): d=d[k]
print(d)' "$1" 2>/dev/null; }
windows_state() { # windows_state off|running : écrit comme l'agent Windows (RagoAgent.psm1)
	local offline=false
	[ "$1" = off ] && offline=true
	cat > "$OUT/ws.json" <<EOF
{"schema": 1, "kind": "rago-library-windows-state", "state": "$1", "updated_at": "2026-11-14T03:00:00Z",
 "boot_id": "2026-11-14T02:00:00Z", "writer": "test VM M7",
 "lib": {"found": true, "partuuid": "$PARTUUID", "letter": null, "online": false, "offline": $offline, "error": null}}
EOF
	fat_put "$OUT/ws.json" /library/windows-state.json
}

say "INFO noyau $(uname -r), systemd $(systemctl --version | head -1 | awk '{print $2}')"
udevadm settle
for _ in $(seq 50); do [ -e "$COMM" ] && [ -e "$LIBDEV" ] && break; sleep 0.2; done
check_true "udev : RAGO-COMM et vdb2 présents" test -e "$COMM" -a -e "$LIBDEV"

# --- pilote ntfs3 ----------------------------------------------------------------------------
modprobe ntfs3 2> "$OUT/modprobe.log"
check_true "pilote noyau ntfs3 chargé" grep -qw ntfs3 /proc/filesystems
show < "$OUT/modprobe.log"

# --- RAGO-LIB : NTFS créé par mkntfs (ntfs-3g sert seulement à le créer) --------------------
if mkntfs -Q -L RAGO-LIB "$LIBDEV" > "$OUT/mkntfs.log" 2>&1; then say "PASS mkntfs RAGO-LIB"; else say "FAIL mkntfs"; show < "$OUT/mkntfs.log"; fi
udevadm trigger --settle "$LIBDEV" 2>/dev/null || { udevadm trigger; udevadm settle; }
for _ in $(seq 50); do [ -e /dev/disk/by-label/RAGO-LIB ] && break; sleep 0.2; done
check "udev : /dev/disk/by-label/RAGO-LIB" "$LIBDEV" "$(readlink -f /dev/disk/by-label/RAGO-LIB)"
PARTUUID=$(blkid -p -o value -s PART_ENTRY_UUID "$LIBDEV")
check "blkid : type ntfs" "ntfs" "$(blkid -p -o value -s TYPE "$LIBDEV")"
say "INFO PARTUUID de RAGO-LIB : $PARTUUID"

# --- tests unitaires et de bout en bout, cette fois en NTFS + ntfs3 ---------------------------
if python3 -I "$O/host/tests/test_library.py" -v > "$OUT/unit.log" 2>&1; then
	say "PASS test_library.py ($(grep -E '^Ran [0-9]+ tests' "$OUT/unit.log" | tail -1), $(grep -E '^(OK|FAILED)' "$OUT/unit.log" | tail -1))"
else
	say "FAIL test_library.py"
	grep -E '^(FAIL|ERROR)|Error|assert' "$OUT/unit.log" | head -40 | show
fi
check "test_library.py : aucun test sauté (NTFS + ntfs3 + ntfscat)" "0" "$(grep -c 'skipped' "$OUT/unit.log" | tr -d ' ' | sed 's/^$/0/')"
grep -E 'test_ntfs_(dirty|windows_cache)' "$OUT/unit.log" | show

# --- installation ------------------------------------------------------------------------------
if "$O/host/setup_windows_security.sh" install > "$OUT/m5.log" 2>&1; then
	say "PASS M5 installé (RAGO-COMM)"
else
	say "FAIL installation M5"; show < "$OUT/m5.log"
fi
if "$O/host/setup_library.sh" install > "$OUT/install.log" 2>&1; then
	say "PASS M7 installé (setup_library.sh install)"
else
	say "FAIL installation M7"; show < "$OUT/install.log"
fi
check "rago-library dans le PATH" "/usr/lib/rago/rago-library.sh" "$(readlink -f "$(command -v rago-library)")"
check "réglages posés : ntfs3" "ntfs3" "$(sed -n 's/^RAGO_LIB_FSTYPE=//p' /etc/rago/rago-library.conf)"
systemd-analyze verify /usr/lib/systemd/system/rago-library-sleep-guard.service > "$OUT/verify.log" 2>&1
check "systemd-analyze verify garde d'hibernation" "0" "$?"
[ -s "$OUT/verify.log" ] && show < "$OUT/verify.log"
for u in systemd-hibernate.service systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service; do
	check_true "garde exigée par $u" sh -c "systemctl show -p Requires $u | grep -qw rago-library-sleep-guard.service"
done
check_true "garde avant sleep.target" sh -c 'systemctl show -p Before rago-library-sleep-guard.service | grep -qw sleep.target'
if rago-library check > "$OUT/check.log" 2>&1; then say "PASS rago-library check"; else say "FAIL rago-library check"; fi
show < "$OUT/check.log"
check_true "RAGO-LIB pas montée au départ" not_mounted

# --- sans état de Windows : lecture seule ------------------------------------------------------
rago-library mount > "$OUT/m1.log" 2>&1
check "mount sans état de Windows : code 3 (lecture seule)" "3" "$?"
check "type du montage : ntfs3 (pas fuseblk)" "ntfs3" "$(lib_fstype)"
check "monté en lecture seule" "ro" "$(lib_mode)"
fat_cat /library/partition.json > "$OUT/part.json"
check "partition.json : PARTUUID réel noté pour Windows (sur la FAT32, lu sans Linux)" "$PARTUUID" "$(json_get partuuid < "$OUT/part.json")"
check "partition.json : numéro de série NTFS" "$(blkid -p -o value -s UUID "$LIBDEV")" "$(json_get ntfs_serial < "$OUT/part.json")"
rago-library umount > "$OUT/u1.log" 2>&1
check "umount" "0" "$?"
rago-library mount --rw > "$OUT/m2.log" 2>&1
check "mount --rw sans état de Windows : refusé (3)" "3" "$?"
check_true "rien de monté après le refus" not_mounted

# --- « off » écrit comme Windows : écriture permise ---------------------------------------------
windows_state off
rago-library mount > "$OUT/m3.log" 2>&1
check "mount après « off » + hors ligne : code 0" "0" "$?"
show < "$OUT/m3.log"
check "type du montage : ntfs3" "ntfs3" "$(lib_fstype)"
check "monté en écriture" "rw" "$(lib_mode)"
check_true "arborescence .rago créée" test -f "$MNT/.rago/library.json" -a -d "$MNT/Games/Steam" -a -d "$MNT/Games/Riot"
cat > "$MNT/.rago/games/steam-730.json" <<'EOF'
{"schema": 1, "kind": "rago-library-game", "key": "steam-730", "launcher": "steam", "launcher_id": "730",
 "name": "Counter-Strike 2", "installed": true, "install_dir": "games/steam/steamapps/common/CS2"}
EOF
mkdir -p "$MNT/Games/Steam/steamapps/common/cs2"
rago-library list > "$OUT/list.log" 2>&1
check "list (montée) : code 0" "0" "$?"
check_true "list : jeu lu, dossier trouvé malgré la casse" grep -q "steam-730.*Counter-Strike 2.*installé  " "$OUT/list.log"
show < "$OUT/list.log"
# Garde d'hibernation : RAGO-LIB montée → hibernation refusée, RAGO-COMM pas touchée.
systemctl reset-failed rago-library-sleep-guard.service 2>/dev/null
systemctl start systemd-hibernate.service > "$OUT/hib.log" 2>&1
check_true "hibernation refusée pendant que RAGO-LIB est montée" test "$?" -ne 0
check "garde en échec" "failed" "$(systemctl is-active rago-library-sleep-guard.service)"
check_true "journal : hibernation REFUSÉE" sh -c 'journalctl -u rago-library-sleep-guard.service -b --no-pager | grep -q "hibernation REFUSÉE"'
check_true "garde : RAGO-COMM jamais montée" comm_not_mounted
check "RAGO-LIB toujours montée en écriture" "rw" "$(lib_mode)"
# Démontage refusé tant qu'un programme s'en sert.
(cd "$MNT/Games" && sleep 30) &
busy=$!
sleep 1
rago-library umount > "$OUT/u2.log" 2>&1
check "umount refusé, RAGO-LIB occupée : code 1" "1" "$?"
check_true "umount : programme nommé" grep -q "sleep" "$OUT/u2.log"
kill "$busy" 2>/dev/null
wait "$busy" 2>/dev/null
rago-library umount > "$OUT/u3.log" 2>&1
check "umount" "0" "$?"
systemctl reset-failed rago-library-sleep-guard.service 2>/dev/null
systemctl start rago-library-sleep-guard.service > "$OUT/guard.log" 2>&1
check "garde : RAGO-LIB démontée, hibernation permise" "0" "$?"
# Ce que ntfs3 a écrit, relu par un autre lecteur NTFS (ntfs-3g, sans monter).
ntfsls -p /.rago/games "$LIBDEV" > "$OUT/ntfsls.log" 2>&1
check_true "ntfsls (ntfs-3g) relit le fichier écrit par ntfs3" grep -qx "steam-730.json" "$OUT/ntfsls.log"
check "volume propre après démontage (rago_library ntfs-check)" "0" "$(python3 -I /usr/lib/rago/rago_library.py ntfs-check "$LIBDEV" > /dev/null 2>&1; echo $?)"

# --- liste avec RAGO-LIB démontée : montage lecture seule le temps de lire ------------------------
rago-library list > "$OUT/list2.log" 2>&1
check "list (démontée) : code 0" "0" "$?"
check_true "list (démontée) : jeu lu" grep -q "steam-730" "$OUT/list2.log"
check_true "list : RAGO-LIB redémontée après lecture" not_mounted

# --- requêtes : relues sur la FAT32 sans Linux, comme Windows -------------------------------------
rago-library install steam 730 --name "Counter-Strike 2" > "$OUT/req.log" 2>&1
check "install steam 730 : code 0" "0" "$?"
fat_cat /library/requests/install-steam-730.json > "$OUT/req.json"
check "requête lue sur la FAT32 : id" "install-steam-730" "$(json_get id < "$OUT/req.json")"
check "requête : clé de jeu" "steam-730" "$(json_get game_key < "$OUT/req.json")"
rago-library install gamepass 9NBLGGH4R315 > "$OUT/req2.log" 2>&1
check "Game Pass / Store refusé : code 2" "2" "$?"
check_true "RAGO-COMM démontée après les requêtes" comm_not_mounted

# --- « running » : lecture seule -----------------------------------------------------------------
windows_state running
rago-library mount --rw > "$OUT/m4.log" 2>&1
check "mount --rw pendant « running » : refusé (3)" "3" "$?"
check_true "rien de monté" not_mounted
rago-library status > "$OUT/status.log" 2>&1
check_true "status : Windows « running » affiché" grep -q "Windows : running" "$OUT/status.log"
show < "$OUT/status.log"

# --- désinstallation ----------------------------------------------------------------------------
if "$O/host/setup_library.sh" uninstall > "$OUT/uninstall.log" 2>&1; then say "PASS désinstallation"; else say "FAIL désinstallation"; show < "$OUT/uninstall.log"; fi
check_true "rago-library retiré" test ! -e /usr/bin/rago-library -a ! -e /usr/lib/rago/rago_library.py
check_true "garde retirée de systemd-hibernate" sh -c '! systemctl show -p Requires systemd-hibernate.service | grep -qw rago-library-sleep-guard'
check_true "RAGO-LIB gardée intacte" sh -c "ntfsls -p /.rago/games '$LIBDEV' | grep -qx steam-730.json"
finish
