#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — partie « invité » du test chroot du module M2.
#
# Tourne dans le chroot Ubuntu 25.10 préparé par
# host/tests/chroot/run_m2_chroot_test.sh (root, sans systemd, /sys en lecture
# seule). Chaque résultat est une ligne « RAGO-M2 PASS|FAIL|INFO ... ».
set -u

REPO=/opt/rago
SETUP=$REPO/host/setup_proton_layer.sh
T=/opt/rago-test
U=joueur
UH=/home/$U
UXDG=/run/user/1000
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
mkdir -p "$T"

say() { echo "RAGO-M2 $*"; }
check() { # check <nom> <attendu> <obtenu>
	if [ "$2" = "$3" ]; then say "PASS $1 ($3)"; else say "FAIL $1 : attendu « $2 », obtenu « $3 »"; fi
}
check_true() { # check_true <nom> <commande...>
	local n=$1
	shift
	if "$@"; then say "PASS $n"; else say "FAIL $n"; fi
}
show() { sed 's/^/RAGO-M2 LOG /'; }
has_line() { grep -qF -- "$1" "$2"; }
# Commande en joueur, environnement propre de session (PATH sans /usr/games :
# rago-session doit le retrouver seul).
as_user() {
	runuser -u "$U" -- env -i HOME="$UH" USER="$U" LOGNAME="$U" LANG=C.UTF-8 TERM=dumb \
		PATH=/usr/local/bin:/usr/bin:/bin XDG_RUNTIME_DIR="$UXDG" "$@"
}
sha() { if [ -e "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else echo absent; fi; }

say "INFO $(. /etc/os-release && echo "$PRETTY_NAME"), noyau $(uname -r)"

# --- 0. paquets de base et joueur --------------------------------------------------------
apt-get update -q > /tmp/apt-update.log 2>&1 || { show < /tmp/apt-update.log; say "FAIL apt-get update"; }
id "$U" >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash "$U"
mkdir -p "$UXDG" && chown "$U:$U" "$UXDG" && chmod 700 "$UXDG"

# --- 1. deps (vrai apt) --------------------------------------------------------------------
out=$("$SETUP" deps 2>&1); rc=$?
check "deps sans --enable-32bit : refus clair" 1 "$rc"
check_true "deps sans --enable-32bit : message i386" grep -q "i386" <<< "$out"
# La licence de Steam est acceptée pour le TEST seulement (le joueur la lit lui-même).
printf 'steam-installer steam/question select I AGREE\nsteam-installer steam/license note\n' | debconf-set-selections
t0=$(date +%s)
"$SETUP" deps --enable-32bit > /tmp/deps.log 2>&1; rc=$?
check "deps --enable-32bit : code" 0 "$rc"
[ "$rc" = 0 ] || tail -30 /tmp/deps.log | show
say "INFO deps : $(($(date +%s) - t0)) s, $(grep -c '^Setting up\|^Paramétrage' /tmp/deps.log) paquets configurés"
check "i386 activé" i386 "$(dpkg --print-foreign-architectures | grep -x i386)"
# Debian / Ubuntu : steam, gamescope et gamemoderun sont dans /usr/games.
for b in /usr/games/steam /usr/games/gamemoderun /usr/bin/gamemoded /usr/bin/mangohud \
	/usr/games/gamescope /usr/bin/pkexec /usr/bin/pkaction /usr/sbin/setcap /usr/bin/python3; do
	check_true "paquet installé : $b" test -x "$b"
done
mangoapp=0
if command -v mangoapp >/dev/null || [ -x /usr/games/mangoapp ]; then mangoapp=1; fi
say "INFO mangoapp (HUD de la session) : $([ "$mangoapp" = 1 ] && echo présent || echo "absent du paquet mangohud de cette distribution")"
for p in gamescope gamemode mangohud steam-installer polkitd; do
	say "INFO version $p : $(dpkg-query -W -f '${Version}' "$p" 2>/dev/null)"
done
# Outils du TEST seulement : Vulkan logiciel (lavapipe), vulkaninfo, dbus.
apt-get install -y -q mesa-vulkan-drivers vulkan-tools dbus-daemon dbus-bin > /tmp/apt-test.log 2>&1 ||
	{ tail -20 /tmp/apt-test.log | show; say "FAIL outils de test (lavapipe, vulkan-tools)"; }
getent group gamemode >/dev/null || groupadd -r gamemode
usermod -aG gamemode "$U"

# --- 2. install + verify -------------------------------------------------------------------
before_gm=$(sha /etc/gamemode.ini)
before_mh=$(sha /etc/MangoHud.conf)
before_cap=$(getcap /usr/games/gamescope 2>/dev/null)
"$SETUP" install > /tmp/install.log 2>&1; rc=$?
check "install : code" 0 "$rc"
[ "$rc" = 0 ] || tail -30 /tmp/install.log | show
for f in /usr/bin/rago-launch /usr/bin/rago-shader-cache /usr/bin/rago-steam-config /usr/bin/rago-session \
	/usr/lib/rago/rago_proton_lib.sh /usr/share/wayland-sessions/rago.desktop /etc/gamemode.ini \
	/etc/polkit-1/rules.d/40-rago-gamemode.rules /etc/MangoHud.conf /usr/lib/systemd/user/rago-shader-prewarm.service \
	/etc/rago/proton-layer.conf; do
	check_true "posé : $f" test -s "$f"
done
check_true "gamescope : cap_sys_nice (pour --rt)" grep -q cap_sys_nice <<< "$(getcap /usr/games/gamescope)"
"$SETUP" verify > /tmp/verify.log 2>&1; rc=$?
check "verify : code" 0 "$rc"
grep -E '^\s+\[' /tmp/verify.log | show
check "verify : aucun échec" 0 "$(grep -c '\[ ÉCHEC \]' /tmp/verify.log)"
check "verify : 3 points en attente de matériel" 3 "$(grep -c '\[ MATÉRIEL \]' /tmp/verify.log)"
check_true "verify : Steam trouvé dans /usr/games" grep -q 'Steam installé (/usr/games/steam)' /tmp/verify.log
check_true "verify : Proton-GE signalé non épinglé" grep -q 'Proton-GE pas encore épinglé' /tmp/verify.log
installed=$(for f in /usr/bin/rago-launch /usr/bin/rago-session /etc/gamemode.ini /etc/MangoHud.conf \
	/etc/polkit-1/rules.d/40-rago-gamemode.rules /etc/rago/proton-layer.conf; do sha "$f" | cut -c1-8; done | tr '\n' ' ')

# --- 3. chaque option gamescope existe -----------------------------------------------------
/usr/games/gamescope --help > /tmp/gs-help.txt 2>&1 || true
say "INFO $(/usr/games/gamescope --version 2>&1 | head -1)"
# shellcheck source=../../lib/rago_proton_lib.sh
. /usr/lib/rago/rago_proton_lib.sh
mapfile -t gsargs < <(RAGO_SESSION_WIDTH=2560 RAGO_SESSION_HEIGHT=1440 RAGO_SESSION_REFRESH=165 \
	RAGO_SESSION_HDR_ITM=1 RAGO_SESSION_OUTPUT=DP-1 RAGO_SESSION_VK_DEVICE=1002:744c \
	RAGO_SESSION_BACKEND=drm RAGO_SESSION_NESTED=1 rago_pl_gamescope_args)
n=0
for a in "${gsargs[@]}"; do
	[ "$a" = -- ] && break
	case "$a" in -*) ;; *) continue ;; esac
	n=$((n + 1))
	check_true "gamescope connaît $a" grep -qE -- "(^|[[:space:],])$a([[:space:],=]|$)" /tmp/gs-help.txt
