#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — partie « invité » du test VM du module M14.
#
# Tourne dans la VM (service rago-m14-test, sortie sur /dev/ttyS0), lancé par
# daemons/rago-profiled/tests/vm/run_m14_vm_test.sh. Chaque résultat est une
# ligne « RAGO-M14 PASS|FAIL|INFO ... ».
set -u

O=/opt/rago
THP=/sys/kernel/mm/transparent_hugepage/enabled
QOS=/dev/cpu_dma_latency
OUT=/var/tmp/m14
mkdir -p "$OUT"
chmod 0777 "$OUT"

say() { echo "RAGO-M14 $*"; }
check() { # check <nom> <attendu> <obtenu>
	if [ "$2" = "$3" ]; then say "PASS $1 ($3)"; else say "FAIL $1 : attendu « $2 », obtenu « $3 »"; fi
}
check_true() {
	local n=$1
	shift
	if "$@"; then say "PASS $n"; else say "FAIL $n"; fi
}
show() { sed 's/^/RAGO-M14 LOG /'; }
thp() { sed -n 's/.*\[\(.*\)\].*/\1/p' "$THP"; }
qos() { od -An -t d4 -N4 "$QOS" | tr -d ' '; }
finish() {
	say "DONE"
	sync
	systemctl poweroff --no-block
	exit 0
}
# Jeu factice : relève THP et la latence PM QoS effective pendant qu'il tourne.
GAME="sed -n 's/.*\[\(.*\)\].*/\1/p' $THP > $OUT/thp; od -An -t d4 -N4 $QOS | tr -d ' ' > $OUT/qos"
as() { # as <utilisateur> <commande…>
	local u=$1
	shift
	runuser -u "$u" -- "$@"
}

for _ in $(seq 1 180); do
	tuned-adm active >/dev/null 2>&1 && break
	sleep 1
done
say "INFO noyau $(uname -r), THP $(thp), PM QoS $(qos) µs"

# --- 1. M1 : la base (C-states shallow tenus par tuned) ----------------------------------
if "$O/host/setup_host_tuning.sh" install --cstates shallow > "$OUT/m1.log" 2>&1; then
	say "PASS M1 installé (--cstates shallow)"
else
	say "FAIL M1 install"
	show < "$OUT/m1.log"
	finish
fi
sleep 2
base_thp=$(thp)
base_qos=$(qos)
check "base M1 : profil tuned" rago-gaming "$(tuned-adm active | sed -n 's/^Current active profile: //p')"
check "base M1 : THP" madvise "$base_thp"
check_true "base M1 : C-states limités par tuned ($base_qos µs)" test "$base_qos" -gt 0 -a "$base_qos" -lt 2000000000

# --- 2. M14 : installation, service durci, socket du groupe rago ------------------------
useradd -m joueur
useradd -m autre
if "$O/daemons/rago-profiled/install.sh" install --user joueur --bin "$O/bin/rago-profiled" > "$OUT/m14.log" 2>&1; then
	say "PASS install.sh install --user joueur"
else
	say "FAIL install.sh install"
	show < "$OUT/m14.log"
	finish
fi
for _ in $(seq 50); do [ -S /run/rago-profiled/profiled.sock ] && break; sleep 0.2; done
check "service actif" active "$(systemctl is-active rago-profiled)"
check "socket root:rago 0660" "660 root rago" "$(stat -c '%a %U %G' /run/rago-profiled/profiled.sock)"
check_true "joueur dans le groupe rago" sh -c 'id -nG joueur | grep -qw rago'
check "base communautaire installée" 5 "$(find /usr/share/rago/profiles -maxdepth 1 -type f | wc -l)"
cat > /etc/rago/profiles/vm-test.toml <<'EOF'
schema = 1
id = "vm-test"
name = "Test VM"
couche = "proton"
cpu_governor = "performance"
thp = "always"
cstates = "poll"
gpu_clocks = { mode = "max" }
mitigations = "off"
[match]
steam_appid = [999999]
EOF
check_true "profil local validé" rago-profiled validate /etc/rago/profiles
check_true "list : base communautaire + profil local" sh -c 'rago-profiled list 2>/dev/null | grep -q "^vm-test" && rago-profiled list 2>/dev/null | grep -q "^valorant"'

# --- 3. un jeu (joueur non root) : surcharge pendant, base exacte après ------------------
rm -f "$OUT/thp" "$OUT/qos"
as joueur env SteamAppId=999999 rago-profiled launch -- sh -c "$GAME" > "$OUT/launch.log" 2>&1
rc=$?
check "jeu lancé par le joueur" 0 "$rc"
check "pendant le jeu : THP" always "$(cat "$OUT/thp")"
check "pendant le jeu : C-states poll (0 µs)" 0 "$(cat "$OUT/qos")"
check "après le jeu : THP de M1" "$base_thp" "$(thp)"
check "après le jeu : C-states de M1 (tuned)" "$base_qos" "$(qos)"
check_true "après le jeu : tuned-adm verify" tuned-adm verify
check_true "rapport : horloges GPU en attente de M9" grep -q "M9" "$OUT/launch.log"
check_true "rapport : mitigations signalées, pas changées" grep -q "RAGO_MITIGATIONS=off" "$OUT/launch.log"
check_true "rapport : rago-sched-hint (M0) absent signalé" grep -q "rago-sched-hint" "$OUT/launch.log"
show < "$OUT/launch.log"

