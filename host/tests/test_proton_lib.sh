#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests unitaires de host/lib/rago_proton_lib.sh (module M2).
# Sans root, sans matériel. Usage : host/tests/test_proton_lib.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib/rago_proton_lib.sh
. "$here/../lib/rago_proton_lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

check() { # check <nom> <attendu> <obtenu>
	if [ "$2" = "$3" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'ÉCHEC %s\n  attendu : %s\n  obtenu  : %s\n' "$1" "$2" "$3"
	fi
}
check_rc() { # check_rc <nom> <code attendu> <commande...>
	local name=$1 want=$2 got
	shift 2
	"$@" >/dev/null 2>&1
	got=$?
	check "$name (code retour)" "$want" "$got"
}

# --- KEY=valeur et priorité des réglages -------------------------------------------------
printf '# x\nRAGO_GAMEMODE="0"\nRAGO_SHADER_CACHE_SIZE=2G\n' > "$tmp/sys.conf"
printf 'RAGO_GAMEMODE=1\n' > "$tmp/usr.conf"
check "conf_get" 0 "$(rago_pl_conf_get "$tmp/sys.conf" RAGO_GAMEMODE)"
check "conf_get défaut" x "$(rago_pl_conf_get "$tmp/sys.conf" NOPE x)"
rago_pl_conf_set "$tmp/sys.conf" RAGO_SHADER_CACHE_SIZE 8G
check "conf_set remplace" 8G "$(rago_pl_conf_get "$tmp/sys.conf" RAGO_SHADER_CACHE_SIZE)"
check "conf_set garde le reste" 3 "$(wc -l < "$tmp/sys.conf")"
check_rc "conf_set refuse un guillemet" 2 rago_pl_conf_set "$tmp/sys.conf" K 'a"b'
check "setting : fichier système" 0 "$(rago_pl_setting RAGO_GAMEMODE 1 "$tmp/sys.conf")"
check "setting : fichier joueur prime" 1 "$(rago_pl_setting RAGO_GAMEMODE 1 "$tmp/sys.conf" "$tmp/usr.conf")"
check "setting : environnement prime" 0 "$(RAGO_GAMEMODE=0 rago_pl_setting RAGO_GAMEMODE 1 "$tmp/sys.conf" "$tmp/usr.conf")"
check "setting : défaut" 4G "$(rago_pl_setting RAGO_ABSENT 4G "$tmp/none" "$tmp/none2")"
check "bool oui" 1 "$(rago_pl_bool oui)"
check "bool off" 0 "$(rago_pl_bool OFF)"
check_rc "bool illisible" 2 rago_pl_bool peut-être

# --- identité du jeu ------------------------------------------------------------------------
proton=(/s/reaper SteamLaunch AppId=1091500 -- /s/steam-launch-wrapper -- /s/SLR/_v2-entry-point --verb=waitforexitandrun -- /s/proton waitforexitandrun "/g/Cyberpunk 2077/bin/x64/Cyberpunk2077.exe" --launcher-skip)
check "exe : .exe de la chaîne Proton" cyberpunk2077.exe "$(rago_pl_exe_key "${proton[@]}")"
native=(/s/reaper SteamLaunch AppId=730 -- /s/steam-launch-wrapper -- /s/SLR/_v2-entry-point --verb=waitforexitandrun -- /g/cs2/game/cs2.sh -steam)
check "exe : après le dernier -- (natif Steam)" cs2.sh "$(rago_pl_exe_key "${native[@]}")"
check "exe : commande simple" supertux2 "$(rago_pl_exe_key /usr/games/supertux2 --fullscreen)"
check "exe : wine (Z:)" game.exe "$(rago_pl_exe_key wine 'Z:/Games/game.exe')"
check "exe : chemin Windows (\\)" game.exe "$(rago_pl_exe_key 'C:\Games\GAME.EXE')"
check_rc "exe : rien" 1 rago_pl_exe_key
check "game : Steam" steam-1091500 "$(rago_pl_game_key 1091500 "${proton[@]}")"
check "game : AppID 0 = hors Steam" exe-cyberpunk2077.exe "$(rago_pl_game_key 0 "${proton[@]}")"
check "game : hors Steam, caractères sûrs" "exe-my_game_.x86_64" "$(rago_pl_game_key "" "/g/My Game!.x86_64")"

# --- GPU -------------------------------------------------------------------------------------
mkgpu() { # mkgpu <sysfs> <cardN> <pci> <vendor> <device> <pilote> <boot_vga>
	local s=$1 d="$1/devices/pci0000:00/$3"
	mkdir -p "$d" "$s/class/drm" "$s/bus/pci/drivers/$6"
	printf '0x%s\n' "$4" > "$d/vendor"
	printf '0x%s\n' "$5" > "$d/device"
	[ "$7" = "-" ] || echo "$7" > "$d/boot_vga"
	ln -s "../../../bus/pci/drivers/$6" "$d/driver"
	mkdir -p "$s/class/drm/$2"
	ln -s "../../../devices/pci0000:00/$3" "$s/class/drm/$2/device"
}
S="$tmp/sys"
mkgpu "$S" card0 0000:00:02.0 8086 a780 i915 0
mkgpu "$S" card1 0000:03:00.0 1002 744C amdgpu 1
mkdir -p "$S/class/drm/card1-DP-1"
check "gpu : liste (connecteurs ignorés)" 2 "$(rago_pl_gpu_list "$S" | wc -l)"
check "gpu : principal (boot_vga)" amdgpu-1002-744c "$(rago_pl_gpu_key "$S")"
check "gpu : dgpu = non principal" i915-8086-a780 "$(rago_pl_gpu_key "$S" dgpu)"
check "gpu : cardN" i915-8086-a780 "$(rago_pl_gpu_key "$S" card0)"
check "gpu : vendor:device" amdgpu-1002-744c "$(rago_pl_gpu_key "$S" 1002:744c)"
check "gpu : pci-…" i915-8086-a780 "$(rago_pl_gpu_key "$S" pci-0000_00_02_0)"
check "gpu : nom de pilote" i915-8086-a780 "$(rago_pl_gpu_key "$S" i915)"
check "gpu : sélecteur inconnu -> première carte" i915-8086-a780 "$(rago_pl_gpu_key "$S" nvidia)"
check "gpu : aucune carte" aucun-gpu "$(rago_pl_gpu_key "$tmp/vide")"
S2="$tmp/sys2"
mkgpu "$S2" card0 0000:01:00.0 10de 2684 nvidia -
check "gpu : sans boot_vga -> première carte" nvidia-10de-2684 "$(rago_pl_gpu_key "$S2")"
check "sélecteur : RAGO_GPU prime" card3 "$(rago_pl_gpu_selector card3 1 1)"
check "sélecteur : DRI_PRIME=1" dgpu "$(rago_pl_gpu_selector "" 1 "")"
check "sélecteur : DRI_PRIME=vendor:device" 1002:744c "$(rago_pl_gpu_selector "" 1002:744c "")"
check "sélecteur : PRIME NVIDIA" nvidia "$(rago_pl_gpu_selector "" "" 1)"
check "sélecteur : rien" "" "$(rago_pl_gpu_selector "" 0 0)"

# --- empreinte des pilotes ---------------------------------------------------------------
F="$tmp/root"
mkdir -p "$F/usr/share/vulkan/icd.d" "$F/usr/lib/x86_64-linux-gnu"
printf '{ "ICD": { "library_path": "libvulkan_radeon.so", "api_version": "1.4.0" } }\n' > "$F/usr/share/vulkan/icd.d/radeon_icd.json"
echo v1 > "$F/usr/lib/x86_64-linux-gnu/libvulkan_radeon.so"
touch -d '2026-01-01' "$F/usr/lib/x86_64-linux-gnu/libvulkan_radeon.so"
fp1=$(rago_pl_driver_fingerprint "$F" "$S")
check "empreinte : 16 caractères" 16 "${#fp1}"
check "empreinte : stable" "$fp1" "$(rago_pl_driver_fingerprint "$F" "$S")"
echo v2-plus-long > "$F/usr/lib/x86_64-linux-gnu/libvulkan_radeon.so"
fp2=$(rago_pl_driver_fingerprint "$F" "$S")
[ "$fp1" != "$fp2" ]; check "empreinte : change avec le pilote" 0 $?
mkdir -p "$S/module/nvidia"; echo 580.95 > "$S/module/nvidia/version"
fp3=$(rago_pl_driver_fingerprint "$F" "$S")
[ "$fp2" != "$fp3" ]; check "empreinte : change avec le module nvidia" 0 $?

# --- caches ---------------------------------------------------------------------------------
check "taille 4G" 4294967296 "$(rago_pl_size_bytes 4G)"
check "taille 500m" 524288000 "$(rago_pl_size_bytes 500m)"
check "taille en octets" 1024 "$(rago_pl_size_bytes 1024)"
check_rc "taille illisible" 2 rago_pl_size_bytes 4T
env_out=$(rago_pl_cache_env /c/amdgpu/steam-1 4g)
check "cache : 8 variables" 8 "$(printf '%s\n' "$env_out" | wc -l)"
check "cache : Mesa" "MESA_SHADER_CACHE_DIR=/c/amdgpu/steam-1/mesa" "$(printf '%s\n' "$env_out" | grep ^MESA_SHADER_CACHE_DIR)"
check "cache : taille Mesa" "MESA_SHADER_CACHE_MAX_SIZE=4G" "$(printf '%s\n' "$env_out" | grep ^MESA_SHADER_CACHE_MAX)"
check "cache : NVIDIA en octets" "__GL_SHADER_DISK_CACHE_SIZE=4294967296" "$(printf '%s\n' "$env_out" | grep ^__GL_SHADER_DISK_CACHE_SIZE)"
check "cache : NVIDIA jamais nettoyé" "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1" "$(printf '%s\n' "$env_out" | grep SKIP_CLEANUP)"
check_rc "cache : taille refusée" 2 rago_pl_cache_env /c x
check_rc "var de cache : MESA_*" 0 rago_pl_cache_var MESA_SHADER_CACHE_DIR
check_rc "var de cache : DRI_PRIME" 0 rago_pl_cache_var DRI_PRIME
check_rc "var de cache : RADV_PERFTEST" 0 rago_pl_cache_var RADV_PERFTEST
check_rc "var de cache : pas PATH" 1 rago_pl_cache_var PATH
check_rc "var de cache : pas LD_PRELOAD" 1 rago_pl_cache_var LD_PRELOAD

# --- jeux en cours ---------------------------------------------------------------------------
st=$(rago_pl_proc_starttime $$ /proc)
case "$st" in '' | *[!0-9]*) check "starttime numérique" nombre "$st" ;; *) check "starttime numérique" ok ok ;; esac
mkdir -p "$tmp/p/4242"
printf '4242 (jeu (bizarre) x) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 777 19 20\n' > "$tmp/p/4242/stat"
check "starttime : nom avec parenthèses et espaces" 777 "$(rago_pl_proc_starttime 4242 "$tmp/p")"
check_rc "starttime : PID absent" 1 rago_pl_proc_starttime 99999999 /proc
G="$tmp/games"; mkdir -p "$G"
check_rc "jeux : aucun" 1 rago_pl_games_active "$G" /proc
echo "$st" > "$G/$$"
check_rc "jeux : PID vivant" 0 rago_pl_games_active "$G" /proc
echo 1 > "$G/$$"
check_rc "jeux : PID réutilisé (autre départ)" 1 rago_pl_games_active "$G" /proc
rm -f "$G/$$"; echo 5 > "$G/99999999"
check_rc "jeux : PID mort" 1 rago_pl_games_active "$G" /proc

