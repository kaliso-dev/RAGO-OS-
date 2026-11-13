---
type: module
tags: [module, phase-A]
maj: 2026-11-13
statut: EN COURS
---
# M3 Chiffrement LUKS

> Phase A. Statut : **EN COURS** — code écrit le 13/11/2026, testé sur disques virtuels seulement (conteneur, loop devices avec TPM émulé, VM qemu UEFI + TPM émulé) ; **jamais testé sur vrai matériel**. Branche `claude/project-thread-ab69fn`, PR #6 vers `main`, à relire. **En attente de matériel** : le vrai déverrouillage automatique par un TPM matériel (fTPM AMD / PTT Intel) et un vrai firmware, la passphrase tapée au vrai clavier au démarrage, mkinitcpio réel, le débit et les FPS. Retour à [[Projet]], carte [[Architecture]], voir [[Sécurité et boot]].

**Objectif.** Disque hôte chiffré, déverrouillé par le TPM au démarrage si le firmware et Secure Boot sont ceux de l'enrôlement, sinon par une passphrase de secours **obligatoire** ; compatible avec l'hibernation du [[Fast OS Switch]] et les deux slots de [[M4 Updates A-B]].

## Fichiers de code (dans `kaliso-dev/rago-os-`)
- `host/setup_secure_encryption.sh` — le script (installé en `/usr/lib/rago/` avec la commande `/usr/bin/rago-encryption`). Commandes : `check`, `format`, `open`, `close`, `enroll-tpm`, `reseal`, `install`, `verify` / `status`, `tpm-check`, `cmdline`, `deps`. Réglages enregistrés dans `/etc/rago/encryption.conf`.
- `host/lib/rago_crypt_lib.sh` — fonctions pures (lecture de `luksDump`, crypttab, fstab, HOOKS mkinitcpio, conf dracut, PCR, disque virtuel ou réel…), réutilise `host/lib/rago_host_lib.sh` de M1.
- `host/dracut/91rago-crypttab/module-setup.sh` — module dracut : met dans l'initramfs **seulement** les volumes du démarrage (`/etc/crypttab.initramfs`).
- `host/systemd/rago-tpm-check.service` + `host/systemd/rago-tpm-check.timer` — 1 min après le démarrage, regarde si le TPM ouvre encore les volumes ; écrit `/run/rago/encryption-status` (pour [[M11 Rago UI]]) et le journal.
- Tests : `host/tests/run_m3_tests.sh` (lance tout : `--loop`, `--vm` en root), `host/tests/test_crypt_lib.sh`, `host/tests/test_encryption_sysroot.sh`, `host/tests/test_encryption_loop.sh`, `host/tests/vm/run_m3_vm_test.sh` (+ `host/tests/vm/m3_vm_guest.sh`, `host/tests/vm/m3_serial_agent.py`), sorties réelles de cryptsetup / systemd-cryptenroll dans `host/tests/fixtures/m3/`.