done
say "INFO $n options gamescope vérifiées"

# --- 4. vraie session gamescope (headless, lavapipe) avec un Steam factice ---------------------
cat > "$T/fake-steam" <<'EOF'
#!/bin/bash
# Steam factice : note ce que la session lui donne, puis lance un jeu par rago-launch.
env | sort > /tmp/m2-steam.env
rago-launch /opt/rago-test/fake-game > /tmp/m2-session-game.out 2>&1
echo "rc=$?" >> /tmp/m2-session-game.out
exit 0
EOF
cat > "$T/fake-game" <<'EOF'
#!/bin/bash
# Jeu factice : note son environnement et l'état de gamemode, sort en code 7.
env | sort > "${GAME_OUT:-/tmp/m2-game}.env"
# État de gamemode pour CE processus (le jeu), demandé par un sous-shell sans
# LD_PRELOAD (sinon « gamemoded -s » s'inscrit lui-même).
command -v gamemoded >/dev/null && (unset LD_PRELOAD; exec gamemoded -s"$$") > "${GAME_OUT:-/tmp/m2-game}.gm" 2>&1
exit 7
EOF
chmod 755 "$T/fake-steam" "$T/fake-game"
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
VK_ICD_FILENAMES=$VK_ICD_FILENAMES vulkaninfo --summary 2>/dev/null | grep -m1 -E 'deviceName' | sed 's/^ */INFO Vulkan : /;s/^/RAGO-M2 /'
as_user env VK_ICD_FILENAMES="$VK_ICD_FILENAMES" RAGO_SESSION_BACKEND=headless RAGO_SESSION_WIDTH=1280 \
	RAGO_SESSION_HEIGHT=720 RAGO_SESSION_REFRESH=60 RAGO_SESSION_STEAM_CMD="$T/fake-steam" \
	timeout 90 rago-session > /tmp/session.log 2>&1; rc=$?
