#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — câblage du hook de lancement et du pré-chauffage (module M2).
#
# Sans root, sans matériel. Utilise les VRAIS binaires de M14 (rago-profiled,
# démon + launch) et de M0 (rago-sched-hint, sans scx_rago chargé : le jeu se
# lance quand même), avec une fausse racine pour le démon (cpufreq, THP,
# PM QoS factices, comme les tests de M14) et la base communautaire de M14.
# gamemoderun, mangohud et fossilize-replay sont factices (ils notent ce
# qu'ils reçoivent) : les vrais sont testés par tests/chroot/.
#
# Usage : cargo build -p rago-profiled -p rago-sched-hint && host/tests/test_rago_launch.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
launch="$repo/host/proton/rago-launch.sh"
shader="$repo/host/proton/rago-shader-cache.sh"
PROFILED=${RAGO_TEST_PROFILED:-$repo/target/debug/rago-profiled}
HINT=${RAGO_TEST_SCHED_HINT:-$repo/target/debug/rago-sched-hint}
for b in "$PROFILED" "$HINT"; do
	[ -x "$b" ] || { echo "$b absent : cargo build -p rago-profiled -p rago-sched-hint" >&2; exit 2; }
done

tmp=$(mktemp -d)
dpid=""
cleanup() {
	[ -n "$dpid" ] && kill "$dpid" 2>/dev/null && wait "$dpid" 2>/dev/null
	jobs -p | xargs -r kill 2>/dev/null
	rm -rf "$tmp"
}
trap cleanup EXIT
pass=0
fail=0
check() {
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); printf 'ÉCHEC %s\n  attendu : %s\n  obtenu  : %s\n' "$1" "$2" "$3"
	fi
}
yes_() { if "$@"; then echo oui; else echo non; fi; }
wait_for() { local i; for i in $(seq 1 100); do eval "$1" && return 0; sleep 0.1; done; return 1; }

# --- environnement factice ------------------------------------------------------------------
H="$tmp/home"; mkdir -p "$H"
export HOME="$H" XDG_RUNTIME_DIR="$tmp/xdg" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" XDG_DATA_HOME="$H/.local/share"
mkdir -p "$XDG_RUNTIME_DIR"
unset SteamAppId SteamGameId MESA_SHADER_CACHE_DIR LD_PRELOAD MANGOHUD RAGO_LAUNCH_ACTIVE RAGO_SESSION_MANGOAPP DRI_PRIME 2>/dev/null
SYS="$tmp/sys"
mkgpu() { # mkgpu <cardN> <pci> <vendor> <device> <pilote> <boot_vga>
	local d="$SYS/devices/pci0000:00/$2"
	mkdir -p "$d" "$SYS/class/drm/$1" "$SYS/bus/pci/drivers/$5"
	printf '0x%s\n' "$3" > "$d/vendor"; printf '0x%s\n' "$4" > "$d/device"; echo "$6" > "$d/boot_vga"
	ln -s "../../../bus/pci/drivers/$5" "$d/driver"
	ln -s "../../../devices/pci0000:00/$2" "$SYS/class/drm/$1/device"
}
mkgpu card0 0000:03:00.0 1002 744c amdgpu 1
mkgpu card1 0000:00:02.0 8086 a780 i915 0
export RAGO_SYSFS="$SYS"
export RAGO_PROTON_CONF_FILE="$tmp/proton-layer.conf"
printf 'RAGO_SHADER_PREWARM="background"\n' > "$RAGO_PROTON_CONF_FILE"

BIN="$tmp/bin"; mkdir -p "$BIN" "$tmp/lib"
GMLIB=libgamemodeauto.so.0
# Bibliothèque vide pour que ld.so ne se plaigne pas du LD_PRELOAD factice.
gcc -shared -o "$tmp/lib/$GMLIB" -x c /dev/null 2>/dev/null && GMLIB="$tmp/lib/$GMLIB"
TRACE="$tmp/trace"
cat > "$BIN/gamemoderun" <<EOF
#!/bin/bash
echo "gamemoderun \$*" >> "$TRACE"
export LD_PRELOAD="\${LD_PRELOAD:+\$LD_PRELOAD:}$GMLIB"
exec "\$@"
EOF
cat > "$BIN/mangohud" <<EOF
#!/bin/bash
echo "mangohud \$*" >> "$TRACE"
export MANGOHUD=1
exec "\$@"
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export RAGO_PROFILED_BIN="$PROFILED" RAGO_SCHED_HINT_BIN="$HINT"
export RAGO_LAUNCH_QUIET=1

