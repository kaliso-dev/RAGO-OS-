#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests de host/setup_proton_layer.sh dans une fausse racine (module M2).
# Sans root obligatoire, sans réseau, sans matériel : fausse archive Proton-GE
# (au format des vraies), sources.lock de test, fichiers existants à sauvegarder.
# Usage : host/tests/test_proton_sysroot.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
setup="$here/../setup_proton_layer.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

check() {
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); printf 'ÉCHEC %s\n  attendu : %s\n  obtenu  : %s\n' "$1" "$2" "$3"
	fi
}
yes_() { if "$@"; then echo oui; else echo non; fi; }

# --- fausse archive Proton-GE + sources.lock de test ------------------------------------------
GE="GE-Proton10-99"
mk_ge() { # mk_ge <dossier de sortie>
	local w="$tmp/ge-src"
	rm -rf "$w"; mkdir -p "$w/$GE/files/bin"
	cat > "$w/$GE/compatibilitytool.vdf" <<-EOF
	"compatibilitytools"
	{
	  "compat_tools"
	  {
	    "$GE" // Internal name of this tool
	    {
	      "install_path" "."
	      "display_name" "$GE"
	      "from_oslist"  "windows"
	      "to_oslist"    "linux"
	    }
	  }
	}
	EOF
	printf '"manifest"\n{\n  "version" "2"\n  "commandline" "/proton %%verb%%"\n  "require_tool_appid" "1628350"\n}\n' > "$w/$GE/toolmanifest.vdf"
	printf '#!/usr/bin/env python3\n' > "$w/$GE/proton"; chmod 0777 "$w/$GE/proton"
	echo wine > "$w/$GE/files/bin/wine"
	tar -czf "$1" -C "$w" "$GE"
}
mk_ge "$tmp/$GE.tar.gz"
sha=$(sha512sum "$tmp/$GE.tar.gz" | cut -d' ' -f1)
LOCKF="$tmp/sources.lock"
cat > "$LOCKF" <<EOF
# lock de test
proton-ge $GE https://example.invalid/$GE.tar.gz sha512:$sha
heroic-pacman PENDING PENDING PENDING
heroic-deb PENDING PENDING PENDING
EOF
export RAGO_PROTON_LOCK="$LOCKF"

R="$tmp/root"
mkdir -p "$R/etc/pacman.d" "$R/usr/share/steam/compatibilitytools.d"
printf '[general]\nrenice=10\n' > "$R/etc/gamemode.ini"          # fichier du joueur à sauvegarder
printf 'fps\nfull\n' > "$R/etc/MangoHud.conf"
S() { bash "$setup" --root "$R" "$@"; }

# --- install -----------------------------------------------------------------------------------
out=$(S install --proton-ge-file "$tmp/$GE.tar.gz" 2>&1); rc=$?
check "install : code" 0 "$rc"
for p in /usr/bin/rago-launch /usr/bin/rago-shader-cache /usr/bin/rago-steam-config /usr/bin/rago-session \
	/usr/lib/rago/rago_proton_lib.sh /usr/lib/systemd/user/rago-shader-prewarm.service /etc/gamemode.ini \
	/etc/polkit-1/rules.d/40-rago-gamemode.rules /etc/MangoHud.conf /usr/share/wayland-sessions/rago.desktop \
	/etc/pacman.d/hooks/rago-gamescope-cap.hook; do
	check "install : $p à nous" oui "$(yes_ grep -qs rago-proton-layer "$R$p")"
done
check "install : rago-launch exécutable" 755 "$(stat -c %a "$R/usr/bin/rago-launch")"
check "install : lib non exécutable" 644 "$(stat -c %a "$R/usr/lib/rago/rago_proton_lib.sh")"
check "install : gamemode.ini du joueur sauvegardé" "$(printf '[general]\nrenice=10')" "$(cat "$R/var/lib/rago/proton-layer/backup/etc%gamemode.ini")"
check "install : MangoHud.conf du joueur sauvegardé" "$(printf 'fps\nfull')" "$(cat "$R/var/lib/rago/proton-layer/backup/etc%MangoHud.conf")"
G="$R/usr/share/steam/compatibilitytools.d/$GE"
check "Proton-GE : extrait" oui "$(yes_ test -f "$G/compatibilitytool.vdf")"
check "Proton-GE : marque Rago" "sha=sha512:$sha" "$(grep '^sha=' "$G/.rago-proton-layer")"
check "Proton-GE : pas de fichier modifiable par tous" 0 "$(find "$G" -perm -o+w -type f | wc -l)"
check "Proton-GE : nom mémorisé" "$GE" "$(bash -c ". '$here/../lib/rago_proton_lib.sh'; rago_pl_conf_get '$R/etc/rago/proton-layer.conf' RAGO_PROTON_GE_NAME")"
check "Proton-GE : pas de dossier temporaire laissé" 0 "$(find "$R/usr/share/steam/compatibilitytools.d" -maxdepth 1 -name '.rago-tmp*' | wc -l)"
check "install : Heroic PENDING signalé" oui "$(yes_ grep -q 'Heroic' <<< "$out")"
check "conf : défauts écrits" "RAGO_SHADER_PREWARM=\"background\"" "$(grep '^RAGO_SHADER_PREWARM=' "$R/etc/rago/proton-layer.conf")"