# --- 4. jeu sans profil : rien ne bouge ----------------------------------------------------
as joueur rago-profiled launch --id inconnu -- sh -c "$GAME" > "$OUT/launch2.log" 2>&1
check "repli : THP inchangé" "$base_thp" "$(cat "$OUT/thp")"
check "repli : C-states inchangés" "$base_qos" "$(cat "$OUT/qos")"
check_true "repli : signalé" grep -q "profil sûr par défaut" "$OUT/launch2.log"

# --- 5. hors du groupe rago : refusé, le jeu se lance quand même sans surcharge -----------
as autre rago-profiled launch --id vm-test -- sh -c "$GAME" > "$OUT/launch3.log" 2>&1
check "hors groupe : jeu lancé quand même" 0 "$?"
check "hors groupe : aucune surcharge" "$base_thp" "$(cat "$OUT/thp")"
check_true "hors groupe : socket refusé" grep -q "injoignable" "$OUT/launch3.log"

# --- 6. service tué en plein jeu : systemd le relance, la base revient -------------------
as joueur rago-profiled launch --id vm-test -- sleep 60 > "$OUT/launch4.log" 2>&1 &
lp=$!
for _ in $(seq 100); do [ "$(thp)" = always ] && break; sleep 0.1; done
check "jeu en cours : profil appliqué" always "$(thp)"
systemctl kill -s KILL rago-profiled
for _ in $(seq 100); do
	[ "$(systemctl is-active rago-profiled)" = active ] && [ "$(thp)" = "$base_thp" ] && break
	sleep 0.2
done
check "relancé par systemd" active "$(systemctl is-active rago-profiled)"
check "reprise : THP de M1" "$base_thp" "$(thp)"
check "reprise : C-states de M1" "$base_qos" "$(qos)"
check_true "reprise journalisée" sh -c 'journalctl -u rago-profiled --no-pager | grep -q reprise'
pkill -f "sleep 60"
wait "$lp" 2>/dev/null

# --- 7. arrêt du service en plein jeu ------------------------------------------------------
as joueur rago-profiled launch --id vm-test -- sleep 60 > "$OUT/launch5.log" 2>&1 &
lp=$!
for _ in $(seq 100); do [ "$(thp)" = always ] && break; sleep 0.1; done
systemctl stop rago-profiled
check "stop : THP de M1" "$base_thp" "$(thp)"
check "stop : C-states de M1" "$base_qos" "$(qos)"
pkill -f "sleep 60"
wait "$lp" 2>/dev/null
systemctl start rago-profiled
for _ in $(seq 50); do [ -S /run/rago-profiled/profiled.sock ] && break; sleep 0.2; done

# --- 8. couche switch : hook de M5/M6 -------------------------------------------------------
as joueur rago-profiled prepare-switch --id valorant > "$OUT/sw.log" 2>&1
check "prepare-switch sans M5/M6 : en attente (code 4)" 4 "$?"
cat > /usr/lib/rago/hooks/windows-security <<'EOF'
#!/bin/sh
echo "$RAGO_PROFILE_ID $RAGO_WINDOWS_SECURITY" > /run/rago-profiled/comm-test
EOF
chmod 0755 /usr/lib/rago/hooks/windows-security
as joueur rago-profiled prepare-switch --id fortnite > "$OUT/sw2.log" 2>&1
check "prepare-switch avec hook (code 0)" 0 "$?"
check "hook : profil transmis" "fortnite perf" "$(cat /run/rago-profiled/comm-test 2>/dev/null)"
show < "$OUT/sw2.log"

# --- 9. durcissement systemd ---------------------------------------------------------------
systemd-analyze security rago-profiled --no-pager 2>/dev/null | tail -1 | show
check_true "statut : réglages lisibles" sh -c 'rago-profiled status | grep -q cstates'

# --- 10. désinstallation -------------------------------------------------------------------
"$O/daemons/rago-profiled/install.sh" uninstall > "$OUT/un.log" 2>&1
check "désinstallé : service" inactive "$(systemctl is-active rago-profiled 2>/dev/null || true)"
check_true "désinstallé : binaire retiré" test ! -e /usr/bin/rago-profiled
check_true "désinstallé : profils locaux gardés" test -f /etc/rago/profiles/vm-test.toml
check "désinstallé : base M1 intacte" "$base_thp/$base_qos" "$(thp)/$(qos)"
finish
