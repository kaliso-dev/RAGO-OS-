---
type: module
tags: [module, phase-B]
maj: 2026-11-12
statut: À FAIRE
---
# M8 Optimisation switch

> Phase B. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Rendre la bascule la plus rapide possible et la faire paraître instantanée.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/bin/rago-fastboot-profile.sh` — auto-tuning du POST (MCR/DTRR/Ultra Fast Boot)
- `(config)` — hibernation LZ4/zstd multi-thread, splash UEFI BGRT
- `tests/bench_switch.sh` — chronométrage des 3 postes

**Ce qu'il fait.** Auto-POST : détecte le chipset, active/documente Memory Context Restore + DDR Training Runtime Reduction + Ultra Fast Boot (POST 45-90s → ~1-5s). Hibernation lz4/zstd, threads 5-6, swap NVMe dédié. Splash UEFI couvrant le POST. R&D (off par défaut) : resume d'image Windows pré-cuite par jeu.

**Dépend de / relié à :** [[Fast OS Switch]], [[Loi physique du POST]], [[M6 Fast OS Switch]]

**Critère de test.** POST réduit mesuré ; resume rapide ; splash visible ; total consigné (cible ~6-13 s).

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M8). Détail : bible v7, module M8.