gsline=$(grep -m1 '^rago-session : gamescope ' /tmp/session.log)
for a in -e "--xwayland-count 2" "-W 1280" "-H 720" "-r 60" --adaptive-sync --hdr-enabled --immediate-flips --rt "--backend headless"; do
	check_true "session : commande gamescope avec $a" grep -qE -- "(^| )$a( |$)" <<< "$gsline"
done
check_true "session : Steam lancé dans gamescope (après --)" grep -qF -- "-- $T/fake-steam" <<< "$gsline"
check "session : gamescope a cap_sys_nice en joueur (--rt possible)" 0 "$(grep -c 'No CAP_SYS_NICE' /tmp/session.log)"
if [ "$mangoapp" = 0 ]; then
	check_true "session sans mangoapp : signalé" grep -q 'mangoapp absent' /tmp/session.log
	check "session sans mangoapp : pas de --mangoapp" 0 "$(grep -c -- '--mangoapp' <<< "$gsline")"
fi
# Environnement que Steam recevrait (réglages lus depuis /etc/rago/proton-layer.conf installé).
as_user rago-session --print > /tmp/session-print.txt 2>&1
for e in RAGO_SESSION=1 STEAM_GAMESCOPE_VRR_SUPPORTED=1 STEAM_GAMESCOPE_HDR_SUPPORTED=1 \
	STEAM_GAMESCOPE_TEARING_SUPPORTED=1 STEAM_MULTIPLE_XWAYLANDS=1 XDG_CURRENT_DESKTOP=gamescope; do
	check_true "session --print : $e" grep -qx "env:$e" /tmp/session-print.txt
done
check_true "session --print : Steam en Big Picture" grep -qx 'argv:-gamepadui' /tmp/session-print.txt
check_true "session --print : gamescope retrouvé dans /usr/games" grep -qx 'argv:/usr/games/gamescope' /tmp/session-print.txt
if grep -q 'VK_EXT_physical_device_drm' /tmp/session.log; then
	# gamescope 3.16 exige VK_EXT_physical_device_drm, même en headless : seul un vrai GPU l'a.
	say "INFO EN ATTENTE DE MATÉRIEL : gamescope exige un GPU Vulkan avec VK_EXT_physical_device_drm (le Vulkan logiciel lavapipe ne l'a pas) : la session ne peut pas démarrer ici (code $rc)"