# --- idempotence ---------------------------------------------------------------------------
sum1=$(find "$R" -type f -not -path '*/var/lib/*' -exec md5sum {} + | sort | md5sum)
out=$(S install --proton-ge-file "$tmp/$GE.tar.gz" 2>&1); rc=$?
sum2=$(find "$R" -type f -not -path '*/var/lib/*' -exec md5sum {} + | sort | md5sum)
check "réinstall : code" 0 "$rc"
check "réinstall : rien ne change" "$sum1" "$sum2"
check "réinstall : Proton-GE déjà là" oui "$(yes_ grep -q 'déjà installé' <<< "$out")"
check "réinstall : sauvegarde intacte" "$(printf '[general]\nrenice=10')" "$(cat "$R/var/lib/rago/proton-layer/backup/etc%gamemode.ini")"

# --- verify (fichiers) ---------------------------------------------------------------------
out=$(S verify 2>&1); rc=$?
check "verify : code" 0 "$rc"
check "verify : 0 échec" oui "$(yes_ grep -q ' 0 échec' <<< "$out")"
sed -i 's/^pin_cores=no/pin_cores=yes/' "$R/etc/gamemode.ini"
out=$(S verify 2>&1); rc=$?
check "verify : pin_cores=yes détecté" 1 "$rc"
check "verify : message pin_cores" oui "$(yes_ grep -q 'pin_cores ≠ no' <<< "$out")"
S install --proton-ge-file "$tmp/$GE.tar.gz" >/dev/null 2>&1
check "install : remet gamemode.ini" "pin_cores=no" "$(grep '^pin_cores' "$R/etc/gamemode.ini")"

# --- options mémorisées / refusées ---------------------------------------------------------
S install --no-session --shader-prewarm before --shader-cache-size 2G >/dev/null 2>&1
check "--no-session : session retirée" non "$(yes_ test -e "$R/usr/bin/rago-session")"
check "--no-session : entrée retirée" non "$(yes_ test -e "$R/usr/share/wayland-sessions/rago.desktop")"
check "--no-session : hook pacman retiré" non "$(yes_ test -e "$R/etc/pacman.d/hooks/rago-gamescope-cap.hook")"
S install >/dev/null 2>&1
check "options mémorisées" 'RAGO_INSTALL_SESSION="0"' "$(grep '^RAGO_INSTALL_SESSION=' "$R/etc/rago/proton-layer.conf")"
check "options mémorisées (prewarm)" 'RAGO_SHADER_PREWARM="before"' "$(grep '^RAGO_SHADER_PREWARM=' "$R/etc/rago/proton-layer.conf")"
before=$(cat "$R/etc/rago/proton-layer.conf")
for bad in "--shader-prewarm souvent" "--default-proton steam" "--shader-cache-size 4T" "--shader-cache-root relatif/x"; do
	# shellcheck disable=SC2086
	S install $bad >/dev/null 2>&1; rc=$?
	check "refus : $bad" 1 "$rc"
done
check "refus : conf intacte" "$before" "$(cat "$R/etc/rago/proton-layer.conf")"
S install --no-session >/dev/null 2>&1
S install >/dev/null 2>&1   # garde --no-session
bash "$setup" --root "$R" install --dry-run >/dev/null 2>&1
check "--dry-run : session pas réinstallée" non "$(yes_ test -e "$R/usr/bin/rago-session")"
# shellcheck disable=SC2034
S install --shader-prewarm background >/dev/null 2>&1
R_SES=$(S install 2>&1 >/dev/null; grep '^RAGO_INSTALL_SESSION=' "$R/etc/rago/proton-layer.conf")
check "session toujours coupée" 'RAGO_INSTALL_SESSION="0"' "$R_SES"

