---
type: module
tags: [module, phase-C]
maj: 2026-11-12
statut: À FAIRE
---
# M12 Installateur

> Phase C. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Installer Rago (depuis Windows ou Linux), clean ou migration, BYOL.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `installer/rago-installer` — installateur (Calamares ou custom)
- `installer/partition.sh` — partitionnement GPT
- `installer/migrate.sh` — sauvegarde + réimport des données
- `installer/build_micro_windows.sh` — construit le micro-Windows depuis l'ISO fournie

**Ce qu'il fait.** GPT : ESP, Rago A/B (LUKS), partition Windows native, RAGO-LIB (NTFS), RAGO-COMM (FAT32), partition données. Modes clean / migration. BYOL : demande l'ISO, construit via compile_micro_engine.ps1. Détecte 1 ou 2 NVMe.

**Dépend de / relié à :** [[M0 Noyau scx_rago]], [[M3 Chiffrement LUKS]], [[M4 Updates A-B]], [[M5 Micro-Windows]], [[M6 Fast OS Switch]], [[M13 Build ISO]]

**Critère de test.** clean OK ; migration → données réimportées ; micro-Windows construit depuis l'ISO ; boot Rago.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M12). Détail : bible v7, module M12.