elif [ -s /tmp/m2-steam.env ]; then
	check "session : gamescope a démarré puis rendu la main" 0 "$rc"
	say "PASS session : gamescope a lancé Steam (factice)"
	check_true "session : Steam a un DISPLAY (Xwayland de gamescope)" grep -qE '^DISPLAY=:[0-9]' /tmp/m2-steam.env
	check_true "session : GAMESCOPE_WAYLAND_DISPLAY" grep -q '^GAMESCOPE_WAYLAND_DISPLAY=' /tmp/m2-steam.env
	for e in RAGO_SESSION=1 STEAM_GAMESCOPE_VRR_SUPPORTED=1 STEAM_GAMESCOPE_HDR_SUPPORTED=1 \
		STEAM_GAMESCOPE_TEARING_SUPPORTED=1 STEAM_MULTIPLE_XWAYLANDS=1; do
		check_true "session : $e" grep -qx "$e" /tmp/m2-steam.env
	done
	check "session : jeu lancé par rago-launch dans la session" rc=7 "$(tail -1 /tmp/m2-session-game.out)"
	if [ "$mangoapp" = 1 ]; then
		check_true "session : STEAM_USE_MANGOAPP" grep -qx STEAM_USE_MANGOAPP=1 /tmp/m2-steam.env
		check "session : HUD mangoapp caché au départ" no_display "$(cat "$UXDG/rago/mangoapp.conf" 2>/dev/null)"
		check "session : pas de mangohud en double dans le jeu" 0 "$(grep -c '^MANGOHUD=1' /tmp/m2-game.env)"
	else
		check "session sans mangoapp : Steam ne l'attend pas" 0 "$(grep -c '^STEAM_USE_MANGOAPP' /tmp/m2-steam.env)"
		check_true "session sans mangoapp : le jeu a MangoHud (rago-launch)" grep -qx 'MANGOHUD=1' /tmp/m2-game.env
		check_true "session sans mangoapp : signalé" grep -q 'mangoapp absent' /tmp/session.log
	fi
	check_true "session : le jeu passe par gamemoderun (/usr/games retrouvé)" grep -qE '^LD_PRELOAD=.*libgamemodeauto' /tmp/m2-game.env
else
	say "FAIL session : Steam (factice) jamais lancé par gamescope"
fi
grep -v scriptmgr /tmp/session.log | head -20 | show
check_true "session : journal Rago écrit" test -s "$UH/.local/state/rago/session.log"
check_true "session : sync Steam tenté (Steam jamais démarré : code 3)" grep -q 'code 3' "$UH/.local/state/rago/session.log"
rm -f /tmp/m2-game.*

# --- 5. vrai polkit : la règle Rago passe avant celle de gamemode ------------------------------
mkdir -p /run/dbus
dbus-daemon --system --fork --nopidfile 2>/dev/null || dbus-daemon --system --fork
start_polkit() {
	/usr/lib/polkit-1/polkitd --no-debug > /tmp/polkitd.log 2>&1 &
	polkit_pid=$!
	for _ in $(seq 1 50); do pkaction >/dev/null 2>&1 && return 0; sleep 0.2; done
	return 1
}
stop_polkit() { kill "$polkit_pid" 2>/dev/null; wait "$polkit_pid" 2>/dev/null; }
pk_rc() { # code de pkcheck pour une action, demandé par un processus du joueur
	# shellcheck disable=SC2016 # $1 et $$ du shell du joueur
	runuser -u "$U" -- bash -c 'pkcheck --action-id "$1" --process $$ >/dev/null 2>&1; echo $?' _ "$1"
}
ACTIONS="governor-helper cpu-helper gpu-helper procsys-helper"
mv /etc/polkit-1/rules.d/40-rago-gamemode.rules /tmp/40-rago-gamemode.rules
if start_polkit; then
	for a in $ACTIONS; do
		check "polkit sans la règle Rago : gamemode.rules autorise $a (témoin)" 0 "$(pk_rc "com.feralinteractive.GameMode.$a")"
	done
	stop_polkit
