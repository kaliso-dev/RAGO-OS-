---
type: module
tags: [module, phase-B]
maj: 2026-11-12
statut: À FAIRE
---
# M6 Fast OS Switch

> Phase B. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** La bascule vers le micro-Windows : rapide et fluide, sans jamais voir Windows.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/bin/rago-switch-to-windows.sh` — écrit le jeu, one-shot, hibernate
- `windows/rago-shell/` — shell Winlogon : lance le jeu, surveille, retour
- `(config)` — hibernation/resume, entrées systemd-boot, partition RAGO-COMM

**Ce qu'il fait.** Design asymétrique (Windows sans état, one-shot auto-consommé). Deux modes (Rapide / Session préservée). Continuité visuelle (gel de frame + splash UEFI de [[M8 Optimisation switch]]). Pré-conditionnement GPU + warm reset. Fast Startup Windows off ; Linux ne monte pas le NTFS (comm FAT32).

**Dépend de / relié à :** [[Fast OS Switch]], [[M0 Noyau scx_rago]], [[M3 Chiffrement LUKS]], [[M5 Micro-Windows]], [[M8 Optimisation switch]], [[Loi physique du POST]]

**Critère de test.** clic → jeu plein écran sans écran noir ni login ; fermeture → session Rago restaurée ; reboot inattendu → Linux.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M6). Détail : bible v7, module M6.
