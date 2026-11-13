#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Rago OS — module dracut « rago-crypttab » (module M3).
#
# Met dans l'initramfs la crypttab des volumes à ouvrir AU DÉMARRAGE :
# /etc/crypttab.initramfs (écrite par setup_secure_encryption.sh install ;
# même fichier que le hook sd-encrypt de mkinitcpio). Rien d'autre : un volume
# du joueur avec un fichier de clé (resté dans la racine) bloquerait sinon le
# démarrage en demandant sa passphrase dans l'initramfs.
#
# Installé dans /usr/lib/dracut/modules.d/91rago-crypttab/ et demandé par
# /etc/dracut.conf.d/90-rago-encryption.conf (add_dracutmodules).
# shellcheck disable=SC2154  # initdir, dracutsysrootdir : variables de dracut

# Seulement si on le demande (add_dracutmodules).
check() {
	[ -f "${dracutsysrootdir-}/etc/crypttab.initramfs" ] || return 1
	return 255
}

depends() {
	echo systemd-cryptsetup
	return 0
}

install() {
	local src="${dracutsysrootdir-}/etc/crypttab.initramfs" dst="$initdir/etc/crypttab"
	[ -f "$src" ] || return 0
	mkdir -p "$initdir/etc"
	if [ -s "$dst" ]; then
		# Mode hostonly : le module crypt a déjà écrit une crypttab filtrée. On garde
		# ses entrées qui ne visent pas les mêmes volumes, puis on ajoute les nôtres.
		awk 'NR == FNR { if ($0 !~ /^[[:space:]]*(#|$)/) { n[$1] = 1; d[$2] = 1 }; next }
			/^[[:space:]]*(#|$)/ { next }
			!($1 in n) && !($2 in d)' "$src" "$dst" > "$dst.rago"
		cat "$src" >> "$dst.rago"
		mv -f "$dst.rago" "$dst"
	else
		cp "$src" "$dst"
	fi
	chmod 600 "$dst"
}
