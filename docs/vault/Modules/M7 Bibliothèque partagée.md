---
type: module
tags: [module, phase-B]
maj: 2026-11-12
statut: À FAIRE
---
# M7 Bibliothèque partagée

> Phase B. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Gérer/installer ses jeux Windows depuis l'UI Rago ; le micro-Windows les lance au native speed.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/bin/rago-library.sh` — montage ntfs3 de RAGO-LIB côté Linux
- `windows/rago-agent/` — agent de finalisation/lancement côté Windows

**Ce qu'il fait.** Partition NTFS RAGO-LIB partagée (Linux écrit ntfs3, Windows lit natif, jamais simultané). Clients Steam/Epic/Riot côté Windows. L'UI écrit la requête dans RAGO-COMM ; l'agent Windows installe une fois (prérequis/registre) et met en cache.

**Dépend de / relié à :** [[M6 Fast OS Switch]], [[M5 Micro-Windows]], [[M11 Rago UI]]

**Critère de test.** install depuis l'UI → finalisé → lancement direct au switch.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M7). Détail : bible v7, module M7.