## Ce qu'il fait
- **Volumes** (créés par l'installateur [[M12 Installateur]]) : `rago-a` et `rago-b` (racine de chaque slot), `rago-swap` (swap d'hibernation). Au démarrage, la racine s'ouvre toujours sous le nom `rago-root` : chaque slot a **sa** crypttab qui nomme **son** volume. La ligne de commande du noyau est donc la même pour les deux slots : `root=/dev/mapper/rago-root resume=/dev/mapper/rago-swap`.
- **`check`** (n'écrit rien) : AES-NI, AVX2 (et VAES), pilote `xts(aes)` du noyau — **avertit** si le chiffrement n'est pas accéléré ; TPM 2.0, PCR 0 / 7 vraiment mesurés par le firmware, UEFI, Secure Boot, outils, générateur d'initramfs, clavier (`KEYMAP`).
- **`format`** : `luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --pbkdf argon2id`, étiquette selon le rôle, passphrase de secours posée dans l'emplacement 0 et vérifiée ; pour le swap, `mkswap` dedans. Refuse toujours (même avec `--yes`) un disque monté, un swap actif, un volume ouvert, un disque entier qui a des partitions ; `--virtual-only` (tests) refuse tout ce qui n'est pas loop / virtio / QEMU. Passphrase : 12 caractères au moins, jamais dans les arguments ni les journaux, fichier en mode 600 obligatoire ; accents acceptés avec un avertissement (clavier QWERTY au démarrage sans `KEYMAP`).
- **`enroll-tpm` / `reseal`** : `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 --wipe-slot=tpm2` (un seul enrôlement TPM, l'ancien est remplacé). **Jamais le TPM seul** : refuse un volume sans passphrase de secours, vérifie avant et après que la passphrase ouvre toujours le volume, refuse des PCR jamais mesurés (le TPM ne protégerait rien ; `--allow-zero-pcrs` pour forcer), note les PCR de l'enrôlement (`/var/lib/rago/encryption/pcrs-at-enroll`). **Avertit du risque PCR 7** à chaque enrôlement.
- **`install`** : `/etc/crypttab` (`tpm2-device=auto,discard,no-read-workqueue,no-write-workqueue,x-initrd.attach`, entrées du joueur gardées, même volume sous un autre nom retiré, jamais `swap` / `tmp` / fichier de clé), `/etc/crypttab.initramfs` (volumes du démarrage seulement), swap `/dev/mapper/rago-swap` dans `/etc/fstab` (priorité 10, sous le zram de [[M1 Tuning hôte]]), initramfs : **dracut** (`/etc/dracut.conf.d/90-rago-encryption.conf` : systemd, crypt, systemd-cryptsetup, tpm2-tss, resume, rago-crypttab, i18n si clavier) ou **mkinitcpio** (`/etc/mkinitcpio.conf.d/90-rago-encryption.conf` : HOOKS systemd + sd-encrypt, keyboard avant autodetect, sd-vconsole), initramfs-tools refusé (pas de TPM2 : passer à dracut) ; ligne de commande dans `/etc/rago/kernel.conf` de [[M0 Noyau scx_rago]] (`root=` dans `RAGO_CMDLINE`, `resume=` dans `RAGO_CMDLINE_EXTRA`, l'ancienne ligne sauvegardée) ; outil + minuterie `rago-tpm-check`. Sauvegarde les fichiers d'origine (une fois). Idempotent.
- **`verify`** : volumes (LUKS2, aes-xts-plain64, 512 bits, argon2id, sha512, passphrase de secours présente — alarme « DANGER » sinon —, TPM enrôlé sur les bons PCR, le TPM ouvre-t-il le volume **maintenant**), crypttab, crypttab de l'initramfs, contenu réel de l'initramfs (systemd-cryptsetup, TPM2, dm-crypt, resume, crypttab), ligne de commande, racine et swap montés depuis les volumes chiffrés, resume, hibernation possible avec le noyau en marche (sinon : noyau verrouillé / lockdown, le [[Fast OS Switch]] en a besoin), swap non chiffré actif, PCR changés depuis l'enrôlement, Secure Boot. Dans le chroot de l'installateur, racine / swap / hibernation sont laissés au premier démarrage ; juste après `install`, ce qui attend la nouvelle ligne de commande est « redémarrage en attente », pas un échec. Code 0 = bon, 1 = échec, 3 = redémarrage en attente.
- **`tpm-check`** (minuterie au démarrage) : `a=ok|refused|untestable|not-enrolled` par volume (`b=`, `swap=` de même) ; si le TPM refuse, journal : « sudo rago-encryption reseal ».
- **`open` / `close`** : `open` passe par le TPM comme au démarrage (`systemd-cryptsetup attach`), ou par la passphrase (`--passphrase-file`) ; `close` attend udev et réessaie, et si le volume reste utilisé, dit par quoi (volume posé dessus, ou montage resté dans l'espace privé d'un service).
- **`cmdline`** (pour [[M4 Updates A-B]]) : les paramètres du noyau d'un slot.

## Risque PCR 7 (et PCR 0)
Le TPM ne rend la clé que si le firmware (PCR 0) et l'état Secure Boot (PCR 7 : activation, clés PK / KEK / db, liste dbx, autorités qui ont vérifié le démarrage) sont ceux de l'enrôlement. Une mise à jour du BIOS / UEFI, de la dbx (Windows Update peut la faire, voir [[M5 Micro-Windows]]), l'activation de Secure Boot (et sans doute un changement de clé MOK, mesurée par shim) les change : au démarrage suivant, la **passphrase de secours** est demandée (rien n'est perdu), puis `sudo rago-encryption reseal`. Prouvé en VM (démarrage 5 ci-dessous). Sans passphrase de secours, un TPM qui refuse = données perdues : c'est pourquoi elle est obligatoire. Une nouvelle initramfs ne change ni PCR 0 ni PCR 7 (vu en VM : le slot B démarre avec une autre initramfs, sans passphrase) ; un nouveau noyau signé par la même clé MOK non plus, en principe (PCR 7 mesure la clé qui a vérifié, pas le fichier ; à vérifier sur la machine). Donc pas de `reseal` après les mises à jour de [[M4 Updates A-B]].

## Ce que le TPM protège, et ce qu'il ne protège pas encore
- **Protège** : disque sorti de la machine (illisible ailleurs), démarrage d'un autre système, Secure Boot coupé ou clés changées (PCR 7), firmware changé (PCR 0) : dans tous ces cas, il faut la passphrase.
- **Ne protège pas encore** : quelqu'un **devant la machine** qui modifie la ligne de commande au menu systemd-boot (éditeur actif par défaut) ou remplace l'initramfs (fichier non signé sur l'ESP, entrée systemd-boot de M0) : PCR 0 et 7 ne changent pas, le TPM rend la clé. Correctif hors de M3 : noyau + initramfs + ligne de commande dans une seule image UKI signée par la clé MOK et éditeur coupé ([[M0 Noyau scx_rago]] / [[M4 Updates A-B]]), ou ajouter des PCR (9, 12) au prix d'un `reseal` à chaque mise à jour. **À DÉCIDER** ([[Questions ouvertes]]).

## Utilisation (installateur M12, puis la machine)
1. `setup_secure_encryption.sh check`.
2. `format --device <part> --role root-a|root-b|swap --passphrase-file F --yes` (une fois par volume).
3. `open --device <slot A> --name rago-root --passphrase-file F`, créer le système de fichiers, copier le système, puis **dans le chroot** du nouveau système : `install --root-device … --other-slot-device … --swap-device …` (régénère l'initramfs).
4. `enroll-tpm --root /mnt --passphrase-file F` (ou plus tard sur la machine : `sudo rago-encryption enroll-tpm`).
5. `kernel/build_rago_kernel.sh bootloader` (M0) pour reprendre la nouvelle ligne de commande, redémarrer, `sudo rago-encryption verify`.
Slot B (fait par [[M4 Updates A-B]] depuis le système en marche) : `open` du volume B, copie, puis dans son chroot `install --slot b --root-device <B> --other-slot-device <A> --swap-device …`.

## Ce que M3 demande aux autres modules
- [[M4 Updates A-B]] : une initramfs **par slot** (chacune porte la crypttab de son slot) ; la ligne de commande reste la même.
- [[M6 Fast OS Switch]] : le resume vient de `resume=/dev/mapper/rago-swap`, déjà dans la ligne de commande ; le swap est ouvert par le TPM dans l'initramfs avant le resume (prouvé en VM).
- [[M11 Rago UI]] : lire `/run/rago/encryption-status` (`a=ok b=ok swap=ok`, ou `refused` : proposer le `reseal`).
- [[M12 Installateur]] : suivre « Utilisation » ci-dessus ; la passphrase passe par un fichier en mode 600 (jamais en argument). Monter le système cible et faire le chroot **dans un espace de montage privé** (`unshare --mount --propagation private`) : sinon systemd-udevd et systemd-logind reçoivent une copie de `/mnt` et de ses sous-montages, qu'un démontage ne retire pas toujours, et le volume ne se ferme plus (vu dans la VM ; `close` dit alors où il est encore monté).

## Tests (13/11, sans matériel, disques virtuels seulement)
- `test_crypt_lib.sh` : **160/160** (fonctions pures ; sorties réelles de cryptsetup 2.7 / 2.8.4 et systemd-cryptenroll 255 / 259 en fixtures).
- `test_encryption_sysroot.sh` : **168/168** sans root ni disque — install dans de fausses racines dracut et mkinitcpio, slots A et B, avec et sans swap, sans crypttab ni fstab, idempotence, sauvegardes, refus, `verify` qui repère une crypttab dangereuse (option `swap`, fichier de clé, sans `tpm2-device`, mauvais slot) ou des HOOKS cassés par un drop-in du joueur, module dracut appelé comme dracut l'appelle (normal et hostonly), `check` sur un faux /sys et /proc (AES-NI / AVX2 absents, PCR jamais mesurés, BIOS legacy, Secure Boot inactif…).
- `test_encryption_loop.sh` : **116/116** en root sur des loop devices jetables + TPM émulé swtpm : vrai `luksFormat` (paramètres relus dans l'en-tête), règles de la passphrase, refus, enrôlement TPM qui garde la passphrase, refus PCR jamais mesurés / mauvaise passphrase / volume sans passphrase, install sur les vrais volumes (slot B reconnu par son étiquette), verify, PCR 7 puis PCR 0 changés repérés, reseal (nouvelle politique TPM).
- `run_m3_vm_test.sh` : VM qemu UEFI (OVMF) + TPM 2.0 émulé vu par le noyau (CRB), 5 disques virtio jetables, Ubuntu 26.04 (noyau 7.0, systemd 259, cryptsetup 2.8.4, dracut 110), 6 démarrages — **90/90** au 3e passage : installateur (format, install dans le chroot avec le vrai dracut, enroll-tpm sur le TPM du noyau) ; racine **et** swap ouverts par le TPM **sans passphrase** (démarrages 2, 3, 4, 6) ; hibernation vers le swap chiffré puis reprise de la même session (le swap est ouvert par le TPM avant le resume) ; slot B avec sa propre crypttab et sa propre initramfs ; **Secure Boot activé** : PCR 7 change, le TPM refuse, la **passphrase de secours** est demandée une seule fois (systemd la réutilise pour les deux volumes du démarrage, racine et swap), `tpm-check` et `verify` le signalent, `reseal`, puis de nouveau sans passphrase ; `close` qui dit qu'un volume est resté monté chez systemd-udevd / systemd-logind. Les deux premiers passages (80/83, 85/87) ont trouvé 3 défauts du script et 2 du test.
- Limites de la VM : base Ubuntu et dracut (pas Arch ni mkinitcpio) ; noyau démarré directement par qemu (pas shim + systemd-boot) ; noyau Ubuntu verrouillé sous Secure Boot, donc hibernation testée Secure Boot inactif ; passphrase tapée sur la console série, pas au clavier.
- Ces tests ont trouvé et fait corriger 13 défauts du script (dont : arrêt silencieux de `format` sur un disque vide sous `set -e`, test de passphrase qui réussissait grâce au TPM sans lire la passphrase, toute la crypttab copiée dans l'initramfs, `verify` en échec dans le chroot de l'installateur, `close` bloqué sans explication).

## En attente de matériel / à vérifier
- Déverrouillage par un **vrai TPM** (fTPM / PTT) et un vrai firmware (mesures PCR 0 / 7 réelles et stables, mise à jour du BIOS, dbx).
- **Clavier au démarrage** : passphrase tapée au vrai clavier (disposition `KEYMAP`, module i18n de dracut / sd-vconsole) ; en VM elle est tapée sur la console série.
- **mkinitcpio** (Arch / base Rago) : testé seulement en fausse racine (Arch inaccessible depuis l'environnement de Claude). À VÉRIFIER sur la base Rago.
- Hibernation avec Secure Boot actif sur le vrai noyau Rago signé (voir [[Questions ouvertes]]).
- Débit du chiffrement (AES-NI / VAES) et FPS inchangés : critère « FPS inchangé » à mesurer sur la machine.
- **Sur la machine de test, seulement sur le SSD de test** (formater efface le volume) : `check` d'abord, puis le chemin « Utilisation » ; garder la passphrase de secours notée à part.

**Dépend de / relié à :** [[Sécurité et boot]], [[M0 Noyau scx_rago]] (ligne de commande, `kernel.conf`), [[M1 Tuning hôte]] (zram au-dessus du swap), [[M4 Updates A-B]] (une crypttab et une initramfs par slot), [[M6 Fast OS Switch]] (swap chiffré ouvert avant le resume), [[M12 Installateur]], [[M11 Rago UI]] (état du TPM).

**Critère de test.** auto-unlock si intègre ; fallback passphrase ; FPS inchangé.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M3). Détail : bible v7, module M3.
