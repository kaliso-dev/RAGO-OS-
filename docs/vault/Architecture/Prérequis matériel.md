---
type: carte
tags: [architecture]
maj: 2026-11-12
---
# Prérequis matériel

Retour à [[Architecture]]. Détail : `docs/plan/Rago_OS_Pro_Build_Bible.md` (Partie 4).

**Machine cible / test** : UEFI + Secure Boot activable, TPM 2.0, NVMe, RAM ≥16 Go (32+ pour compiler le noyau). **1 seul GPU suffit** (plus de passthrough → le switch utilise le GPU en natif). **Portable OK.**

**Tester sans risque** : SSD externe (~50-60 €) pour installer Rago sans toucher le disque interne ; tout le non-matériel en VM jetable. Aucune machine louée ne teste tout (un cloud est une VM, ne fait pas le switch bare-metal).

**À fournir par l'utilisateur** : ISO Windows (Win 11 conso gratuite pour tester, ou IoT LTSC eval). BYOL : le client fournit son ISO/licence → Rago ne paie rien par client. Licence IoT LTSC prod ~90-295 $/appareil via distributeur agréé.

À décider : un ou deux NVMe ([[Questions ouvertes]]).
