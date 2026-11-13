#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — build reproductible du noyau Rago (module M0).
#
#   sources épinglées (sha256) + patchset CachyOS + config Rago
#   -> Clang/ThinLTO -> paquet -> installation -> signature Secure Boot (MOK)
#   -> entrée systemd-boot ; plus l'ordonnanceur scx_rago et son service.
#
# Usage : build_rago_kernel.sh [options] <étape>...
#
# Étapes sans root (dans kernel/build/, résultats dans kernel/out/) :
#   deps          vérifie les outils nécessaires
#   lock          épingle les sources (premier téléchargement, mainteneur)
#   fetch         télécharge et vérifie les sources (sha256 de sources.lock)
#   prepare       extrait l'arbre et applique les patchs
#   config        config de base + localmodconfig + fragments Rago + x86-64-vN
#   verify        vérifie que chaque option de rago-gaming.config a « pris »
#   build         compile (LLVM=1, ThinLTO)
#   package       paquet pacman (Arch) ou tarball, plus manifeste sha256
#   scx           compile scx_rago et rago-sched-hint (cargo, clang >= 20)
#   all           fetch prepare config verify build package scx
#
# Étapes root (machine cible) :
#   mok-gen       crée la clé MOK (openssl) dans /etc/rago/secureboot
#   mok-enroll    demande l'inscription de la clé au prochain boot (mokutil)
#   install       installe le paquet noyau, puis sign + bootloader
#   sign          signe le noyau installé (sbsign) et vérifie (sbverify)
#   bootloader    signe systemd-boot (+ shim si présent), écrit l'entrée
#   scx-install   installe scx_rago, rago-sched-hint, le service, le groupe
#   secureboot-status  état Secure Boot / MOK (mokutil)
#
# Options :
#   --x86-level auto|3|4   niveau x86-64 (défaut auto : v4 si détecté, sinon v3)
#   --no-localmodconfig    noyau générique (ISO, M13) : pas de localmodconfig
#   --lsmod FICHIER        liste de modules pour localmodconfig (défaut : lsmod)
#   --base-config FICHIER  config de base (défaut : config CachyOS épinglée)
#   --jobs N               parallélisme (défaut : nproc)
#   --user NOM             (scx-install) utilisateur à ajouter au groupe rago
#   --patches-ref SHA      (lock) commit CachyOS/kernel-patches
#   --config-ref SHA       (lock) commit CachyOS/linux-cachyos
#   --dry-run              (étapes root) affiche les actions sans les faire
#   -h, --help
#
# Configuration machine : /etc/rago/kernel.conf (voir write_default_conf) :
#   RAGO_MITIGATIONS=auto|off   « off » ajoute mitigations=off au démarrage
#   RAGO_CMDLINE="root=..."      base de la ligne de commande
#   RAGO_ESP=/boot               montage de l'ESP (systemd-boot)
#
# Aucun contournement d'anti-triche : le noyau est signé avec la clé du
# propriétaire de la machine, inscrite par lui dans le MOK, Secure Boot actif.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
# shellcheck source-path=SCRIPTDIR source=lib/rago_kernel_lib.sh
. "$here/lib/rago_kernel_lib.sh"

LOCK="$here/patches/sources.lock"
LOCAL_PATCHES="$here/patches/local"
FRAG_GAMING="$here/config/rago-gaming.config"
FRAG_KEEP="$here/config/rago-keep.config"
BUILD="${RAGO_BUILD_DIR:-$here/build}"
OUT="${RAGO_OUT_DIR:-$here/out}"
DL="$BUILD/downloads"
CONF_FILE="${RAGO_KERNEL_CONF:-/etc/rago/kernel.conf}"
MOK_DIR="${RAGO_MOK_DIR:-/etc/rago/secureboot}"
PKGBASE=linux-rago
LOCALVERSION=-rago

x86_level=auto
localmod=1
lsmod_file=""
base_config=""
jobs=$(nproc 2>/dev/null || echo 4)
target_user="${SUDO_USER:-}"
patches_ref=""
config_ref=""
dry_run=0

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }

# Commande root : exécutée, ou seulement affichée avec --dry-run.
run() {
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] %s\n' "$*"
	else
		"$@"
	fi
}

need_root() { [ "$(id -u)" -eq 0 ] || [ "$dry_run" = 1 ] || die "l'étape « $1 » doit être lancée en root (sudo)"; }
# RAGO_ALLOW_ROOT_BUILD=1 : conteneur de CI jetable où tout tourne en root.
not_root()  { [ "$(id -u)" -ne 0 ] || [ "${RAGO_ALLOW_ROOT_BUILD:-0}" = 1 ] || die "l'étape « $1 » ne doit pas tourner en root (compilation non privilégiée)"; }

