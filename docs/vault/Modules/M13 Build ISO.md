---
type: module
tags: [module, phase-C]
maj: 2026-11-12
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

**Dépend de / relié à :** [[M12 Installateur]], [[Architecture]]

**Critère de test.** ISO boote, hardware_check OK, installateur se lance.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M13). Détail : bible v7, module M13.