# --- Steam -----------------------------------------------------------------------------------
H="$tmp/home"
mkdir -p "$H/.local/share/Steam/steamapps"
ln -s ../.local/share/Steam "$H/.steam-root-tmp"
mkdir -p "$H/.steam"; ln -s ../.local/share/Steam "$H/.steam/root"
check "steam root : lien ~/.steam/root résolu" "$(cd "$H/.local/share/Steam" && pwd -P)" "$(rago_pl_steam_root "$H")"
H2="$tmp/home2"; mkdir -p "$H2/.steam/debian-installation/ubuntu12_32"
check "steam root : steam-installer Debian" "$(cd "$H2/.steam/debian-installation" && pwd -P)" "$(rago_pl_steam_root "$H2")"
check_rc "steam root : absent" 1 rago_pl_steam_root "$tmp/nobody"
mkdir -p "$H/.local/share/Steam/ubuntu12_64"
printf '#!/bin/sh\n' > "$H/.local/share/Steam/ubuntu12_64/fossilize_replay"; chmod +x "$H/.local/share/Steam/ubuntu12_64/fossilize_replay"
check "fossilize : celui de Steam" "$H/.local/share/Steam/ubuntu12_64/fossilize_replay" "$(PATH=/nonexistent rago_pl_fossilize_bin "$H/.local/share/Steam")"
check "fossilize : RAGO_FOSSILIZE_REPLAY" /bin/true "$(RAGO_FOSSILIZE_REPLAY=/bin/true rago_pl_fossilize_bin "")"
check_rc "fossilize : aucun" 1 env PATH=/nonexistent /bin/bash -c ". '$here/../lib/rago_proton_lib.sh'; rago_pl_fossilize_bin ''"

