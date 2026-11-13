#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — tests unitaires de host/lib/rago_uki_lib.sh (module M4 : UKI,
# prédiction de PCR 11, politique TPM, entrées de démarrage A/B).
# Sans root, sans disque, sans TPM. Usage : host/tests/test_uki_lib.sh
#
# Oracles indépendants du code testé :
#   - python3 (hashlib) recalcule PCR 11 et construit de petits fichiers PE ;
#   - si ukify et systemd-measure sont là, une vraie UKI est construite et
#     comparée à « ukify build --measure » (calcul de systemd lui-même) ;
#   - de vrais jetons systemd-cryptenroll (fixtures/m4, TPM émulé swtpm, PCR
#     connus) : leur « tpm2-policy-hash » doit être retrouvé.
set -u

here=$(cd "$(dirname "$0")" && pwd)
fx3="$here/fixtures/m3"
fx="$here/fixtures/m4"
# shellcheck source-path=SCRIPTDIR source=../lib/rago_uki_lib.sh
. "$here/../lib/rago_uki_lib.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
skipped=0

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

skip() { skipped=$((skipped + 1)); printf 'IGNORÉ %s\n' "$*"; }

have_py=0
command -v python3 >/dev/null 2>&1 && have_py=1

# --- octets, sha256, extension de PCR -----------------------------------------------------
check "sha256 texte « abc »" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$(rago_sha256_text abc)"
check "sha256 texte + NUL « .linux »" "$(printf '.linux\0' | sha256sum | cut -d' ' -f1)" "$(rago_sha256_text_nul .linux)"
check "sha256 d'octets hexa (616263 = abc)" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$(rago_sha256_hex 616263)"
check "sha256 d'octets hexa en majuscules" ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$(rago_sha256_hex 616263 | tr a-f A-F | tr A-F a-f)"
check_rc "hexa impair refusé" 1 rago_hex_bin abc
check_rc "hexa invalide refusé" 1 rago_hex_bin zz
check "octets hexa -> binaire (00 ff 41)" "00ff41" "$(rago_hex_bin 00FF41 | od -An -v -t x1 | tr -d ' \n')"
check_rc "sha256 hexa valide" 0 rago_is_sha256_hex "$RAGO_PCR_ZERO"
check_rc "sha256 hexa trop court" 1 rago_is_sha256_hex abcd
check_rc "sha256 hexa avec un g" 1 rago_is_sha256_hex "${RAGO_PCR_ZERO%0}g"
# Extension : sha256(0…0 || sha256("enter-initrd")).
want=$(printf '%s' "$RAGO_PCR_ZERO$(rago_sha256_text enter-initrd)" | sed 's/../\\x&/g' | xargs -0 printf '%b' | sha256sum | cut -d' ' -f1)
check "extension de PCR (sha256(ancien || empreinte))" "$want" "$(rago_pcr_extend "$RAGO_PCR_ZERO" "$(rago_sha256_text enter-initrd)")"

# --- petits fichiers PE (python3) -----------------------------------------------------------
# mkpe <sortie> <nom:fichier[:taille virtuelle]>... : PE32+ minimal, sections alignées
# sur 512 octets (taille brute), taille virtuelle donnée ou = taille du fichier.
mkpe() {
	python3 - "$@" <<'PY'
import struct, sys
out = sys.argv[1]
secs = []
for spec in sys.argv[2:]:
    parts = spec.split(":")
    name, path = parts[0], parts[1]
    data = open(path, "rb").read()
    vsize = int(parts[2]) if len(parts) > 2 else len(data)
    secs.append((name.encode(), data, vsize))
nsec = len(secs)
optsz = 240
hdr_end = 0x80 + 4 + 20 + optsz + 40 * nsec
raw = (hdr_end + 511) // 512 * 512
dos = bytearray(0x80)
dos[0:2] = b"MZ"
struct.pack_into("<I", dos, 0x3c, 0x80)
coff = struct.pack("<HHIIIHH", 0x8664, nsec, 0, 0, 0, optsz, 0x22)
opt = bytearray(optsz)
struct.pack_into("<H", opt, 0, 0x20b)
table = b""
body = b""
va = 0x1000
for name, data, vsize in secs:
    rs = (len(data) + 511) // 512 * 512
    table += struct.pack("<8sIIIIIIHHI", name.ljust(8, b"\0"), vsize, va, rs, raw + len(body), 0, 0, 0, 0, 0x40000040)
    body += data + b"\0" * (rs - len(data))
    va += (max(vsize, rs) + 0xfff) // 0x1000 * 0x1000
head = bytes(dos) + b"PE\0\0" + coff + bytes(opt) + table
head += b"\0" * (raw - len(head))
open(out, "wb").write(head + body)
PY
}

