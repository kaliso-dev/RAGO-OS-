---
type: module
tags: [module, phase-C]
maj: 2026-11-13
statut: À FAIRE
---
# M13 Build ISO

> Phase C. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Compiler l'ISO installable Rago (sans Windows — BYOL à l'install).

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `iso/Rago_ISO_Builder/build_rago_iso.sh` — build archiso
- `profile/packages.x86_64` — paquets
- `airootfs/` — système de fichiers cible + unités

**Ce qu'il fait.** Base archiso. Paquets : noyau Rago, steam, gamescope, proton-ge, rust, cryptsetup, tpm2-tools, sbsigntools, systemd-boot, ntfs3, installateur. hardware_check : TPM 2.0 + UEFI/Secure Boot. L'ISO ne contient PAS Windows.

**À installer pour M14 (13/11).** `/usr/bin/rago-profiled`, `host/systemd/rago-profiled.service` (activé), `profiles/community/` → `/usr/share/rago/profiles/`, `/etc/rago/profiles/`, `/usr/lib/rago/hooks/` : voir `daemons/rago-profiled/install.sh`.

**Pour M4 (13/11).** Paquets : `systemd-ukify` (avec python-pefile), systemd-boot et son systemd-stub, `sbsigntools`, `rsync`, `openssl`, `tpm2-tools`. `rago-update` (`host/manage_atomic_updates.sh`) se met en place sur la machine installée, après M0 + M3 (`setup`). Plus tard, les mises à jour par image (`rago-update apply --image`) attendent une archive tar signée d'une racine, produite ici ; la clé qui la signe n'est pas décidée ([[Questions ouvertes]]). Détail : [[M4 Updates A-B]].

**Dépend de / relié à :** [[M12 Installateur]], [[Architecture]], [[M4 Updates A-B]]

**Critère de test.** ISO boote, hardware_check OK, installateur se lance.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M13). Détail : bible v7, module M13.