# --- versions épinglées -----------------------------------------------------------------
cat > "$tmp/lock" <<'EOF'
# commentaire proton-ge x y z
proton-ge GE-Proton10-30 https://h/GE-Proton10-30.tar.gz sha512:abc
heroic-deb PENDING PENDING PENDING
EOF
check "lock : ligne" "GE-Proton10-30 https://h/GE-Proton10-30.tar.gz sha512:abc" "$(rago_pl_lock_get "$tmp/lock" proton-ge)"
check "lock : PENDING" "PENDING PENDING PENDING" "$(rago_pl_lock_get "$tmp/lock" heroic-deb)"
check_rc "lock : absent" 1 rago_pl_lock_get "$tmp/lock" lutris
echo bonjour > "$tmp/f"
check_rc "empreinte sha256 bonne" 0 rago_pl_hash_ok "$tmp/f" "sha256:$(sha256sum "$tmp/f" | cut -d' ' -f1)"
check_rc "empreinte sha512 bonne" 0 rago_pl_hash_ok "$tmp/f" "sha512:$(sha512sum "$tmp/f" | cut -d' ' -f1)"
check_rc "empreinte fausse" 1 rago_pl_hash_ok "$tmp/f" "sha256:$(printf '0%.0s' {1..64})"
check_rc "empreinte PENDING" 2 rago_pl_hash_ok "$tmp/f" PENDING
check_rc "empreinte algo inconnu" 2 rago_pl_hash_ok "$tmp/f" md5:abc

