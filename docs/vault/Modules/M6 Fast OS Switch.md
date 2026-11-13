---
type: module
tags: [module, phase-B]
maj: 2026-11-13
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

**Avec [[M4 Updates A-B]]** (code du 13/11) : l'entrée à usage unique de systemd-boot (`bootctl set-oneshot`) sert aussi à l'essai d'une mise à jour, et le crochet d'hibernation de M4 (`host/systemd/system-sleep/rago-update`) fait reprendre Linux sur la même entrée quand il n'a pas démarré par l'entrée par défaut ; il laisse en place une entrée à usage unique déjà choisie (celle de M6). Les deux se marchent dessus pendant un essai : à régler en codant M6, voir [[Questions ouvertes]].

**Dépend de / relié à :** [[Fast OS Switch]], [[M0 Noyau scx_rago]], [[M3 Chiffrement LUKS]], [[M5 Micro-Windows]], [[M8 Optimisation switch]], [[Loi physique du POST]]

**Critère de test.** clic → jeu plein écran sans écran noir ni login ; fermeture → session Rago restaurée ; reboot inattendu → Linux.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M6). Détail : bible v7, module M6.
