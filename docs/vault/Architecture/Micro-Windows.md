---
type: carte
tags: [architecture]
maj: 2026-11-12
---
# Micro-Windows

Retour à [[Architecture]]. Module : [[M5 Micro-Windows]]. Code : `windows/`.

Windows réduit à un **moteur de jeu invisible** : pas de bureau, pas de login, démarre direct sur le jeu. Cibles **RAM idle ~300-500 Mo, disque ~2-3,5 Go, boot ~2-4 s**. Base **Windows 11 IoT Enterprise LTSC 25H2** (BYOL : ISO fournie par l'utilisateur).

**Méthode** : ablation DISM offline (`windows/compile_micro_engine.ps1`) — purge agressive du WinSxS (non-serviçabilité assumée), services non critiques coupés, shell Winlogon remplacé par `rago-shell`, services anti-triche forcés en automatique. `autounattend.xml` : AutoLogon silencieux, aucun compte Microsoft, aucun écran de connexion.

**À garder activés** (exigés par l'anti-triche moderne) : Secure Boot, TPM 2.0, **VBS, HVCI, IOMMU** → voir [[Vanguard On-Demand]]. Plus noyau NT, WDDM/DirectX, pilote GPU, .NET, VC++, réseau.

**Le mur** : pas de « Windows de quelques Mo » — en dessous de ce qui fait tourner jeu + anti-triche, ça casse.

Relié à : [[Fast OS Switch]], [[Vanguard On-Demand]], [[Sécurité et boot]].
