---
type: module
tags: [module, phase-B]
maj: 2026-11-14
statut: À FAIRE
---
# M7 Bibliothèque partagée

> Phase B. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Gérer/installer ses jeux Windows depuis l'UI Rago ; le micro-Windows les lance au native speed.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/bin/rago-library.sh` — montage ntfs3 de RAGO-LIB côté Linux
- `windows/rago-agent/` — agent de finalisation/lancement côté Windows

**Ordre** : prochain module après [[M5 Micro-Windows]], **avant** [[M6 Fast OS Switch]] (décision du 14/11 : « M7 passe AVANT M6 : le switch doit être bâti contre une bibliothèque partagée déjà figée »).

**Déjà là grâce à M5** (code du 14/11) : la partition d'échange RAGO-COMM (FAT32, montée à la demande par `host/systemd/run-rago-comm.mount`, réglages `/etc/rago/rago-comm.conf`, côté Windows `C:\Rago\bin\RagoComm.psm1`), le shell provisoire `rago-shell.ps1` qui sait lancer un launcher ou un installateur, la tâche de démarrage `\Rago\Boot` (SYSTEM). Les jeux du Microsoft Store / Game Pass ne sont pas pris en charge (Store retiré par M5).

**Ce qu'il fait.** Partition NTFS RAGO-LIB partagée (Linux écrit ntfs3, Windows lit natif, jamais simultané). Clients Steam/Epic/Riot côté Windows. L'UI écrit la requête dans RAGO-COMM ; l'agent Windows installe une fois (prérequis/registre) et met en cache.

**Dépend de / relié à :** [[M5 Micro-Windows]], [[M6 Fast OS Switch]], [[M11 Rago UI]], [[Micro-Windows]]

**Critère de test.** install depuis l'UI → finalisé → lancement direct au switch.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M7). Détail : bible v7, module M7.
