---
type: module
tags: [module, phase-A]
maj: 2026-11-12
statut: À FAIRE
---
# M0 Noyau scx_rago

> Phase A. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Le meilleur noyau possible pour le jeu, signé Secure Boot, avec un ordonnanceur informé par le launcher.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `kernel/build_rago_kernel.sh` — build reproductible (Clang/ThinLTO), paquet, install, signe, maj bootloader
- `kernel/config/rago-gaming.config` — config noyau documentée
- `kernel/scx/` — ordonnanceur scx_rago (fork scx_lavd)
- `host/bin/rago-sched-hint` — API hint launcher → BPF map
- `host/systemd/rago-scx.service` — chargement de scx au boot

**Ce qu'il fait.** Base ≥6.12 + patchset CachyOS, PREEMPT/1000Hz/MGLRU/ThinLTO/v3. Signature MOK (openssl/sbsign/mokutil). scx_rago reçoit du launcher les PID du jeu (thread de rendu) comme latency-critical, et route le jeu sur le CCD X3D / les P-cores. Filet EEVDF+BORE.

**Dépend de / relié à :** [[Noyau et ordonnanceur]], [[Sécurité et boot]], [[M11 Rago UI]], [[M14 Profils par jeu]]

**Critère de test.** uname = Rago ; SCHED_CLASS_EXT=y ; scx chargé ; cyclictest meilleur ; boot Secure Boot ON ; jeu taggé → bons cœurs.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M0). Détail : bible v7, module M0.