# --- empreinte fausse, PENDING, Proton-GE posé à la main ---------------------------------
R2="$tmp/root2"; mkdir -p "$R2"
mk_ge "$tmp/autre.tar.gz"
echo "en plus" >> "$tmp/autre.tar.gz"
out=$(bash "$setup" --root "$R2" install --proton-ge-file "$tmp/autre.tar.gz" 2>&1); rc=$?
check "empreinte fausse : refus" 1 "$rc"
check "empreinte fausse : message" oui "$(yes_ grep -q 'empreinte différente' <<< "$out")"
check "empreinte fausse : rien extrait" non "$(yes_ test -e "$R2/usr/share/steam/compatibilitytools.d/$GE")"
R3="$tmp/root3"; mkdir -p "$R3"
sed "s|^proton-ge .*|proton-ge PENDING PENDING PENDING|" "$LOCKF" > "$tmp/pending.lock"
out=$(RAGO_PROTON_LOCK="$tmp/pending.lock" bash "$setup" --root "$R3" install 2>&1); rc=$?
check "PENDING : install continue" 0 "$rc"
check "PENDING : avertissement" oui "$(yes_ grep -q 'pas encore épinglé' <<< "$out")"
check "PENDING : hook installé quand même" oui "$(yes_ test -x "$R3/usr/bin/rago-launch")"
R4="$tmp/root4"; mkdir -p "$R4/usr/share/steam/compatibilitytools.d/$GE"
echo "à la main" > "$R4/usr/share/steam/compatibilitytools.d/$GE/proton"
out=$(bash "$setup" --root "$R4" install --proton-ge-file "$tmp/$GE.tar.gz" 2>&1)
check "GE à la main : laissé" "à la main" "$(cat "$R4/usr/share/steam/compatibilitytools.d/$GE/proton")"
check "GE à la main : signalé" oui "$(yes_ grep -q 'sans marque Rago' <<< "$out")"

# --- dry-run sur une racine vide ---------------------------------------------------------------
R5="$tmp/root5"; mkdir -p "$R5"
bash "$setup" --root "$R5" --dry-run install --proton-ge-file "$tmp/$GE.tar.gz" >/dev/null 2>&1
check "--dry-run : rien écrit" 0 "$(find "$R5" -mindepth 1 | wc -l)"

# --- uninstall ---------------------------------------------------------------------------------
S install --proton-ge-file "$tmp/$GE.tar.gz" >/dev/null 2>&1
bash "$setup" --root "$R4" uninstall >/dev/null 2>&1
check "uninstall : GE posé à la main gardé" oui "$(yes_ test -e "$R4/usr/share/steam/compatibilitytools.d/$GE/proton")"
out=$(S uninstall 2>&1); rc=$?
check "uninstall : code" 0 "$rc"
check "uninstall : gamemode.ini du joueur remis" "$(printf '[general]\nrenice=10')" "$(cat "$R/etc/gamemode.ini")"
check "uninstall : MangoHud.conf du joueur remis" "$(printf 'fps\nfull')" "$(cat "$R/etc/MangoHud.conf")"
check "uninstall : Proton-GE retiré" non "$(yes_ test -e "$G")"
left=$(find "$R" -type f | sed "s|^$R||" | sort | tr '\n' ' ')
check "uninstall : il ne reste que les fichiers d'avant" "/etc/MangoHud.conf /etc/gamemode.ini " "$left"
out=$(S uninstall 2>&1)
check "uninstall deux fois : rien à faire" oui "$(yes_ grep -q 'rien à désinstaller' <<< "$out")"

# --- côté joueur : user (Steam factice) -------------------------------------------------------
H="$tmp/home"
mkdir -p "$H/.local/share/Steam/steamapps" "$H/.local/share/Steam/userdata/42/config" "$H/.local/share/Steam/config"
printf '"AppState"\n{\n\t"appid"\t\t"620"\n\t"name"\t\t"Portal 2"\n}\n' > "$H/.local/share/Steam/steamapps/appmanifest_620.acf"
printf '"UserLocalConfigStore"\n{\n}\n' > "$H/.local/share/Steam/userdata/42/config/localconfig.vdf"
out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" RAGO_ALLOW_ROOT_USER=1 bash "$setup" user 2>&1); rc=$?
check "user : code" 0 "$rc"
check "user : jeu branché" oui "$(yes_ grep -q '"LaunchOptions"[[:space:]]*"rago-launch %command%"' "$H/.local/share/Steam/userdata/42/config/localconfig.vdf")"
mkdir -p "$H/.config"; printf '[cpu]\npin_cores=yes\n' > "$H/.config/gamemode.ini"
out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" RAGO_ALLOW_ROOT_USER=1 bash "$setup" user 2>&1)
check "user : gamemode.ini du joueur signalé" oui "$(yes_ grep -q 'pin_cores=yes' <<< "$out")"
HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" RAGO_ALLOW_ROOT_USER=1 bash "$setup" user --remove >/dev/null 2>&1
check "user --remove : hook retiré" non "$(yes_ grep -q 'rago-launch' "$H/.local/share/Steam/userdata/42/config/localconfig.vdf")"

printf '%d tests OK, %d échec(s)\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