# Oracle PCR 11 : sections données dans l'ordre de mesure, puis phases.
#   py_pcr11 <nom:fichier:taille virtuelle>... -- <phase>...
py_pcr11() {
	python3 - "$@" <<'PY'
import hashlib, sys
args = sys.argv[1:]
cut = args.index("--")
pcr = b"\0" * 32
def ext(pcr, d):
    return hashlib.sha256(pcr + d).digest()
for spec in args[:cut]:
    name, path, vsize = spec.split(":")
    data = open(path, "rb").read()
    vsize = int(vsize)
    data = data[:vsize] + b"\0" * max(0, vsize - len(data))
    pcr = ext(pcr, hashlib.sha256(name.encode() + b"\0").digest())
    pcr = ext(pcr, hashlib.sha256(data).digest())
for ph in args[cut + 1:]:
    pcr = ext(pcr, hashlib.sha256(ph.encode()).digest())
print(pcr.hex())
PY
}

if [ "$have_py" = 1 ]; then
	printf 'NOYAU-%.0s' $(seq 1 300) > "$tmp/linux"
	printf 'ID=rago\nNAME="Rago OS"\n' > "$tmp/osrel"
	printf 'root=/dev/mapper/rago-root rd.shell=0' > "$tmp/cmdline"
	printf 'INITRAMFS-%.0s' $(seq 1 50) > "$tmp/initrd"
	printf '6.18.44-rago' > "$tmp/uname"
	printf 'sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md\n' > "$tmp/sbat"
	printf 'slot=a\npcr11-phases=enter-initrd\nversion=test-1\n' > "$tmp/rago"
	printf 'CODE' > "$tmp/text"
	# Ordre dans le fichier volontairement différent de l'ordre de mesure ; .linux
	# avec une taille virtuelle plus grande (zéros), .cmdline plus petite (tronquée).
	mkpe "$tmp/uki.efi" ".text:$tmp/text" ".osrel:$tmp/osrel" ".cmdline:$tmp/cmdline:20" \
		".uname:$tmp/uname" ".sbat:$tmp/sbat" ".initrd:$tmp/initrd" ".rago:$tmp/rago" ".linux:$tmp/linux:4000"
	secs=$(rago_pe_sections "$tmp/uki.efi")
	check "PE : 8 sections lues" 8 "$(wc -l <<<"$secs")"
	check "PE : noms dans l'ordre du fichier" ".text .osrel .cmdline .uname .sbat .initrd .rago .linux" "$(awk '{ print $1 }' <<<"$secs" | tr '\n' ' ' | sed 's/ $//')"
	check "PE : .linux taille virtuelle 4000, brute 2048" "4000 2048" "$(awk '$1 == ".linux" { print $2, $4 }' <<<"$secs")"
	check "PE : section texte (.osrel)" "$(cat "$tmp/osrel")" "$(rago_uki_section "$tmp/uki.efi" .osrel)"
	check "PE : section tronquée à la taille virtuelle (.cmdline)" "root=/dev/mapper/ra" "$(rago_uki_section "$tmp/uki.efi" .cmdline | head -c 19)"
	check "PE : taille virtuelle de .cmdline respectée" 20 "$(rago_uki_section "$tmp/uki.efi" .cmdline | wc -c)"
	check "PE : section complétée de zéros (.linux, 4000 octets)" 4000 "$(rago_uki_section "$tmp/uki.efi" .linux | wc -c)"
	check "métadonnées .rago : slot" a "$(rago_uki_meta "$tmp/uki.efi" slot)"
	check "métadonnées .rago : version" test-1 "$(rago_uki_meta "$tmp/uki.efi" version)"
	check "métadonnées .rago : clé absente" "" "$(rago_uki_meta "$tmp/uki.efi" absent)"
	check_rc "section absente" 1 rago_uki_section "$tmp/uki.efi" .splash

	order=(".linux:$tmp/linux:4000" ".osrel:$tmp/osrel:$(wc -c < "$tmp/osrel")" ".cmdline:$tmp/cmdline:20"
		".initrd:$tmp/initrd:$(wc -c < "$tmp/initrd")" ".uname:$tmp/uname:$(wc -c < "$tmp/uname")" ".sbat:$tmp/sbat:$(wc -c < "$tmp/sbat")")
	check "PCR 11 sans phase (sections mesurées, .rago et .text ignorées)" "$(py_pcr11 "${order[@]}" --)" "$(rago_uki_pcr11 "$tmp/uki.efi")"
	check "PCR 11 à l'ouverture des volumes (enter-initrd)" "$(py_pcr11 "${order[@]}" -- enter-initrd)" "$(rago_uki_pcr11 "$tmp/uki.efi" enter-initrd)"
	check "PCR 11 système démarré (4 phases)" "$(py_pcr11 "${order[@]}" -- enter-initrd leave-initrd sysinit ready)" "$(rago_uki_pcr11 "$tmp/uki.efi" enter-initrd leave-initrd sysinit ready)"
	check "PCR 11 d'ouverture lu dans .rago (pcr11-phases=enter-initrd)" "$(py_pcr11 "${order[@]}" -- enter-initrd)" "$(rago_uki_unlock_pcr11 "$tmp/uki.efi")"
	rv=$(rago_uki_pcr11_runtime_values "$tmp/uki.efi")
	check "valeurs possibles au démarrage : 7 lignes" 7 "$(wc -l <<<"$rv")"
	check "valeurs possibles : chaîne complète" "$(py_pcr11 "${order[@]}" -- enter-initrd leave-initrd sysinit ready)" "$(awk '$1 == "enter-initrd:leave-initrd:sysinit:ready" { print $2 }' <<<"$rv")"
	check "valeurs possibles : initramfs sans barrière (sysinit, ready)" "$(py_pcr11 "${order[@]}" -- sysinit ready)" "$(awk '$1 == "sysinit:ready" { print $2 }' <<<"$rv")"

	# Initramfs sans systemd-pcrphase : .rago dit « pcr11-phases= » (vide).
	printf 'slot=b\npcr11-phases=\n' > "$tmp/rago-nophase"
	mkpe "$tmp/uki-nophase.efi" ".linux:$tmp/linux:4000" ".rago:$tmp/rago-nophase"
	check "PCR 11 d'ouverture sans barrière (pcr11-phases vide)" "$(py_pcr11 ".linux:$tmp/linux:4000" --)" "$(rago_uki_unlock_pcr11 "$tmp/uki-nophase.efi")"
	# Pas de .rago : pas une UKI de Rago, on ne devine pas.
	mkpe "$tmp/uki-norago.efi" ".linux:$tmp/linux" ".osrel:$tmp/osrel"
	check_rc "UKI sans .rago : prédiction refusée" 3 rago_uki_unlock_pcr11 "$tmp/uki-norago.efi"
	# Section .profile (UKI à profils) : mesure différente, refus.
	mkpe "$tmp/uki-profile.efi" ".linux:$tmp/linux" ".profile:$tmp/osrel" ".rago:$tmp/rago"
	check_rc "UKI à profils (.profile) : prédiction refusée" 2 rago_uki_pcr11 "$tmp/uki-profile.efi"
	check_rc "UKI à profils : ouverture refusée aussi" 2 rago_uki_unlock_pcr11 "$tmp/uki-profile.efi"
	mkpe "$tmp/nolinux.efi" ".osrel:$tmp/osrel" ".rago:$tmp/rago"
	check_rc "PE sans .linux : pas une UKI" 1 rago_uki_pcr11 "$tmp/nolinux.efi"
	printf 'pas un PE' > "$tmp/notpe"
	check_rc "fichier qui n'est pas un PE" 1 rago_pe_sections "$tmp/notpe"
	check_rc "fichier absent" 1 rago_pe_sections "$tmp/absent"
	head -c 300 "$tmp/uki.efi" > "$tmp/cut.efi"
	check_rc "PE coupé (table des sections incomplète)" 1 rago_pe_sections "$tmp/cut.efi"