else
	say "FAIL polkitd ne démarre pas"; show < /tmp/polkitd.log
fi
mv /tmp/40-rago-gamemode.rules /etc/polkit-1/rules.d/40-rago-gamemode.rules
if start_polkit; then
	for a in $ACTIONS; do
		check "polkit avec la règle Rago : $a refusé" 1 "$(pk_rc "com.feralinteractive.GameMode.$a")"
	done
	check "polkit : règle Rago compilée sans erreur" 0 "$(grep -ciE 'error|exception' /tmp/polkitd.log)"
else
	say "FAIL polkitd ne démarre pas (avec la règle)"; show < /tmp/polkitd.log
fi

# --- 6. vrai gamemode + vraie chaîne de lancement -----------------------------------------------
cat > "$T/gm-chain.sh" <<'EOF'
#!/bin/bash
stdbuf -oL -eL gamemoded > /tmp/gamemoded.log 2>&1 &
gm=$!
for _ in $(seq 1 50); do gamemoded -s >/dev/null 2>&1 && break; sleep 0.2; done
GAME_OUT=/tmp/m2-chain rago-launch /opt/rago-test/fake-game > /tmp/m2-chain.out 2>&1
echo "rc=$?" >> /tmp/m2-chain.out
# Le jeu fini, gamemode se relâche (au plus tard au passage du « reaper », 5 s).
for _ in $(seq 1 30); do gamemoded -s > /tmp/m2-chain.after 2>&1; grep -q inactive /tmp/m2-chain.after && break; sleep 0.5; done
kill $gm; wait $gm 2>/dev/null
exit 0
EOF
chmod 755 "$T/gm-chain.sh"
as_user dbus-run-session -- "$T/gm-chain.sh"
check "chaîne : code du jeu rendu" rc=7 "$(tail -1 /tmp/m2-chain.out)"
check_true "chaîne : le jeu inscrit chez le vrai gamemoded" grep -qE 'gamemode is active and \[[0-9]+\] registered' /tmp/m2-chain.gm
check_true "chaîne : gamemode relâché après le jeu" grep -q 'gamemode is inactive' /tmp/m2-chain.after
check_true "chaîne : LD_PRELOAD gamemode" grep -qE '^LD_PRELOAD=.*libgamemodeauto' /tmp/m2-chain.env
check_true "chaîne : MangoHud (vrai script mangohud)" grep -qx 'MANGOHUD=1' /tmp/m2-chain.env
check_true "chaîne : LD_PRELOAD MangoHud" grep -qE '^LD_PRELOAD=.*MangoHud' /tmp/m2-chain.env
check_true "chaîne : cache de shaders du jeu par GPU" grep -qE "^MESA_SHADER_CACHE_DIR=$UH/.local/share/rago/shader-cache/[^/]+/exe-fake-game/mesa$" /tmp/m2-chain.env
check_true "chaîne : RAGO_LAUNCH_ACTIVE" grep -qx 'RAGO_LAUNCH_ACTIVE=1' /tmp/m2-chain.env
if [ -x /usr/local/bin/rago-profiled ]; then
	check_true "chaîne : passée par rago-profiled launch (M14, démon arrêté : jeu lancé sans profil)" grep -qi 'profiled' /tmp/m2-chain.out
fi
show < /tmp/m2-chain.out
check_true "gamemoded : lit /etc/gamemode.ini" grep -q 'Loading config file \[/etc/gamemode.ini\]' /tmp/gamemoded.log
check_true "gamemoded : gouverneur refusé par polkit (vrai pkexec)" grep -q 'Not authorized' /tmp/gamemoded.log
check "gamemoded : ne touche pas aux cœurs (pin/park)" 0 "$(grep -ciE 'pinning|parking' /tmp/gamemoded.log)"
check "gamemoded : pas de renice" 0 "$(grep -ciE 'renic' /tmp/gamemoded.log)"
check "gamemoded : aucune erreur de configuration" 0 "$(grep -ciE 'apply_gpu_optimisations|invalid' /tmp/gamemoded.log)"
head -30 /tmp/gamemoded.log | show