# Faux jeu : note son environnement et le THP vu pendant qu'il tourne, attend
# le fichier « fin », sort en code 7.
F="$tmp/root"
GAMEDIR="$tmp/jeux"; mkdir -p "$GAMEDIR"
cat > "$GAMEDIR/Cyberpunk2077.exe" <<EOF
#!/bin/bash
out=\${GAME_OUT:-$tmp/game}
env > "\$out.env"
echo \$\$ > "\$out.pid"
cat "$F/sys/kernel/mm/transparent_hugepage/enabled" > "\$out.thp"
trap 'echo TERM > "\$out.sig"; exit 143' TERM
for i in \$(seq 1 100); do [ -e "\$out.fin" ] && break; sleep 0.1; done
exit 7
EOF
chmod +x "$GAMEDIR/Cyberpunk2077.exe"
cp "$GAMEDIR/Cyberpunk2077.exe" "$GAMEDIR/inconnu.x86_64"

# Fausse racine du démon M14 (comme daemons/rago-profiled/tests/cli.rs).
for i in 0 1; do
	mkdir -p "$F/sys/devices/system/cpu/cpufreq/policy$i"
	echo performance > "$F/sys/devices/system/cpu/cpufreq/policy$i/scaling_governor"
	echo "performance powersave" > "$F/sys/devices/system/cpu/cpufreq/policy$i/scaling_available_governors"