else
	skip "python3 absent : tests PE / PCR 11 sautés"
fi

# --- vraie UKI (ukify) contre le calcul de systemd (ukify --measure) ----------------------------
measure=""
for m in /usr/lib/systemd/systemd-measure /lib/systemd/systemd-measure; do [ -x "$m" ] && measure=$m && break; done
stub=""
for s in /usr/lib/systemd/boot/efi/linuxx64.efi.stub /lib/systemd/boot/efi/linuxx64.efi.stub; do [ -f "$s" ] && stub=$s && break; done
if command -v ukify >/dev/null 2>&1 && [ -n "$measure" ] && [ -n "$stub" ]; then
	printf 'slot=a\npcr11-phases=enter-initrd\n' > "$tmp/meta"
	if ukify build --linux="$tmp/linux" --initrd="$tmp/initrd" --cmdline='root=/dev/mapper/rago-root rd.shell=0 rd.emergency=reboot' \
		--os-release=@"$tmp/osrel" --uname=6.18.44-rago --section=.rago:@"$tmp/meta" --measure \
		--output="$tmp/real.efi" > "$tmp/measure.txt" 2>&1; then
		# Les titres « # PCR[11] Phase <…> » et les valeurs sortent sur deux flux
		# (leur mélange dépend de la version) : la n-ième valeur sha256 va avec la
		# n-ième phase.
		mapfile -t mph < <(sed -n 's/^# PCR\[11\] Phase <\(.*\)>$/\1/p' "$tmp/measure.txt")
		mapfile -t mval < <(sed -n 's/^11:sha256=//p' "$tmp/measure.txt")
		check "systemd-measure : 4 phases, 4 valeurs sha256" "4 4" "${#mph[@]} ${#mval[@]}"
		unlock=""
		for i in "${!mph[@]}"; do
			ph=${mph[$i]}
			[ "$ph" = enter-initrd ] && unlock=${mval[$i]:-}
			# shellcheck disable=SC2046  # phases séparées
			got=$(rago_uki_pcr11 "$tmp/real.efi" $(tr ':' ' ' <<<"$ph"))
			check "vraie UKI (ukify $(ukify --version 2>/dev/null | awk '{ print $2 }')) : PCR 11 phase $ph = systemd-measure" "${mval[$i]:-}" "$got"
		done
		check "vraie UKI : PCR 11 d'ouverture lu dans .rago" "$unlock" "$(rago_uki_unlock_pcr11 "$tmp/real.efi")"
	else
		skip "ukify build a échoué : $(tail -1 "$tmp/measure.txt")"
	fi