# --- 7. MangoHud lit /etc/MangoHud.conf (vrai calque Vulkan) ----------------------------------
as_user env VK_ICD_FILENAMES="$VK_ICD_FILENAMES" MANGOHUD=1 MANGOHUD_LOG_LEVEL=debug vulkaninfo --summary > /tmp/mh.log 2>&1
check_true "MangoHud : calque chargé" grep -qi 'mangohud' /tmp/mh.log
check_true "MangoHud : /etc/MangoHud.conf lu" grep -q "parsing config: '/etc/MangoHud.conf'" /tmp/mh.log
check "MangoHud : aucune option inconnue" 0 "$(grep -ciE 'unknown option|unrecognized' /tmp/mh.log)"
grep -i 'config' /tmp/mh.log | head -5 | show

# --- 8. côté joueur, pré-chauffage ------------------------------------------------------------
as_user "$SETUP" user > /tmp/user.log 2>&1; rc=$?
check "user : code" 0 "$rc"
check_true "user : Steam jamais démarré signalé" grep -q 'Steam jamais démarré' /tmp/user.log
check "user : refusé en root" 1 "$("$SETUP" user >/dev/null 2>&1; echo $?)"
as_user rago-shader-cache status > /tmp/sc.log 2>&1
check_true "rago-shader-cache status : GPU affiché" grep -q '^gpu ' /tmp/sc.log
as_user rago-shader-cache prewarm > /tmp/pw.log 2>&1; rc=$?
check "pré-chauffage sans fossilize-replay (Ubuntu ne l'empaquette pas) : en attente, code 4" 4 "$rc"

# --- 9. réinstall (idempotent), uninstall -----------------------------------------------------
"$SETUP" install > /tmp/install2.log 2>&1; rc=$?
check "réinstall : code" 0 "$rc"
again=$(for f in /usr/bin/rago-launch /usr/bin/rago-session /etc/gamemode.ini /etc/MangoHud.conf \
	/etc/polkit-1/rules.d/40-rago-gamemode.rules /etc/rago/proton-layer.conf; do sha "$f" | cut -c1-8; done | tr '\n' ' ')
check "réinstall : mêmes fichiers" "$installed" "$again"
"$SETUP" uninstall > /tmp/uninstall.log 2>&1; rc=$?
check "uninstall : code" 0 "$rc"
[ "$rc" = 0 ] || tail -20 /tmp/uninstall.log | show
for f in /usr/bin/rago-launch /usr/bin/rago-session /usr/bin/rago-shader-cache /usr/bin/rago-steam-config \
	/etc/polkit-1/rules.d/40-rago-gamemode.rules /usr/share/wayland-sessions/rago.desktop /etc/rago/proton-layer.conf; do
	check_true "retiré : $f" test ! -e "$f"
done
check "uninstall : /etc/gamemode.ini comme avant" "$before_gm" "$(sha /etc/gamemode.ini)"
check "uninstall : /etc/MangoHud.conf comme avant" "$before_mh" "$(sha /etc/MangoHud.conf)"
check "uninstall : capacités de gamescope comme avant" "$before_cap" "$(getcap /usr/games/gamescope 2>/dev/null)"
check "verify après uninstall : échec" 1 "$("$SETUP" verify >/dev/null 2>&1; echo $?)"
check_true "uninstall : paquets gardés (Steam, gamemode, MangoHud, gamescope)" test -x /usr/games/steam -a -x /usr/games/gamemoderun -a -x /usr/bin/mangohud -a -x /usr/games/gamescope

say "INFO EN ATTENTE DE MATÉRIEL : affichage plein écran, VRR, HDR, tearing, --rt, FPS / 1 % low, effet du pré-chauffage, jeu EAC / BattlEye"
say "FIN"
