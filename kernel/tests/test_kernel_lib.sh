#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests unitaires de kernel/lib/rago_kernel_lib.sh (sans root,
# sans matériel). Usage : kernel/tests/test_kernel_lib.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=../lib/rago_kernel_lib.sh
. "$here/../lib/rago_kernel_lib.sh"

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

# --- niveau x86-64 -------------------------------------------------------------
V2="fpu sse sse2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3"
V3="$V2 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave"
V4="$V3 avx512f avx512bw avx512cd avx512dq avx512vl"
check "flags v1" 1 "$(rago_x86_level_from_flags "fpu sse sse2")"
check "flags v2" 2 "$(rago_x86_level_from_flags "$V2")"
check "flags v3" 3 "$(rago_x86_level_from_flags "$V3")"
check "flags v4" 4 "$(rago_x86_level_from_flags "$V4")"
check "flags v3 sans movbe" 2 "$(rago_x86_level_from_flags "${V3/movbe/}")"
check "flags v4 sans avx512vl" 3 "$(rago_x86_level_from_flags "${V4/avx512vl/}")"
# avx512f contient « avx » : il ne doit pas suffire à valider avx.
check "sous-chaîne avx512f" 2 "$(rago_x86_level_from_flags "$V2 avx512f avx2 bmi1 bmi2 f16c fma abm movbe xsave")"

printf 'processor\t: 0\nflags\t\t: %s\n\nprocessor\t: 1\nflags\t\t: %s\n' "$V4" "$V3" > "$tmp/cpuinfo_mixed"
check "cpuinfo : minimum des CPU" 3 "$(rago_detect_x86_level "$tmp/cpuinfo_mixed")"
printf 'processor\t: 0\nflags\t\t: %s\n' "$V4" > "$tmp/cpuinfo_v4"
check "cpuinfo v4" 4 "$(rago_detect_x86_level "$tmp/cpuinfo_v4")"
check "cpuinfo réel lisible" 0 "$( [ -r /proc/cpuinfo ] && rago_detect_x86_level /proc/cpuinfo >/dev/null; echo $?)"

check "choix auto v4" 4 "$(rago_choose_x86_level 4 auto)"
check "choix auto v3" 3 "$(rago_choose_x86_level 3 auto)"
check_rc "choix auto v2 refusé" 1 rago_choose_x86_level 2 auto
check "choix forcé 3 sur v4" 3 "$(rago_choose_x86_level 4 3)"
check_rc "choix forcé 4 sur v3 refusé" 1 rago_choose_x86_level 3 4
check_rc "choix invalide" 2 rago_choose_x86_level 4 5

# --- lecture et vérification de .config -----------------------------------------
cat > "$tmp/config" <<'EOF'
CONFIG_PREEMPT=y
# CONFIG_PREEMPT_NONE is not set
CONFIG_HZ=1000
CONFIG_ZRAM=m
CONFIG_HIBERNATION_DEF_COMP="lz4"
CONFIG_SCHED_CLASS_EXT=y
CONFIG_X86_64_VERSION=3
EOF
check "cfg y" y "$(rago_cfg_get "$tmp/config" PREEMPT)"
check "cfg not set" n "$(rago_cfg_get "$tmp/config" PREEMPT_NONE)"
check "cfg absent" n "$(rago_cfg_get "$tmp/config" SCHED_BORE)"
check "cfg nombre" 1000 "$(rago_cfg_get "$tmp/config" HZ)"
check "cfg chaîne" '"lz4"' "$(rago_cfg_get "$tmp/config" HIBERNATION_DEF_COMP)"
# Un préfixe commun ne doit pas confondre deux symboles.
check "cfg préfixe" n "$(rago_cfg_get "$tmp/config" PREEMPT_DYNAMIC)"

cat > "$tmp/frag_ok" <<'EOF'
# commentaire
CONFIG_PREEMPT=y
# CONFIG_PREEMPT_NONE is not set
CONFIG_HZ=1000
CONFIG_HIBERNATION_DEF_COMP="lz4"
EOF
check "verify conforme (sortie)" "" "$(rago_cfg_verify "$tmp/config" "$tmp/frag_ok")"
check_rc "verify conforme" 0 rago_cfg_verify "$tmp/config" "$tmp/frag_ok"

cat > "$tmp/frag_bad" <<'EOF'
CONFIG_SCHED_BORE=y
CONFIG_ZRAM=y
# CONFIG_HZ is not set
CONFIG_NTSYNC=m # rago:optional
EOF
out=$(rago_cfg_verify "$tmp/config" "$tmp/frag_bad")
check "verify écarts" "MISSING SCHED_BORE want=y got=n
MISSING ZRAM want=y got=m
MISSING HZ want=n got=1000
OPTIONAL NTSYNC want=m got=n" "$out"
check_rc "verify écart obligatoire" 1 rago_cfg_verify "$tmp/config" "$tmp/frag_bad"
printf 'CONFIG_NTSYNC=m # rago:optional\n' > "$tmp/frag_opt"
check_rc "verify optionnel seul" 0 rago_cfg_verify "$tmp/config" "$tmp/frag_opt"

# Les vrais fragments du dépôt sont bien formés (aucune ligne ignorée par erreur).
for f in "$here/../config/rago-gaming.config" "$here/../config/rago-keep.config"; do
	bad=$(grep -v -E '^(#.*|CONFIG_[A-Z0-9_]+=.+|)$' "$f" || true)
	check "fragment bien formé $(basename "$f")" "" "$bad"