# --- Variables de reproductibilité ----------------------------------------------
kernel_version() { rago_lock_var "$LOCK" KERNEL_VERSION; }
srcdir() { echo "$BUILD/linux-$(kernel_version)"; }

# Date figée : date du dernier commit du dépôt Rago (identique pour tous ceux
# qui construisent le même commit), à défaut celle du fichier de verrou.
source_date_epoch() {
	if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then echo "$SOURCE_DATE_EPOCH"; return; fi
	git -C "$repo" log -1 --format=%ct 2>/dev/null || stat -c %Y "$LOCK"
}

# Chaîne LLVM pour make : LLVM=1 si « clang » est un Clang récent, sinon
# suffixe de version (LLVM=-20).
llvm_flag() {
	local v
	if command -v clang >/dev/null; then
		v=$(clang -dumpversion | cut -d. -f1)
		if [ "$v" -ge 17 ]; then echo "LLVM=1"; return; fi
	fi
	for v in 21 20 19 18 17; do
		if command -v "clang-$v" >/dev/null && command -v "ld.lld-$v" >/dev/null; then
			echo "LLVM=-$v"; return
		fi
	done
	die "Clang >= 17 et ld.lld introuvables (paquets clang, lld, llvm)"
}

kmake() {
	local epoch
	epoch=$(source_date_epoch)
	env SOURCE_DATE_EPOCH="$epoch" \
	    KBUILD_BUILD_TIMESTAMP="@$epoch" \
	    KBUILD_BUILD_USER=rago \
	    KBUILD_BUILD_HOST=rago-build \
	    KBUILD_BUILD_VERSION=1 \
	    LC_ALL=C TZ=UTC \
	    make -C "$(srcdir)" "$(llvm_flag)" LOCALVERSION="$LOCALVERSION" \
	         ${RAGO_KCFLAGS:+KCFLAGS="$RAGO_KCFLAGS"} "$@"
}

# --- deps -------------------------------------------------------------------------
step_deps() {
	local missing="" t
	for t in curl sha256sum tar xz patch make bc flex bison perl pahole openssl cpio zstd; do
		command -v "$t" >/dev/null || missing="$missing $t"
	done
	llvm_flag >/dev/null
	[ -n "$missing" ] && die "outils manquants :$missing"
	log "outils OK ($(llvm_flag))"
}

# --- lock -----------------------------------------------------------------------
step_lock() {
	not_root lock
	if [ -z "$patches_ref" ] || [ -z "$config_ref" ]; then
		die "lock exige --patches-ref et --config-ref"
	fi
	case "$patches_ref$config_ref" in *[!0-9a-f]*) die "les refs doivent être des sha de commit (hex)" ;; esac
	mkdir -p "$DL"
	local tmp name url sum
	tmp=$(mktemp)
	sed -e "s/@PATCHES_REF@/$patches_ref/g" -e "s/@CONFIG_REF@/$config_ref/g" "$LOCK" > "$tmp"
	cp "$tmp" "$tmp.new"
	while read -r name url sum; do
		log "téléchargement de $name"
		curl -fL --retry 3 -o "$DL/$name" "$url"
		sum=$(sha256sum "$DL/$name" | cut -d' ' -f1)
		# Remplace « name url <ancien> » par « name url <sha256> ».
		awk -v n="$name" -v s="$sum" '$1 == n && NF == 3 { $3 = s } { print }' "$tmp.new" > "$tmp.new2"
		mv "$tmp.new2" "$tmp.new"
	done < <(rago_series_entries "$tmp")
	mv "$tmp.new" "$LOCK"
	rm -f "$tmp"
	log "sources.lock mis à jour : relire le diff, puis committer"
}

# --- fetch ------------------------------------------------------------------------
step_fetch() {
	not_root fetch
	mkdir -p "$DL"
	local name url sum got
	grep -q '@PATCHES_REF@\|@CONFIG_REF@' "$LOCK" && die "sources.lock non épinglé : lancer « lock » (voir kernel/patches/README.md)"
	while read -r name url sum; do
		rago_is_sha256 "$sum" || die "$name : sha256 absent (« $sum ») dans sources.lock"
		if [ ! -f "$DL/$name" ] || [ "$(sha256sum "$DL/$name" | cut -d' ' -f1)" != "$sum" ]; then
			log "téléchargement de $name"
			curl -fL --retry 3 -o "$DL/$name.part" "$url"
			mv "$DL/$name.part" "$DL/$name"
		fi
		got=$(sha256sum "$DL/$name" | cut -d' ' -f1)
		[ "$got" = "$sum" ] || die "$name : sha256 $got différent de l'épinglé $sum"
		log "$name vérifié"
	done < <(rago_series_entries "$LOCK")
}