else
	skip "ukify / systemd-measure / systemd-stub absents : comparaison avec systemd sautée"
fi

# --- politique TPM (PolicyPCR) et jetons LUKS2 --------------------------------------------------
# Jetons faits par systemd-cryptenroll 255 sur un TPM émulé (swtpm) dont les PCR
# valaient : 0 = c66c…2529, 7 = 469a…4a19 ; PCR 11 donné en valeur littérale.
P0=c66c37d3916a781e35d869d2d6596b9c6e35b68c3bc9b8f88ab7279dbddb2529
P7=469ab4eabe5fef10a1d1ac79084cadf2388b25806c1b45682cf31e7ba3084a19
X11=f2a2405f0a2e6d6f42c8f1d6d1d0ff8ad0e4ad1ae24b2a5ec5b5ad1ec3eab81b
Y11=1111111111111111111111111111111111111111111111111111111111111111
for v in 2.7 2.8; do
	toks=$(rago_luks_tpm2_tokens < "$fx/luksdump-cryptsetup-$v-tpm2-multi.txt")
	check "jetons (cryptsetup $v) : 3 jetons systemd-tpm2" 3 "$(wc -l <<<"$toks")"
	check "jetons (cryptsetup $v) : id, emplacement, PCR" "0 1 0+7|1 2 0+7+11|2 3 7+11" "$(awk '{ print $1, $2, $3 }' <<<"$toks" | tr '\n' '|' | sed 's/|$//')"
	check "politique 0+7 = jeton 0 (cryptsetup $v)" "$(awk '$1 == 0 { print $4 }' <<<"$toks")" "$(rago_tpm2_policy_pcr 0=$P0 7=$P7)"
	check "politique 0+7+11 (11 littéral) = jeton 1 (cryptsetup $v)" "$(awk '$1 == 1 { print $4 }' <<<"$toks")" "$(rago_tpm2_policy_pcr 0=$P0 7=$P7 11=$X11)"
	check "politique 7+11 = jeton 2 (cryptsetup $v)" "$(awk '$1 == 2 { print $4 }' <<<"$toks")" "$(rago_tpm2_policy_pcr 7=$P7 11=$Y11)"