done
check "SCHED_CLASS_EXT demandé" 1 "$(grep -c '^CONFIG_SCHED_CLASS_EXT=y$' "$here/../config/rago-gaming.config")"
check "LTO_CLANG_THIN demandé" 1 "$(grep -c '^CONFIG_LTO_CLANG_THIN=y$' "$here/../config/rago-gaming.config")"
check "HZ 1000 demandé" 1 "$(grep -c '^CONFIG_HZ=1000$' "$here/../config/rago-gaming.config")"
# Une même option ne doit pas être demandée avec deux valeurs différentes.
dups=$(cat "$here/../config/rago-keep.config" "$here/../config/rago-gaming.config" |
	sed -n 's/^\(CONFIG_[A-Z0-9_]*\)=\(.*\)$/\1 \2/p' | sort -u | cut -d' ' -f1 | uniq -d)
check "pas de conflit entre fragments" "" "$dups"

# --- ligne de commande et entrée systemd-boot ----------------------------------------
base=$(rago_cmdline_base "BOOT_IMAGE=/vmlinuz-linux initrd=\\initramfs.img root=UUID=abcd rw quiet mitigations=off")
check "cmdline base" "root=UUID=abcd rw quiet" "$base"
check "cmdline auto" "root=UUID=abcd rw quiet" "$(rago_cmdline "$base" auto)"
check "cmdline off" "root=UUID=abcd rw quiet mitigations=off" "$(rago_cmdline "$base" off)"
check "cmdline extra" "root=UUID=abcd rw quiet mitigations=off splash" "$(rago_cmdline "$base" off splash)"
check_rc "cmdline mitigations invalide" 2 rago_cmdline "$base" maybe

entry=$(RAGO_UCODE_IMAGES="/amd-ucode.img" rago_loader_entry "Rago OS" 6.18.44-rago /vmlinuz-linux-rago /initramfs-linux-rago.img "root=UUID=abcd rw")
check "entrée systemd-boot" "title   Rago OS
version 6.18.44-rago
linux   /vmlinuz-linux-rago
initrd  /amd-ucode.img
initrd  /initramfs-linux-rago.img
options root=UUID=abcd rw" "$entry"

# --- /etc/rago/kernel.conf -------------------------------------------------------------
cat > "$tmp/kernel.conf" <<'EOF'
# commentaire
RAGO_CMDLINE="root=UUID=abcd rw"
RAGO_MITIGATIONS=off
RAGO_ESP='/efi'
EOF
check "conf guillemets doubles" "root=UUID=abcd rw" "$(rago_conf_get "$tmp/kernel.conf" RAGO_CMDLINE)"
check "conf brut" off "$(rago_conf_get "$tmp/kernel.conf" RAGO_MITIGATIONS)"
check "conf guillemets simples" /efi "$(rago_conf_get "$tmp/kernel.conf" RAGO_ESP)"
check "conf défaut" auto "$(rago_conf_get "$tmp/kernel.conf" ABSENT auto)"
check "conf fichier absent" auto "$(rago_conf_get "$tmp/nope" RAGO_MITIGATIONS auto)"
# Le fichier n'est jamais exécuté.
# shellcheck disable=SC2016  # chaîne littérale voulue
printf 'RAGO_MITIGATIONS=$(touch %s/pwned)\n' "$tmp" > "$tmp/evil.conf"
rago_conf_get "$tmp/evil.conf" RAGO_MITIGATIONS >/dev/null
check "conf non exécuté" no "$([ -e "$tmp/pwned" ] && echo yes || echo no)"

# --- versions, URL, sources.lock ----------------------------------------------------------
check "url kernel.org" "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.44.tar.xz" "$(rago_kernel_url 6.18.44)"
check_rc "version 6.18.44 >= 6.12" 0 rago_version_ge 6.18.44 6.12
check_rc "version 6.9 < 6.12" 1 rago_version_ge 6.9 6.12
check_rc "sha256 valide" 0 rago_is_sha256 "$(printf x | sha256sum | cut -d' ' -f1)"
check_rc "sha256 PENDING" 1 rago_is_sha256 PENDING
check_rc "sha256 majuscules refusé" 1 rago_is_sha256 "$(printf x | sha256sum | cut -d' ' -f1 | tr a-f A-F)"

cat > "$tmp/lock" <<'EOF'
# en-tête
KERNEL_VERSION=6.18.44
PATCHES_REF=abc
a.tar.xz https://e/a PENDING   # commentaire
b.patch https://e/b 0000
EOF
check "lock entrées" "a.tar.xz https://e/a PENDING
b.patch https://e/b 0000" "$(rago_series_entries "$tmp/lock")"
check "lock variable" 6.18.44 "$(rago_lock_var "$tmp/lock" KERNEL_VERSION)"
printf 'x y\n' > "$tmp/lock_bad"
check_rc "lock ligne invalide" 1 rago_series_entries "$tmp/lock_bad"

lock="$here/../patches/sources.lock"
check "sources.lock : version >= 6.12" 0 "$(rago_version_ge "$(rago_lock_var "$lock" KERNEL_VERSION)" 6.12; echo $?)"
check "sources.lock : tarball cohérent" 1 "$(rago_series_entries "$lock" | grep -c "^linux-$(rago_lock_var "$lock" KERNEL_VERSION).tar.xz $(rago_kernel_url "$(rago_lock_var "$lock" KERNEL_VERSION)") ")"
check "sources.lock : patch BORE" 1 "$(rago_series_entries "$lock" | grep -c 'bore')"

echo "test_kernel_lib : $pass réussis, $fail échoués"
[ "$fail" -eq 0 ]
