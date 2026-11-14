---
type: carte
tags: [architecture]
maj: 2026-11-14
---
# Prérequis matériel

Retour à [[Architecture]]. Détail : `docs/plan/Rago_OS_Pro_Build_Bible.md` (Partie 4).

**Machine cible / test** : UEFI + Secure Boot activable, TPM 2.0, NVMe, RAM ≥16 Go (32+ pour compiler le noyau). **1 seul GPU suffit** (plus de passthrough → le switch utilise le GPU en natif). **Portable OK.**

**Tester sans risque** : SSD externe (~50-60 €) pour installer Rago sans toucher le disque interne ; tout le non-matériel en VM jetable. Aucune machine louée ne teste tout (un cloud est une VM, ne fait pas le switch bare-metal).

**À fournir par l'utilisateur** : ISO **Windows 11 Pro 25H2 ou plus** (décision du 14/11), téléchargée chez Microsoft, et sa licence. BYOL : le client fournit son ISO/licence → Rago ne paie rien par client. Les éditions IoT LTSC ne sont plus la base (pas de LTSC 25H2, donc pas de Vanguard On-Demand ; licence prévue pour des appareils à usage fixe) : voir [[Micro-Windows]].

**Réglages du firmware pour le [[Micro-Windows]]** ([[M5 Micro-Windows]]) : UEFI, Secure Boot, TPM 2.0 (fTPM AMD / PTT Intel ; pour un compte Riot restreint, seul un fTPM convient), virtualisation (VT-x / SVM), IOMMU (VT-d / AMD-Vi). Une place libre sur le disque pour Windows.

À décider : un ou deux NVMe ([[Questions ouvertes]]).