cat > "$tmp/compat.vdf" <<'EOF'
"compatibilitytools"
{
  "compat_tools"
  {
    "GE-Proton10-30" // Internal name of this tool
    {
      // Can register this tool with Steam in two ways:
      "install_path" "."
      "display_name" "GE-Proton10-30"
      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
EOF
check "nom d'outil Steam" GE-Proton10-30 "$(rago_pl_compat_tool_name "$tmp/compat.vdf")"
printf '"compatibilitytools" { "compat_tools" { Rago_Tool { "install_path" "." } } }\n' > "$tmp/c2.vdf"
check "nom d'outil (sans guillemets, une ligne)" Rago_Tool "$(rago_pl_compat_tool_name "$tmp/c2.vdf")"

# --- session gamescope -----------------------------------------------------------------------
args=$(rago_pl_gamescope_args | tr '\n' ' ')
check "gamescope : défauts" "-e --xwayland-count 2 --adaptive-sync --hdr-enabled --immediate-flips --rt --mangoapp -- steam -gamepadui " "$args"
args=$(RAGO_SESSION_VRR=0 RAGO_SESSION_HDR=0 RAGO_SESSION_TEARING=0 RAGO_SESSION_RT=0 RAGO_SESSION_MANGOAPP=0 rago_pl_gamescope_args | tr '\n' ' ')
check "gamescope : tout coupé" "-e --xwayland-count 2 -- steam -gamepadui " "$args"
args=$(RAGO_SESSION_WIDTH=2560 RAGO_SESSION_HEIGHT=1440 RAGO_SESSION_REFRESH=165 RAGO_SESSION_HDR_ITM=1 \
	RAGO_SESSION_OUTPUT=DP-1,HDMI-A-1 RAGO_SESSION_VK_DEVICE=1002:744c RAGO_SESSION_BACKEND=headless \
	RAGO_SESSION_NESTED=1 RAGO_SESSION_EXTRA_ARGS="--force-grab-cursor -S fit" RAGO_SESSION_STEAM_CMD="/opt/faux-steam -gamepadui -x" \
	rago_pl_gamescope_args | tr '\n' ' ')
check "gamescope : tout réglé" "-e --xwayland-count 2 -W 2560 -H 1440 -r 165 --adaptive-sync --hdr-enabled --hdr-itm-enabled --immediate-flips --rt --mangoapp -O DP-1,HDMI-A-1 --prefer-vk-device 1002:744c --backend headless -f --force-grab-cursor -S fit -- /opt/faux-steam -gamepadui -x " "$args"
args=$(RAGO_SESSION_HDR=0 RAGO_SESSION_HDR_ITM=1 rago_pl_gamescope_args | grep -c hdr)
check "gamescope : ITM sans HDR ignoré" 0 "$args"
envs=$(rago_pl_session_env)
for v in RAGO_SESSION=1 STEAM_GAMESCOPE_VRR_SUPPORTED=1 STEAM_GAMESCOPE_HDR_SUPPORTED=1 DXVK_HDR=1 \
	STEAM_GAMESCOPE_TEARING_SUPPORTED=1 STEAM_USE_MANGOAPP=1 RAGO_SESSION_MANGOAPP=1 STEAM_MULTIPLE_XWAYLANDS=1; do
	check "env session : $v" 1 "$(printf '%s\n' "$envs" | grep -cx "$v")"
done
envs=$(RAGO_SESSION_VRR=0 RAGO_SESSION_HDR=0 RAGO_SESSION_TEARING=0 RAGO_SESSION_MANGOAPP=0 rago_pl_session_env)
check "env session : capacités coupées" 0 "$(printf '%s\n' "$envs" | grep -cE 'VRR|HDR|TEARING|MANGOAPP')"

printf '%d tests OK, %d échec(s)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