done
check "politique : ordre des PCR donnés sans importance" "$(rago_tpm2_policy_pcr 0=$P0 7=$P7 11=$X11)" "$(rago_tpm2_policy_pcr 11=$X11 0=$P0 7=$P7)"
check "politique : valeurs en majuscules acceptées" "$(rago_tpm2_policy_pcr 0=$P0 7=$P7)" "$(rago_tpm2_policy_pcr 0="$(tr a-f A-F <<<"$P0")" 7=$P7)"
check_rc "politique : PCR 24 refusé" 1 rago_tpm2_policy_pcr 24=$P0
check_rc "politique : valeur invalide refusée" 1 rago_tpm2_policy_pcr 0=abcd
check_rc "politique : rien à lier" 1 rago_tpm2_policy_pcr
# Jetons de M3 (un seul jeton 0+7, cryptsetup 2.7 et 2.8).
for f in "$fx3"/luksdump-cryptsetup-2.7-tpm2.txt "$fx3"/luksdump-cryptsetup-2.8-tpm2.txt; do
	toks=$(rago_luks_tpm2_tokens < "$f")
	check "jeton M3 ($(basename "$f")) : 1 jeton 0+7 avec empreinte" "1 0+7 64" "$(awk '{ print NR, $3, length($4) }' <<<"$toks")"
done
check "luksDump sans jeton : rien" "" "$(printf 'LUKS header information\nTokens:\nDigests:\n' | rago_luks_tpm2_tokens)"
check_rc "PCR 11 dans 0+7+11" 0 rago_pcrs_have 0+7+11 11
check_rc "PCR 1 pas dans 0+7+11" 1 rago_pcrs_have 0+7+11 1
check_rc "PCR 7 dans 7" 0 rago_pcrs_have 7 7

