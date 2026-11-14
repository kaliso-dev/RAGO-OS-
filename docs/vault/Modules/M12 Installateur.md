---
type: module
tags: [module, phase-C]
maj: 2026-11-14
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

**Ce que les modules déjà codés lui demandent (13/11, 14/11).**
- [[M7 Bibliothèque partagée]] (14/11) : créer **RAGO-LIB** (GPT « Microsoft basic data », NTFS, étiquette `RAGO-LIB`, sans le bit « caché » ni « sans lettre ») à côté de RAGO-COMM ([[M5 Micro-Windows]]) ; installer `host/setup_library.sh install` ; monter une fois `rago-library mount` pour que le PARTUUID soit noté pour Windows (`RAGO-COMM\library\partition.json`) ; la lettre `L:` doit rester libre dans Windows. Taille : à décider avec Sofiene (les jeux y vivent).
- [[M3 Chiffrement LUKS]] : volumes `rago-a`, `rago-b`, `rago-swap` (`setup_secure_encryption.sh format`), install dans le chroot du système cible, monté dans un espace de montage privé ; passphrase par un fichier en mode 600.
- **TPM au premier démarrage**, pas depuis l'installateur : un jeton TPM pris pendant l'installation ne vaut que si l'installateur démarre par la même chaîne que le système installé (PCR 7), ce qui n'arrivera presque jamais (clé USB signée Microsoft / shim contre systemd-boot signé par la clé MOK de la machine). Vu dans la VM de [[M4 Updates A-B]] : refusé, passphrase demandée. Donc au premier démarrage : passphrase de secours demandée une fois, puis `sudo rago-update setup` (UKI signée, jetons TPM sur la vraie chaîne).
- [[M0 Noyau scx_rago]] + [[M4 Updates A-B]] : ESP montée en `/boot` (`RAGO_ESP`), systemd-boot installé puis signé et entrée `rago.conf` (`build_rago_kernel.sh bootloader`, avant M4 : en mode A/B il n'écrit plus `rago.conf`), clé MOK inscrite (MokManager) ; `rago-update setup` se lance sur la machine installée, démarrée par `rago.conf`.

**Dépend de / relié à :** [[M0 Noyau scx_rago]], [[M3 Chiffrement LUKS]], [[M4 Updates A-B]], [[M5 Micro-Windows]], [[M6 Fast OS Switch]], [[M13 Build ISO]]

**Critère de test.** clean OK ; migration → données réimportées ; micro-Windows construit depuis l'ISO ; boot Rago.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M12). Détail : bible v7, module M12.
