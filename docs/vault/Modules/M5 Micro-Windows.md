---
type: module
tags: [module, phase-B]
maj: 2026-11-12
statut: À FAIRE
---
# M5 Micro-Windows

> Phase B. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Windows réduit à un moteur de jeu invisible, aligné sur l'anti-triche moderne.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `windows/compile_micro_engine.ps1` — ablation DISM offline
- `windows/autounattend.xml` — install sans surveillance, AutoLogon silencieux

**Ce qu'il fait.** Base Win 11 IoT LTSC 25H2 (BYOL). Purge WinSxS agressive, services coupés, shell = rago-shell, services anti-triche forcés. GARDE Secure Boot/TPM/VBS/HVCI/IOMMU ([[Vanguard On-Demand]]) + noyau NT/DirectX/.NET/VC++/réseau. Deux profils de sécurité (compat max / perf) pilotés par [[M14 Profils par jeu]].

**Dépend de / relié à :** [[Micro-Windows]], [[Vanguard On-Demand]], [[M6 Fast OS Switch]], [[M14 Profils par jeu]]

**Critère de test.** RAM idle ~300-500 Mo ; pas d'explorer.exe ; un JEU RÉEL + son anti-triche tournent.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M5). Détail : bible v7, module M5.