# --- variables EFI de systemd-boot ------------------------------------------------------------------
printf '\x07\x00\x00\x00' > "$tmp/var"
printf 'rago-a.efi' | sed 's/./&\n/g' | while IFS= read -r c; do [ -n "$c" ] && printf '%s\0' "$c"; done >> "$tmp/var"
printf '\0\0' >> "$tmp/var"
check "variable EFI UTF-16 -> texte" rago-a.efi "$(rago_efivar_string "$tmp/var")"
check "variable EFI absente -> vide" "" "$(rago_efivar_string "$tmp/absente")"

# --- entrées A/B ------------------------------------------------------------------------------------
check "entrée UKI du slot a" rago-a.efi "$(rago_ab_entry_id a uki)"
check "entrée UKI à l'essai du slot b" rago-b.next.efi "$(rago_ab_entry_id b uki next)"
check "entrée de repli du slot a" rago-a.conf "$(rago_ab_entry_id a conf)"
check_rc "slot c refusé" 1 rago_ab_entry_id c uki
check "slot de rago-b.next.efi" b "$(rago_ab_entry_slot rago-b.next.efi)"
check "slot de rago-a.conf" a "$(rago_ab_entry_slot rago-a.conf)"
check "slot de l'entrée de M0" m0 "$(rago_ab_entry_slot rago.conf)"
check_rc "entrée étrangère" 1 rago_ab_entry_slot ubuntu.conf
check "nom définitif de rago-a.next.efi" rago-a.efi "$(rago_ab_entry_final rago-a.next.efi)"
check "nom définitif de rago-b.next.conf" rago-b.conf "$(rago_ab_entry_final rago-b.next.conf)"
check "nom définitif de rago-b.efi" rago-b.efi "$(rago_ab_entry_final rago-b.efi)"
check "fichier de rago-a.efi" EFI/Linux/rago-a.efi "$(rago_ab_entry_path rago-a.efi)"
check "fichier de rago-b.conf" loader/entries/rago-b.conf "$(rago_ab_entry_path rago-b.conf)"
check "dossier de rago-b.next.conf" rago/b.next "$(rago_ab_conf_dir rago-b.next.conf)"
check "dossier de rago-a.conf" rago/a "$(rago_ab_conf_dir rago-a.conf)"
esp="$tmp/esp"
mkdir -p "$esp/EFI/Linux" "$esp/loader/entries"
: > "$esp/EFI/Linux/rago-a.efi"
: > "$esp/EFI/Linux/rago-a.next.efi"
: > "$esp/EFI/Linux/autre.efi"
: > "$esp/loader/entries/rago-b.conf"
: > "$esp/loader/entries/rago.conf"
: > "$esp/loader/entries/ubuntu.conf"
check "entrées Rago de l'ESP" "rago-a.efi a uki|rago-a.next.efi a uki|rago-b.conf b conf|rago.conf m0 conf" "$(rago_ab_entries "$esp" | tr '\n' '|' | sed 's/|$//')"
check "ESP vide : aucune entrée" "" "$(rago_ab_entries "$tmp/vide")"

# --- initramfs : barrière TPM de systemd --------------------------------------------------------------
cat > "$tmp/ls-yes" <<'EOF'
-rwxr-xr-x   1 root     root        12345 Apr 15 12:00 usr/lib/systemd/systemd-pcrextend
-rw-r--r--   1 root     root          900 Apr 15 12:00 usr/lib/systemd/system/systemd-pcrphase-initrd.service
lrwxrwxrwx   1 root     root           34 Apr 15 12:00 usr/lib/systemd/system/initrd.target.wants/systemd-pcrphase-initrd.service -> ../systemd-pcrphase-initrd.service
EOF
check_rc "initramfs avec systemd-pcrphase (lsinitrd)" 0 rago_initramfs_has_pcrphase "$tmp/ls-yes"
grep -v 'initrd.target.wants' "$tmp/ls-yes" > "$tmp/ls-nowants"
check_rc "service présent mais pas activé : pas de barrière" 1 rago_initramfs_has_pcrphase "$tmp/ls-nowants"
grep -v 'pcrextend' "$tmp/ls-yes" > "$tmp/ls-nobin"
check_rc "programme absent : pas de barrière" 1 rago_initramfs_has_pcrphase "$tmp/ls-nobin"
printf 'usr/lib/systemd/systemd-pcrphase\nusr/lib/systemd/system/systemd-pcrphase-initrd.service\nusr/lib/systemd/system/initrd.target.wants/systemd-pcrphase-initrd.service\n' > "$tmp/ls-cpio"
check_rc "liste « un chemin par ligne » (lsinitcpio), ancien nom systemd-pcrphase" 0 rago_initramfs_has_pcrphase "$tmp/ls-cpio"