done
mkdir -p "$F/sys/kernel/mm/transparent_hugepage" "$F/sys/devices/system/cpu/cpu0/cpuidle/state1" "$F/proc" "$F/etc/rago" "$F/dev" "$F/run" "$F/hooks"
echo "always [madvise] never" > "$F/sys/kernel/mm/transparent_hugepage/enabled"
echo 2 > "$F/sys/devices/system/cpu/cpu0/cpuidle/state1/latency"
echo "root=/dev/x quiet" > "$F/proc/cmdline"
echo 'RAGO_CSTATES="deep"' > "$F/etc/rago/host-tuning.conf"
printf '\x00\x94\x35\x77' > "$F/dev/cpu_dma_latency"
export RAGO_PROFILED_SOCKET="$F/run/profiled.sock"
start_daemon() {
	"$PROFILED" --profiles-dir "$repo/profiles/community" daemon --group "" --state-dir "$F/run" \
		--hooks-dir "$F/hooks" --root "$F" --pmqos-dev "$F/dev/cpu_dma_latency" 2>> "$tmp/daemon.log" &
	dpid=$!
	wait_for "[ -S '$RAGO_PROFILED_SOCKET' ]" || { echo "démon M14 muet" >&2; cat "$tmp/daemon.log"; exit 1; }
}
# THP lu comme le noyau l'affiche (« always [madvise] never ») ou comme le démon
# l'écrit dans la fausse racine (« always »), comme thp() des tests de M14.
thp_of() { local s; s=$(cat "$1" 2>/dev/null); case $s in *\[*\]*) s=${s#*[}; s=${s%%]*} ;; esac; printf '%s' "$s"; }
thp() { thp_of "$F/sys/kernel/mm/transparent_hugepage/enabled"; }

# Fausse chaîne Steam : reaper et steam-launch-wrapper lancent ce qui suit « -- »,
# proton lance l'exe (le vrai passerait par Wine).
S="$tmp/s"; mkdir -p "$S"
# shellcheck disable=SC2016 # le script écrit garde ses $ littéraux
printf '#!/bin/bash\nwhile [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done\nshift\nexec "$@"\n' > "$S/reaper"
cp "$S/reaper" "$S/steam-launch-wrapper"
# shellcheck disable=SC2016
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$S/proton"
chmod +x "$S"/*
PROTON=("$S/reaper" SteamLaunch AppId=1091500 -- "$S/steam-launch-wrapper" -- "$S/proton" waitforexitandrun "$GAMEDIR/Cyberpunk2077.exe")
P() { bash "$launch" --print -- "$@"; }
line() { grep -c -x -F "$1"; }

# === A. ce que rago-launch prépare (--print) =================================================
out=$(SteamAppId=1091500 P "${PROTON[@]}")
CR="$H/.local/share/rago/shader-cache"
check "print : clé du jeu" 1 "$(line "game:steam-1091500" <<< "$out")"
check "print : exe" 1 "$(line "exe:cyberpunk2077.exe" <<< "$out")"
check "print : GPU principal" 1 "$(line "gpu:amdgpu-1002-744c" <<< "$out")"
check "print : cache Mesa par GPU" 1 "$(line "env:MESA_SHADER_CACHE_DIR=$CR/amdgpu-1002-744c/steam-1091500/mesa" <<< "$out")"
check "print : cache NVIDIA" 1 "$(line "env:__GL_SHADER_DISK_CACHE_PATH=$CR/amdgpu-1002-744c/steam-1091500/nvidia" <<< "$out")"
argv=$(sed -n 's/^argv://p' <<< "$out" | tr '\n' ' ')
check "print : chaîne M14 -> gamemode -> MangoHud -> jeu" "$PROFILED launch --exe cyberpunk2077.exe -- $BIN/gamemoderun $BIN/mangohud ${PROTON[*]} " "$argv"
out=$(SteamAppId=1091500 MESA_SHADER_CACHE_DIR=/steam/shadercache/1091500 P "${PROTON[@]}")
check "print : cache posé par Steam gardé" 0 "$(grep -c '^env:MESA_SHADER_CACHE_DIR' <<< "$out")"
check "print : les autres caches posés" 1 "$(grep -c '^env:DXVK_STATE_CACHE_PATH' <<< "$out")"
out=$(DRI_PRIME=1 P "$GAMEDIR/inconnu.x86_64")
check "print : DRI_PRIME=1 -> autre GPU, autre cache" 1 "$(line "gpu:i915-8086-a780" <<< "$out")"
check "print : jeu hors Steam" 1 "$(line "game:exe-inconnu.x86_64" <<< "$out")"
out=$(RAGO_PROFILE_ID=counter-strike-2 P /g/cs2)
check "print : RAGO_PROFILE_ID -> --id" "$PROFILED launch --exe cs2 --id counter-strike-2 --" "$(sed -n 's/^argv://p' <<< "$out" | head -7 | tr '\n' ' ' | sed 's/ $//')"
out=$(LD_PRELOAD="$GMLIB" P /g/jeu 2>/dev/null)
check "print : gamemoderun déjà là -> pas deux fois" 0 "$(grep -c gamemoderun <<< "$out")"
out=$(RAGO_SESSION_MANGOAPP=1 P /g/jeu)
check "print : session mangoapp -> pas de mangohud" 0 "$(grep -c 'argv:.*mangohud' <<< "$out")"
out=$(RAGO_MANGOHUD=0 P /g/jeu)
check "print : RAGO_MANGOHUD=0 (option de lancement)" 0 "$(grep -c 'argv:.*mangohud' <<< "$out")"
mkdir -p "$XDG_CONFIG_HOME/rago"; echo 'RAGO_GAMEMODE=0' > "$XDG_CONFIG_HOME/rago/proton-layer.conf"
out=$(P /g/jeu)
check "print : RAGO_GAMEMODE=0 du joueur" 0 "$(grep -c gamemoderun <<< "$out")"
rm -f "$XDG_CONFIG_HOME/rago/proton-layer.conf"
echo 'RAGO_SHADER_CACHE=0' >> "$RAGO_PROTON_CONF_FILE"
out=$(P /g/jeu)
check "print : RAGO_SHADER_CACHE=0 du système" 0 "$(grep -c '^env:MESA' <<< "$out")"
sed -i '/RAGO_SHADER_CACHE=0/d' "$RAGO_PROTON_CONF_FILE"
out=$(RAGO_PROFILED_BIN=/nonexistent P /g/jeu)
check "print : sans M14 -> hint M0 seul" "$HINT run -- $BIN/gamemoderun" "$(sed -n 's/^argv://p' <<< "$out" | head -4 | tr '\n' ' ' | sed 's/ $//')"
out=$(RAGO_PROFILED_BIN=/nonexistent RAGO_SCHED_HINT_BIN=/nonexistent P /g/jeu)
check "print : sans M14 ni M0 -> le jeu seul" "$BIN/gamemoderun $BIN/mangohud /g/jeu" "$(sed -n 's/^argv://p' <<< "$out" | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$XDG_STATE_HOME/rago" "$tmp/eac"
printf 'PROTON_EAC_RUNTIME="%s"\n' "$tmp/eac" > "$XDG_STATE_HOME/rago/proton-runtimes.env"
out=$(P /g/heroic/Fortnite.exe)
check "print : runtime EAC donné au jeu hors Steam" 1 "$(line "env:PROTON_EAC_RUNTIME=$tmp/eac" <<< "$out")"
check "print : BattlEye absent -> rien" 0 "$(grep -c BATTLEYE <<< "$out")"
out=$(SteamAppId=1091500 P "${PROTON[@]}")
check "print : jeu Steam -> Steam gère les runtimes" 0 "$(grep -c EAC <<< "$out")"
mkdir -p "$tmp/layers"; echo '{}' > "$tmp/layers/VkLayer_fossilize.json"
out=$(RAGO_VK_LAYER_DIRS="$tmp/layers" P /g/heroic/Fortnite.exe)
check "print : capture Fossilize hors Steam" 1 "$(line "env:FOSSILIZE_DUMP_PATH=$CR/amdgpu-1002-744c/exe-fortnite.exe/fossilize/rago" <<< "$out")"
out=$(RAGO_VK_LAYER_DIRS="$tmp/layers" SteamAppId=1091500 P "${PROTON[@]}")
check "print : pas de capture Rago pour Steam (Steam capture)" 0 "$(grep -c FOSSILIZE <<< "$out")"
out=$(bash "$launch" 2>&1); rc=$?
check "sans commande : usage, code 2" 2 "$rc"

# === B. vrai lancement : profil M14 + hint M0 ===============================================
start_daemon
check "base avant le jeu : THP madvise" madvise "$(thp)"
: > "$TRACE"
(SteamAppId=1091500 exec bash "$launch" "${PROTON[@]}") 2> "$tmp/launch.err" &
lpid=$!
wait_for "[ -s '$tmp/game.thp' ]" || echo "le jeu n'a pas démarré" >&2
check "pendant le jeu : profil Cyberpunk appliqué (THP always vu par le jeu)" always "$(thp_of "$tmp/game.thp")"
st=$("$PROFILED" status 2>&1)
check "pendant le jeu : session M14 active" oui "$(yes_ grep -q 'cyberpunk-2077' <<< "$st")"
check "pendant le jeu : gamemoderun puis mangohud" "gamemoderun mangohud" "$(cut -d' ' -f1 "$TRACE" | tr '\n' ' ' | sed 's/ $//')"
genv="$tmp/game.env"
check "pendant le jeu : LD_PRELOAD de gamemode" oui "$(yes_ grep -q '^LD_PRELOAD=.*libgamemodeauto' "$genv")"
check "pendant le jeu : MangoHud" oui "$(yes_ grep -qx 'MANGOHUD=1' "$genv")"
check "pendant le jeu : cache Mesa du jeu" oui "$(yes_ grep -qx "MESA_SHADER_CACHE_DIR=$CR/amdgpu-1002-744c/steam-1091500/mesa" "$genv")"
check "pendant le jeu : RAGO_LAUNCH_ACTIVE" oui "$(yes_ grep -qx 'RAGO_LAUNCH_ACTIVE=1' "$genv")"
check "pendant le jeu : marque « jeu en cours »" oui "$(yes_ test -f "$XDG_RUNTIME_DIR/rago/games/$lpid")"
check "pendant le jeu : le PID marqué est rago-profiled launch" rago-profiled "$(cut -c1-13 "/proc/$lpid/comm")"
# shellcheck source-path=SCRIPTDIR source=../lib/rago_proton_lib.sh
. "$repo/host/lib/rago_proton_lib.sh"
check "pendant le jeu : le pré-chauffage verrait le jeu" 0 "$(rago_pl_games_active "$XDG_RUNTIME_DIR/rago/games" /proc; echo $?)"
gd="$CR/amdgpu-1002-744c/steam-1091500"
check "noté : environnement de cache du jeu" oui "$(yes_ grep -qx "MESA_SHADER_CACHE_DIR=$gd/mesa" "$gd/game.env")"
check "noté : pas de variable hors cache" 0 "$(grep -c '^PATH=' "$gd/game.env")"
check "noté : bases Fossilize Rago" oui "$(yes_ grep -qx "$gd/fossilize" "$gd/foz-dirs")"
touch "$tmp/game.fin"
wait "$lpid"; rc=$?
check "après le jeu : code du jeu rendu" 7 "$rc"
check "après le jeu : base M1 remise (THP madvise)" madvise "$(thp)"
check "après le jeu : plus de jeu en cours" 1 "$(rago_pl_games_active "$XDG_RUNTIME_DIR/rago/games" /proc; echo $?)"
rm -f "$tmp"/game.*

# Jeu inconnu : profil sûr par défaut, rien ne bouge.
(exec bash "$launch" "$GAMEDIR/inconnu.x86_64") 2>/dev/null &
lpid=$!
wait_for "[ -s '$tmp/game.thp' ]"
check "jeu inconnu : THP inchangé pendant le jeu" madvise "$(thp_of "$tmp/game.thp")"
touch "$tmp/game.fin"; wait "$lpid"
rm -f "$tmp"/game.*

# Steam arrête le jeu (SIGTERM) : transmis au jeu, base remise.
(SteamAppId=1091500 exec bash "$launch" "${PROTON[@]}") 2>/dev/null &
lpid=$!
wait_for "[ -s '$tmp/game.thp' ]"
kill -TERM "$lpid"
wait "$lpid"; rc=$?
check "SIGTERM : reçu par le jeu" TERM "$(cat "$tmp/game.sig" 2>/dev/null)"
check "SIGTERM : code 143" 143 "$rc"
check "SIGTERM : base remise" madvise "$(thp)"
rm -f "$tmp"/game.*

# Démon M14 arrêté : le jeu se lance quand même.
kill "$dpid"; wait "$dpid" 2>/dev/null; dpid=""
touch "$tmp/game.fin"
SteamAppId=1091500 bash "$launch" "${PROTON[@]}" 2>/dev/null; rc=$?
check "sans démon M14 : jeu lancé, code rendu" 7 "$rc"
rm -f "$tmp"/game.*

# Déjà sous rago-launch : pas de deuxième enveloppe.
: > "$TRACE"; touch "$tmp/game.fin"
RAGO_LAUNCH_ACTIVE=1 bash "$launch" "$GAMEDIR/inconnu.x86_64"; rc=$?
check "imbriqué : lancé directement" "7 0" "$rc $(wc -l < "$TRACE")"
rm -f "$tmp"/game.*

# === C. pré-chauffage Fossilize (fossilize-replay factice) ===================================
RLOG="$tmp/replay.log"
cat > "$BIN/fossilize-replay" <<EOF
#!/bin/bash
db=\${@: -1}
echo "\$(basename "\$db") threads=\$4 mesa=\$MESA_SHADER_CACHE_DIR prime=\${DRI_PRIME:-}" >> "$RLOG"
echo \$\$ > "$tmp/replay.pid"
mkdir -p "\$MESA_SHADER_CACHE_DIR" && touch "\$MESA_SHADER_CACHE_DIR/warm-\$(basename "\$db")"
sleep "\${FAKE_REPLAY_SLEEP:-0}"
exit "\${FAKE_REPLAY_RC:-0}"
EOF
chmod +x "$BIN/fossilize-replay"
FR="$tmp/fakeroot"; mkdir -p "$FR/usr/share/vulkan/icd.d" "$FR/usr/lib"
echo '{"ICD":{"library_path":"/usr/lib/libvulkan_radeon.so"}}' > "$FR/usr/share/vulkan/icd.d/radeon_icd.json"
echo v1 > "$FR/usr/lib/libvulkan_radeon.so"
export RAGO_ROOTFS="$FR"
SC() { bash "$shader" "$@"; }
steamfoz="$tmp/SteamLibrary/steamapps/shadercache/1091500/fozpipelinesv6"
mkdir -p "$steamfoz"
echo "base-a" > "$gd/fossilize/rago.1.foz"
echo "base-steam" > "$steamfoz/steamapprun_pipeline_cache.foz"
echo "$steamfoz" >> "$gd/foz-dirs"
: > "$RLOG"
out=$(MESA_SHADER_CACHE_DIR=/faux SC prewarm --threads 3 2>&1); rc=$?
check "prewarm : code" 0 "$rc"
check "prewarm : deux bases rejouées" 2 "$(wc -l < "$RLOG")"
check "prewarm : environnement du jeu, pas le nôtre" 2 "$(grep -c "mesa=$gd/mesa " "$RLOG")"
check "prewarm : nombre de fils" 2 "$(grep -c 'threads=3' "$RLOG")"
check "prewarm : cache du jeu rempli" oui "$(yes_ test -e "$gd/mesa/warm-steamapprun_pipeline_cache.foz")"
check "prewarm : tampon" 2 "$(wc -l < "$gd/prewarm.stamp")"
: > "$RLOG"
out=$(SC prewarm 2>&1)
check "prewarm encore : rien à refaire" 0 "$(wc -l < "$RLOG")"
check "prewarm encore : message" oui "$(yes_ grep -q '2 déjà faite' <<< "$out")"
echo "base-a plus grosse" > "$gd/fossilize/rago.1.foz"
SC prewarm >/dev/null 2>&1
check "base changée : seule elle est rejouée" "rago.1.foz" "$(cut -d' ' -f1 "$RLOG")"
: > "$RLOG"
echo v2-mise-a-jour > "$FR/usr/lib/libvulkan_radeon.so"
SC prewarm >/dev/null 2>&1
check "pilote mis à jour : tout est rejoué" 2 "$(wc -l < "$RLOG")"
: > "$RLOG"
echo "nouvelle" > "$steamfoz/steam_pipeline_cache.foz"
FAKE_REPLAY_RC=1 SC prewarm >/dev/null 2>&1; rc=$?
check "rejeu en échec : code 1" 1 "$rc"
FAKE_REPLAY_RC=0 SC prewarm >/dev/null 2>&1
check "rejeu en échec : refait au passage suivant" 2 "$(grep -c steam_pipeline_cache.foz "$RLOG")"
# Pause pendant un jeu.
sleep 60 & holder=$!
rago_pl_proc_starttime "$holder" /proc > "$XDG_RUNTIME_DIR/rago/games/$holder"
echo "encore une" > "$gd/fossilize/rago.2.foz"
: > "$RLOG"
(FAKE_REPLAY_SLEEP=4 SC prewarm --wait-games > "$tmp/pw.out" 2>&1) &
pw=$!
wait_for "[ -s '$tmp/replay.pid' ] && [ \"\$(awk '{print \$3}' /proc/\$(cat '$tmp/replay.pid')/stat 2>/dev/null)\" = T ]"
rp=$(cat "$tmp/replay.pid")
check "jeu en cours : rejeu en pause (état T)" T "$(awk '{print $3}' "/proc/$rp/stat" 2>/dev/null)"
kill "$holder"; wait "$holder" 2>/dev/null
wait_for "[ \"\$(awk '{print \$3}' /proc/$rp/stat 2>/dev/null)\" != T ]"
check "jeu fini : rejeu repris" non "$(yes_ test "$(awk '{print $3}' "/proc/$rp/stat" 2>/dev/null)" = T)"
wait "$pw"; rc=$?
check "pause puis reprise : fini" 0 "$rc"
check "pause : messages" oui "$(yes_ grep -q 'en pause' "$tmp/pw.out")"
rm -f "$tmp/replay.pid"
# Délai.
echo "longue" > "$gd/fossilize/rago.3.foz"
t0=$(date +%s)
FAKE_REPLAY_SLEEP=30 SC prewarm --timeout 2 --no-wait-games >/dev/null 2>&1
t1=$(date +%s)
check "délai : arrêté à temps" oui "$(yes_ test $((t1 - t0)) -le 6)"
check "délai : pas de tampon" 0 "$(grep -c 'rago.3.foz' "$gd/prewarm.stamp")"
check "délai : rejeu tué" non "$(yes_ kill -0 "$(cat "$tmp/replay.pid")" 2>/dev/null)"
# Un seul jeu, état, verrou, binaire absent.
: > "$RLOG"
SC prewarm --game exe-inconnu.x86_64 >/dev/null 2>&1
check "--game : seulement ce jeu" 0 "$(grep -c rago.3 "$RLOG")"
out=$(SC status 2>&1)
check "status : GPU" oui "$(yes_ grep -q '^gpu amdgpu-1002-744c' <<< "$out")"
check "status : jeu listé" oui "$(yes_ grep -q 'steam-1091500 : 5 base(s)' <<< "$out")"
rm -f "$tmp/replay.pid"
(FAKE_REPLAY_SLEEP=3 SC prewarm --no-wait-games >/dev/null 2>&1) &
pw=$!
wait_for "[ -s '$tmp/replay.pid' ]"
out=$(SC prewarm 2>&1)
check "verrou : un seul pré-chauffage" oui "$(yes_ grep -q 'tourne déjà' <<< "$out")"
wait "$pw"
rm "$BIN/fossilize-replay"
out=$(PATH="$BIN:/usr/bin:/bin" SC prewarm 2>&1); rc=$?
check "sans fossilize-replay : en attente (code 4)" 4 "$rc"
check "sans fossilize-replay : message" oui "$(yes_ grep -q 'en attente' <<< "$out")"

printf '%d tests OK, %d échec(s)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
