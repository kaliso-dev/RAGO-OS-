---
type: module
tags: [module, phase-A]
maj: 2026-11-12
statut: À FAIRE
---
# M1 Tuning hôte

> Phase A. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Régler l'hôte pour le jeu natif (sans isolation VM).

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/setup_host_tuning.sh` — script de tuning
- `host/tuned/rago-gaming/tuned.conf` — profil tuned
- `host/sysctl.d/99-rago.conf` — sysctl
- `host/udev/60-rago-iosched.rules` — scheduler I/O NVMe

**Ce qu'il fait.** tuned latency-performance, gouverneur performance, sysctl (max_map_count, swappiness, réseau), NVMe none/mq-deadline, zram, THP madvise (surchargée par [[M14 Profils par jeu]]). Pas d'isolation stricte de cœurs (scx_rago route le jeu).

**Dépend de / relié à :** [[M0 Noyau scx_rago]], [[Couche Proton]]

**Critère de test.** tuned-adm active = rago-gaming ; gouverneur performance ; 1% low MangoHud.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M1). Détail : bible v7, module M1.