# --- ligne de commande, os-release, loader.conf ---------------------------------------------------------
check "ligne de commande d'UKI" "root=/dev/mapper/rago-root quiet rd.shell=0 rd.emergency=reboot" "$(rago_uki_cmdline "root=/dev/mapper/rago-root" auto "quiet" "rd.shell=0 rd.emergency=reboot")"
check "ligne de commande : mitigations=off" "root=x mitigations=off" "$(rago_uki_cmdline "root=x" off "" "")"
check "ligne de commande : espaces en trop retirés" "a b c" "$(rago_uki_cmdline " a  b" auto "" " c ")"
check_rc "mitigations invalide" 2 rago_uki_cmdline x peut-être "" ""
printf 'PRETTY_NAME="Ubuntu 26.04 LTS"\nNAME="Ubuntu"\nID=ubuntu\nIMAGE_VERSION=1\n' > "$tmp/os-release"
osr=$(rago_uki_os_release "$tmp/os-release" b 2026.11.13)
check "os-release d'UKI : titre du slot" 'PRETTY_NAME="Rago OS — slot B (2026.11.13)"' "$(grep '^PRETTY_NAME=' <<<"$osr")"
check "os-release d'UKI : version de l'image" 'IMAGE_VERSION="2026.11.13"' "$(grep '^IMAGE_VERSION=' <<<"$osr")"
check "os-release d'UKI : le reste gardé" 'NAME="Ubuntu"|ID=ubuntu' "$(grep -E '^(NAME|ID)=' <<<"$osr" | tr '\n' '|' | sed 's/|$//')"
check "os-release d'UKI : un seul PRETTY_NAME" 1 "$(grep -c '^PRETTY_NAME=' <<<"$osr")"
check "os-release absent : nom Rago" 'NAME="Rago OS"' "$(rago_uki_os_release "$tmp/absent" a "" | grep '^NAME=')"
printf '# loader.conf\ntimeout 3\ndefault ubuntu.conf\neditor yes\ndefault @saved\n' > "$tmp/loader.conf"
lc=$(rago_loader_conf_set "$tmp/loader.conf" default rago-a.efi)
check "loader.conf : default remplacé, doublon retiré" "# loader.conf|timeout 3|default rago-a.efi|editor yes" "$(tr '\n' '|' <<<"$lc" | sed 's/|$//')"
lc=$(rago_loader_conf_set <(printf '%s\n' "$lc") editor no)
check "loader.conf : editor no" "editor no" "$(grep '^editor' <<<"$lc")"
check "loader.conf absent : clé ajoutée" "editor no" "$(rago_loader_conf_set "$tmp/absent" editor no)"
printf '%s\n' "$lc" > "$tmp/loader2.conf"
check "loader.conf : lecture de default" rago-a.efi "$(rago_loader_conf_get "$tmp/loader2.conf" default)"
check "loader.conf : clé absente -> vide" "" "$(rago_loader_conf_get "$tmp/loader2.conf" console-mode)"

printf 'test_uki_lib : %d OK, %d échec(s), %d ignoré(s)\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