# --- prepare ----------------------------------------------------------------------
step_prepare() {
	not_root prepare
	local v src name url sum p
	v=$(kernel_version)
	src=$(srcdir)
	rm -rf "$src"
	log "extraction de linux-$v"
	tar -C "$BUILD" -xf "$DL/linux-$v.tar.xz"
	while read -r name url sum; do
		case "$name" in
		*.patch)
			log "patch $name"
			patch -d "$src" -p1 --forward --no-backup-if-mismatch -s < "$DL/$name"
			;;
		esac
	done < <(rago_series_entries "$LOCK")
	if [ -d "$LOCAL_PATCHES" ]; then
		for p in "$LOCAL_PATCHES"/*.patch; do
			[ -e "$p" ] || continue
			log "patch local $(basename "$p")"
			patch -d "$src" -p1 --forward --no-backup-if-mismatch -s < "$p"
		done
	fi
	# Pas de suffixe « + » ni de hash git dans la version (reproductibilité).
	touch "$src/.scmversion"
}

# --- clé de signature des modules -------------------------------------------------
# Les modules du noyau sont signés par une clé de build persistante (gardée
# hors dépôt dans kernel/build/keys/, jamais committée) dont le certificat est
# intégré au noyau. La clé MOK (root, /etc/rago/secureboot) signe les binaires
# EFI et les modules DKMS ; le build reste ainsi non privilégié et
# reproductible sur une même machine.
module_key() {
	local d="$BUILD/keys" k="$BUILD/keys/module-signing.pem"
	if [ ! -f "$k" ]; then
		mkdir -p "$d"; chmod 0700 "$d"
		log "création de la clé de signature des modules (hors dépôt)"
		( umask 077
		  openssl req -new -x509 -newkey rsa:4096 -sha512 -nodes -days 36500 \
			-subj "/CN=Rago OS kernel module signing key/" \
			-addext "basicConstraints=critical,CA:FALSE" \
			-addext "keyUsage=digitalSignature" \
			-addext "extendedKeyUsage=1.3.6.1.4.1.2312.16.1.2" \
			-keyout "$d/key.tmp" -out "$d/crt.tmp" 2>/dev/null
		  cat "$d/key.tmp" "$d/crt.tmp" > "$k"
		  rm -f "$d/key.tmp" "$d/crt.tmp" )
	fi
	echo "$k"
}

# --- config -----------------------------------------------------------------------
step_config() {
	not_root config
	local src base detected level key
	src=$(srcdir)
	[ -f "$src/Makefile" ] || die "arbre absent : lancer « prepare »"
	base=${base_config:-$DL/config-cachyos}
	[ -f "$base" ] || die "config de base introuvable : $base"
	log "config de base : $base"
	cp "$base" "$src/.config"
	kmake olddefconfig >/dev/null

	if [ "$localmod" = 1 ]; then
		local lsm=$lsmod_file
		if [ -z "$lsm" ]; then
			lsm="$BUILD/lsmod.txt"
			lsmod > "$lsm"
		fi
		log "localmodconfig ($(($(wc -l < "$lsm") - 1)) modules chargés) + fragment de conservation"
		# La config de base vient de passer olddefconfig : aucune question attendue.
		kmake LSMOD="$lsm" localmodconfig < /dev/null > "$BUILD/localmodconfig.log" 2>&1 ||
			die "localmodconfig a échoué (voir $BUILD/localmodconfig.log)"
	else
		log "noyau générique : pas de localmodconfig"
	fi

	# Fusion des fragments (la dernière valeur l'emporte).
	(cd "$src" && KCONFIG_CONFIG=.config ./scripts/kconfig/merge_config.sh -m .config "$FRAG_KEEP" "$FRAG_GAMING" >/dev/null)

	# Niveau x86-64.
	detected=$(rago_detect_x86_level /proc/cpuinfo)
	if [ "$localmod" = 0 ] && [ "$x86_level" = auto ]; then
		level=3   # noyau générique : v3 (le minimum Rago), jamais v4
	else
		level=$(rago_choose_x86_level "$detected" "$x86_level") ||
			die "CPU x86-64-v$detected : Rago exige au moins x86-64-v3 (niveau demandé : $x86_level)"
	fi
	log "x86-64-v$level (détecté : v$detected)"
	if grep -q '^config X86_64_VERSION' "$src/arch/x86/Kconfig.cpu" 2>/dev/null; then
		"$src/scripts/config" --file "$src/.config" --enable GENERIC_CPU --set-val X86_64_VERSION "$level"
		RAGO_KCFLAGS=""
	else
		warn "CONFIG_X86_64_VERSION absent (patchset CachyOS non appliqué ?) : -march=x86-64-v$level via KCFLAGS"
		RAGO_KCFLAGS="-march=x86-64-v$level"
	fi
	echo "$RAGO_KCFLAGS" > "$BUILD/kcflags"

	key=$(module_key)
	# Une config de distribution peut pointer vers ses propres fichiers de
	# certificats (ex. debian/canonical-*.pem) : on les vide.
	"$src/scripts/config" --file "$src/.config" \
		--set-str MODULE_SIG_KEY "$key" \
		--set-str LOCALVERSION "" \
		--disable LOCALVERSION_AUTO \
		--set-str SYSTEM_TRUSTED_KEYS "" \
		--set-str SYSTEM_REVOCATION_KEYS ""
	kmake olddefconfig >/dev/null
	cp "$src/.config" "$OUT_CONFIG"
	log "config écrite (copie : $OUT_CONFIG)"
}

# --- verify -----------------------------------------------------------------------
step_verify() {
	local src rc=0 out
	src=$(srcdir)
	[ -f "$src/.config" ] || die "pas de .config : lancer « config »"
	log "vérification de rago-gaming.config"
	if ! out=$(rago_cfg_verify "$src/.config" "$FRAG_GAMING"); then rc=1; fi
	[ -n "$out" ] && printf '%s\n' "$out"
	log "vérification de rago-keep.config (signalé seulement)"
	rago_cfg_verify "$src/.config" "$FRAG_KEEP" | sed 's/^MISSING/NOTE/' || true
	if [ "$(rago_cfg_get "$src/.config" X86_64_VERSION)" = n ] && [ ! -s "$BUILD/kcflags" ]; then
		echo "MISSING X86_64_VERSION (ni config ni KCFLAGS)"; rc=1
	fi
	[ "$rc" = 0 ] || die "des options obligatoires n'ont pas pris (voir ci-dessus)"
	log "config conforme"
}

# --- build ------------------------------------------------------------------------
step_build() {
	not_root build
	RAGO_KCFLAGS=$(cat "$BUILD/kcflags" 2>/dev/null || true)
	log "compilation ($(llvm_flag), ThinLTO, $jobs tâches)"
	kmake -j"$jobs" all
	log "noyau : $(kmake -s kernelrelease)"
}

# --- package ----------------------------------------------------------------------
step_package() {
	not_root package
	local rel f
	RAGO_KCFLAGS=$(cat "$BUILD/kcflags" 2>/dev/null || true)
	rel=$(kmake -s kernelrelease)
	mkdir -p "$OUT"
	rm -f "$OUT"/*.pkg.tar.* "$OUT"/linux-*.tar*
	if command -v makepkg >/dev/null; then
		log "paquet pacman $PKGBASE"
		kmake -j"$jobs" PACMAN_PKGBASE="$PKGBASE" PACMAN_EXTRAPACKAGES="headers" pacman-pkg
		find "$(srcdir)" -maxdepth 3 -name "$PKGBASE*.pkg.tar.*" -newer "$(srcdir)/.config" -exec mv {} "$OUT/" \;
	else
		log "makepkg absent : tarball (make tar-pkg)"
		kmake -j"$jobs" tar-pkg
		find "$(srcdir)" -maxdepth 1 -name "linux-*.tar" -newer "$(srcdir)/.config" -exec mv {} "$OUT/" \;
	fi
	{
		echo "# Rago OS — manifeste du build noyau"
		echo "kernelrelease=$rel"
		echo "source_date_epoch=$(source_date_epoch)"
		echo "rago_commit=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo inconnu)"
		echo "llvm=$(llvm_flag)"
		echo "kcflags=${RAGO_KCFLAGS:-}"
		echo "localmodconfig=$localmod"
		echo "x86_64_version=$(rago_cfg_get "$(srcdir)/.config" X86_64_VERSION)"
		echo "# sha256"
		(cd "$here" && sha256sum patches/sources.lock config/rago-gaming.config config/rago-keep.config)
		sha256sum "$(srcdir)/.config" | sed "s|$(srcdir)/||"
		(cd "$OUT" && for f in *.pkg.tar.* linux-*.tar; do [ -e "$f" ] && sha256sum "$f"; done)
		sha256sum "$(srcdir)/arch/x86/boot/bzImage" | sed "s|$(srcdir)/||"
	} > "$OUT/manifest.txt"
	log "paquet et manifeste dans $OUT"
	ls -1 "$OUT"
}

# --- scx (compilation) ---------------------------------------------------------------
bpf_clang() {
	local c v
	for c in clang clang-21 clang-20; do
		command -v "$c" >/dev/null || continue
		v=$("$c" -dumpversion | cut -d. -f1)
		[ "$v" -ge 20 ] && { echo "$c"; return; }
	done
	die "scx_rago exige Clang >= 20 pour le BPF (clang 18 produit un code d'arène refusé par le vérifieur)"
}

step_scx() {
	not_root scx
	command -v cargo >/dev/null || die "cargo absent (rustup / paquet rust)"
	log "compilation de scx_rago et rago-sched-hint (BPF_CLANG=$(bpf_clang))"
	(cd "$repo" && BPF_CLANG=$(bpf_clang) cargo build --release --locked -p scx_rago -p rago-sched-hint)
	mkdir -p "$OUT/bin"
	cp "$repo/target/release/scx_rago" "$repo/target/release/rago-sched-hint" "$OUT/bin/"
	log "binaires dans $OUT/bin"
}

# --- MOK ---------------------------------------------------------------------------------
step_mok_gen() {
	need_root mok-gen
	if [ -f "$MOK_DIR/MOK.key" ]; then
		log "clé MOK déjà présente ($MOK_DIR) : rien à faire"
		return
	fi
	log "création de la clé MOK dans $MOK_DIR (RSA 2048, 10 ans)"
	run install -d -m 0700 "$MOK_DIR"
	local cnf
	cnf=$(mktemp)
	cat > "$cnf" <<-EOF
	[ req ]
	distinguished_name = dn
	prompt = no
	x509_extensions = v3
	[ dn ]
	CN = Rago OS Secure Boot MOK ($(hostname 2>/dev/null || echo machine))
	[ v3 ]
	basicConstraints = critical,CA:FALSE
	keyUsage = digitalSignature
	extendedKeyUsage = codeSigning,1.3.6.1.4.1.2312.16.1.2
	subjectKeyIdentifier = hash
	authorityKeyIdentifier = keyid
	EOF
	# RSA 2048 : taille la plus compatible avec les firmwares UEFI et shim.
	run sh -c "umask 077 && openssl req -new -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
		-config '$cnf' -keyout '$MOK_DIR/MOK.key' -out '$MOK_DIR/MOK.crt' 2>/dev/null"
	run openssl x509 -in "$MOK_DIR/MOK.crt" -outform DER -out "$MOK_DIR/MOK.cer"
	run chmod 0600 "$MOK_DIR/MOK.key"
	run chmod 0644 "$MOK_DIR/MOK.crt" "$MOK_DIR/MOK.cer"
	rm -f "$cnf"
	log "clé créée. Étape suivante : « mok-enroll » puis redémarrage."
}

step_mok_enroll() {
	need_root mok-enroll
	command -v mokutil >/dev/null || die "mokutil absent"
	[ -f "$MOK_DIR/MOK.cer" ] || [ "$dry_run" = 1 ] || die "pas de clé : lancer « mok-gen »"
	if [ "$dry_run" = 0 ] && mokutil --test-key "$MOK_DIR/MOK.cer" 2>&1 | grep -q "already enrolled"; then
		log "clé MOK déjà inscrite"
		return
	fi
	log "demande d'inscription : choisir un mot de passe à usage unique,"
	log "puis au redémarrage, dans MokManager : Enroll MOK > Continue > Yes > mot de passe."
	run mokutil --import "$MOK_DIR/MOK.cer"
	run mokutil --list-new
}

step_secureboot_status() {
	if command -v mokutil >/dev/null; then
		mokutil --sb-state || true
		if [ -f "$MOK_DIR/MOK.cer" ]; then
			mokutil --test-key "$MOK_DIR/MOK.cer" || true
		fi
	else
		warn "mokutil absent"
	fi
}

# --- configuration machine ------------------------------------------------------------
write_default_conf() {
	[ -f "$CONF_FILE" ] && return
	local base
	base=$(rago_cmdline_base "$(cat /proc/cmdline)")
	log "création de $CONF_FILE"
	run install -d -m 0755 "$(dirname "$CONF_FILE")"
	if [ "$dry_run" = 1 ]; then
		printf '[dry-run] écrire %s (RAGO_CMDLINE="%s")\n' "$CONF_FILE" "$base"
		return
	fi
	cat > "$CONF_FILE" <<-EOF
	# Rago OS — options de démarrage du noyau Rago (lu par build_rago_kernel.sh).
	# Après modification : sudo $here/build_rago_kernel.sh bootloader

	# Base de la ligne de commande (reprise du noyau courant à l'installation).
	RAGO_CMDLINE="$base"

	# Mitigations des failles CPU (Spectre, etc.) :
	#   auto = défaut du noyau (recommandé) ;
	#   off  = mitigations=off : quelques % de perf en plus, MOINS DE SÉCURITÉ.
	RAGO_MITIGATIONS=auto

	# Paramètres ajoutés à la fin (facultatif).
	RAGO_CMDLINE_EXTRA=""

	# Montage de l'ESP utilisée par systemd-boot.
	RAGO_ESP=/boot
	EOF
}

esp_dir() { rago_conf_get "$CONF_FILE" RAGO_ESP /boot; }

# Signe un binaire EFI avec la clé MOK, en place, puis vérifie.
sbsign_file() {
	local f=$1
	[ -f "$MOK_DIR/MOK.key" ] || [ "$dry_run" = 1 ] || die "pas de clé MOK : lancer « mok-gen » puis « mok-enroll »"
	if [ "$dry_run" = 0 ] && sbverify --cert "$MOK_DIR/MOK.crt" "$f" >/dev/null 2>&1; then
		log "$(basename "$f") déjà signé par la clé MOK"
		return
	fi
	log "signature de $f"
	run sbsign --key "$MOK_DIR/MOK.key" --cert "$MOK_DIR/MOK.crt" --output "$f.signed" "$f"
	run mv "$f.signed" "$f"
	run sbverify --cert "$MOK_DIR/MOK.crt" "$f"
}

# --- install ---------------------------------------------------------------------------
step_install() {
	need_root install
	write_default_conf
	local pkg tarball
	pkg=$(find "$OUT" -maxdepth 1 -name "$PKGBASE-[0-9]*.pkg.tar.*" ! -name '*.sig' 2>/dev/null | sort | tail -1)
	tarball=$(find "$OUT" -maxdepth 1 -name 'linux-*.tar' 2>/dev/null | sort | tail -1)
	if [ -n "$pkg" ] && command -v pacman >/dev/null; then
		local headers
		headers=$(find "$OUT" -maxdepth 1 -name "$PKGBASE-headers-*.pkg.tar.*" 2>/dev/null | sort | tail -1)
		log "pacman -U $(basename "$pkg") ${headers:+$(basename "$headers")}"
		# shellcheck disable=SC2086
		run pacman -U --noconfirm "$pkg" $headers
		# Le hook mkinitcpio d'Arch copie vmlinuz dans /boot et crée l'initramfs
		# à partir du fichier pkgbase du paquet.
	elif [ -n "$tarball" ]; then
		log "installation du tarball $(basename "$tarball")"
		run tar -C / -xf "$tarball"
		local rel
		rel=$(tar -tf "$tarball" | sed -n 's|^lib/modules/\([^/]*\)/$|\1|p; s|^usr/lib/modules/\([^/]*\)/$|\1|p' | head -1)
		[ -n "$rel" ] || die "version introuvable dans $tarball"
		run cp "/boot/vmlinuz-$rel" "/boot/vmlinuz-$PKGBASE"
		if command -v mkinitcpio >/dev/null; then
			run mkinitcpio -k "$rel" -g "/boot/initramfs-$PKGBASE.img"
		elif command -v dracut >/dev/null; then
			run dracut --force --kver "$rel" "/boot/initramfs-$PKGBASE.img"
		else
			die "ni mkinitcpio ni dracut : initramfs impossible"
		fi
	else
		die "aucun paquet dans $OUT : lancer « package »"
	fi
	step_dkms_conf
	step_sign
	step_bootloader
}

# DKMS (pilote NVIDIA, etc.) : signer les modules avec la clé MOK.
step_dkms_conf() {
	[ -d /etc/dkms ] || return 0
	log "DKMS : signature des modules avec la clé MOK"
	run install -d /etc/dkms/framework.conf.d
	if [ "$dry_run" = 1 ]; then
		echo "[dry-run] écrire /etc/dkms/framework.conf.d/rago.conf"
		return
	fi
	cat > /etc/dkms/framework.conf.d/rago.conf <<-EOF
	# Rago OS : modules DKMS signés avec la clé MOK (Secure Boot).
	mok_signing_key="$MOK_DIR/MOK.key"
	mok_certificate="$MOK_DIR/MOK.cer"
	sign_tool="/etc/dkms/sign_helper.sh"
	EOF
	if [ ! -x /etc/dkms/sign_helper.sh ]; then
		cat > /etc/dkms/sign_helper.sh <<-'EOF'
		#!/bin/sh
		# Rago OS : signe un module DKMS (appelé par dkms : <version noyau> <module>).
		exec /usr/lib/modules/"$1"/build/scripts/sign-file sha512 /etc/rago/secureboot/MOK.key /etc/rago/secureboot/MOK.cer "$2"
		EOF
		chmod 0755 /etc/dkms/sign_helper.sh
	fi
}

# --- sign ----------------------------------------------------------------------------------
step_sign() {
	need_root sign
	command -v sbsign >/dev/null || die "sbsign absent (paquet sbsigntools)"
	local k="${RAGO_KERNEL_IMG:-/boot/vmlinuz-$PKGBASE}"
	[ -f "$k" ] || [ "$dry_run" = 1 ] || die "$k absent : lancer « install »"
	sbsign_file "$k"
}

# --- bootloader -----------------------------------------------------------------------------
step_bootloader() {
	need_root bootloader
	write_default_conf
	local esp base mit extra opts entry rel shim mm sdboot dest
	esp=$(esp_dir)
	[ -d "$esp/loader" ] || [ "$dry_run" = 1 ] || die "$esp/loader absent : systemd-boot n'est pas installé sur l'ESP ($esp)"

	base=$(rago_conf_get "$CONF_FILE" RAGO_CMDLINE "")
	[ -n "$base" ] || base=$(rago_cmdline_base "$(cat /proc/cmdline)")
	mit=$(rago_conf_get "$CONF_FILE" RAGO_MITIGATIONS auto)
	extra=$(rago_conf_get "$CONF_FILE" RAGO_CMDLINE_EXTRA "")
	opts=$(rago_cmdline "$base" "$mit" "$extra") || die "RAGO_MITIGATIONS invalide : $mit (auto|off)"
	[ "$mit" = off ] && warn "mitigations=off actif (choix explicite dans $CONF_FILE)"

	# Microcode : chargé avant l'initramfs s'il est présent sur l'ESP.
	RAGO_UCODE_IMAGES=""
	for u in amd-ucode.img intel-ucode.img; do
		[ -f "$esp/$u" ] && RAGO_UCODE_IMAGES="$RAGO_UCODE_IMAGES /$u"
	done
	export RAGO_UCODE_IMAGES

	# Version installée : dossier de modules dont le fichier pkgbase est le nôtre.
	rel=""
	for d in /usr/lib/modules/*; do
		if [ "$(cat "$d/pkgbase" 2>/dev/null)" = "$PKGBASE" ]; then rel=$(basename "$d"); fi
	done
	entry="$esp/loader/entries/rago.conf"
	log "entrée systemd-boot : $entry"
	if [ "$dry_run" = 1 ]; then
		rago_loader_entry "Rago OS" "${rel:-?}" "/vmlinuz-$PKGBASE" "/initramfs-$PKGBASE.img" "$opts" | sed 's/^/[dry-run] /'
	else
		rago_loader_entry "Rago OS" "${rel:-?}" "/vmlinuz-$PKGBASE" "/initramfs-$PKGBASE.img" "$opts" > "$entry.tmp"
		mv "$entry.tmp" "$entry"
	fi

	# systemd-boot signé avec la clé MOK.
	sdboot=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
	[ -f "$sdboot" ] || [ "$dry_run" = 1 ] || die "$sdboot absent (paquet systemd)"
	# Copie « .signed » : `bootctl install/update` la préfère à l'original.
	run sbsign --key "$MOK_DIR/MOK.key" --cert "$MOK_DIR/MOK.crt" --output "$sdboot.signed" "$sdboot"

	shim=""; mm=""
	for d in /usr/share/shim-signed /usr/share/shim /usr/lib/shim; do
		[ -f "$d/shimx64.efi" ] && shim="$d/shimx64.efi"
		[ -f "$d/mmx64.efi" ] && mm="$d/mmx64.efi"
		[ -n "$shim" ] && break
	done
	if [ -n "$shim" ]; then
		# Chaîne : firmware (clé Microsoft) -> shim -> systemd-boot (clé MOK)
		# -> noyau (clé MOK). shim lance « grubx64.efi » dans son dossier.
		dest="$esp/EFI/rago"
		log "shim trouvé : chaîne shim -> systemd-boot dans $dest"
		run install -d "$dest"
		run install -m 0644 "$shim" "$dest/shimx64.efi"
		[ -n "$mm" ] && run install -m 0644 "$mm" "$dest/mmx64.efi"
		run install -m 0644 "$sdboot.signed" "$dest/grubx64.efi"
		if command -v efibootmgr >/dev/null && [ "$dry_run" = 0 ] && ! efibootmgr | grep -q "Rago OS"; then
			local part disk partnum
			part=$(findmnt -no SOURCE "$esp")
			disk="/dev/$(lsblk -no PKNAME "$part")"
			partnum=$(cat "/sys/class/block/$(basename "$part")/partition")
			log "ajout de l'entrée UEFI « Rago OS » ($disk partition $partnum)"
			efibootmgr --create --disk "$disk" --part "$partnum" \
				--label "Rago OS" --loader '\EFI\rago\shimx64.efi' >/dev/null
		fi
	else
		warn "shim absent (paquet shim-signed) : seul systemd-boot est signé avec la clé MOK."
		warn "Sans shim, la clé MOK doit être dans la db UEFI (inscription firmware) pour démarrer avec Secure Boot."
		run bootctl update --graceful
	fi
}

# --- scx-install ----------------------------------------------------------------------------
step_scx_install() {
	need_root scx-install
	local bin="$OUT/bin"
	[ -x "$bin/scx_rago" ] || [ "$dry_run" = 1 ] || die "$bin/scx_rago absent : lancer « scx » (sans root)"
	run install -m 0755 "$bin/scx_rago" /usr/bin/scx_rago
	run install -m 0755 "$bin/rago-sched-hint" /usr/bin/rago-sched-hint
	run install -m 0644 "$repo/host/systemd/rago-scx.service" /usr/lib/systemd/system/rago-scx.service
	run install -Dm 0644 "$repo/kernel/scx/scx_rago/RAGO_FORK.md" /usr/share/doc/rago/RAGO_FORK.md
	if ! getent group rago >/dev/null; then
		log "création du groupe système « rago » (accès au canal launcher)"
		run groupadd --system rago
	fi
	if [ -n "$target_user" ]; then
		log "ajout de $target_user au groupe rago (effectif à la prochaine connexion)"
		run usermod -aG rago "$target_user"
	else
		warn "aucun utilisateur ajouté au groupe rago (--user NOM)"
	fi
	# scx_loader (paquet scx-scheds) gère aussi sched_ext : un seul à la fois.
	if systemctl is-enabled scx_loader.service >/dev/null 2>&1; then
		log "désactivation de scx_loader (conflit)"
		run systemctl disable --now scx_loader.service
	fi
	run systemctl daemon-reload
	run systemctl enable --now rago-scx.service
	log "rago-scx actif. État : systemctl status rago-scx ; rago-sched-hint status"
}

# --- programme principal ----------------------------------------------------------------
usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }

steps=()
while [ $# -gt 0 ]; do
	case "$1" in
	--x86-level) x86_level=$2; shift 2 ;;
	--no-localmodconfig) localmod=0; shift ;;
	--lsmod) lsmod_file=$2; shift 2 ;;
	--base-config) base_config=$2; shift 2 ;;
	--jobs) jobs=$2; shift 2 ;;
	--user) target_user=$2; shift 2 ;;
	--patches-ref) patches_ref=$2; shift 2 ;;
	--config-ref) config_ref=$2; shift 2 ;;
	--dry-run) dry_run=1; shift ;;
	-h|--help) usage; exit 0 ;;
	-*) die "option inconnue : $1" ;;
	*) steps+=("$1"); shift ;;
	esac
done
[ ${#steps[@]} -gt 0 ] || { usage; exit 2; }
case "$x86_level" in auto|3|4) ;; *) die "--x86-level : auto, 3 ou 4" ;; esac

mkdir -p "$BUILD" "$OUT" 2>/dev/null || true
OUT_CONFIG="$OUT/config-rago"
RAGO_KCFLAGS=""

for s in "${steps[@]}"; do
	case "$s" in
	deps) step_deps ;;
	lock) step_lock ;;
	fetch) step_fetch ;;
	prepare) step_prepare ;;
	config) step_config ;;
	verify) step_verify ;;
	build) step_build ;;
	package) step_package ;;
	scx) step_scx ;;
	all) step_deps; step_fetch; step_prepare; step_config; step_verify; step_build; step_package; step_scx ;;
	mok-gen) step_mok_gen ;;
	mok-enroll) step_mok_enroll ;;
	install) step_install ;;
	sign) step_sign ;;
	bootloader) step_bootloader ;;
	scx-install) step_scx_install ;;
	secureboot-status) step_secureboot_status ;;
	*) die "étape inconnue : $s (voir --help)" ;;
	esac
done
