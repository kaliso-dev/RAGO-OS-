---
type: recherche
tags: [recherche]
maj: 2026-11-14
---
# Vanguard On-Demand

Retour à [[Projet]]. Sources : recherche nov. 2026 (`docs/plan/Rago_Etude_Micro_Windows.md`), puis étude du 14/11 pour [[M5 Micro-Windows]] (blog Riot « Vanguard On-Demand » du 24/06/2026, pages d'aide Riot « Vanguard Pre-Check », « Enabling IOMMU », « Enabling Memory Integrity » ; pages d'aide Epic / EAC et BattlEye ; pages Microsoft). Lues par l'outil de lecture web de Claude, pas copiées mot à mot : à revérifier si Riot change ses pages.

**Découverte clé qui valide le modèle Rago.** Riot a sorti en 2026 un mode où le pilote de Vanguard **ne se charge plus au démarrage, mais au lancement du jeu, et se décharge à la fermeture** — si le PC passe le « Vanguard Pre-Check » (facultatif) : **Windows 11 25H2 ou plus**, mode UEFI + Secure Boot, TPM 2.0, **VBS + HVCI** (intégrité de la mémoire), **IOMMU activé dans le BIOS** (Intel VT-d, AMD IOMMU / AMD-Vi). L'éligibilité s'affiche dans l'application VGTray de Riot.

**Détails relevés le 14/11.**
- **25H2 minimum** parce que le rapport d'attestation des pilotes à l'exécution (pilotes et empreintes mesurés dans le TPM) n'existe que depuis cette version. Conséquence : **Windows 11 LTSC 2024 (24H2, build 26100) n'y a pas droit**, et il n'existe pas de LTSC 25H2. D'où la base « Windows 11 Pro 25H2 ou plus » (décision du 14/11).
- **TPM** : fTPM ou TPM discret suffisent ; **pour un compte restreint, seul un fTPM convient**.
- **IOMMU** : Riot vérifie qu'il est activé dans le BIOS ; il n'exige pas que msinfo32 affiche « Protection DMA du noyau ». M5 le lit comme « protection DMA » disponible pour VBS (À VÉRIFIER sur la machine).
- Vanguard **toujours actif** (au démarrage) reste possible sans Pre-Check, avec TPM 2.0 + Secure Boot.
- **EAC et BattlEye** ne demandent ni n'interdisent VBS / HVCI d'après leurs pages ; ils bloquent leur pilote quand la **protection de pile matérielle en mode noyau** (Isolation du noyau) est active. FACEIT, lui, exige l'intégrité de la mémoire. M5 ne touche pas à cette protection et l'affiche.

**Pourquoi ça compte** : c'est **exactement** le modèle du [[Fast OS Switch]] (on démarre dans le jeu, on joue, on quitte). L'industrie de l'anti-triche converge vers l'architecture de Rago. Conséquence directe : le [[Micro-Windows]] doit **garder ces protections activées**, pas les stripper.

Nuance : VBS/HVCI coûtent un peu de FPS et activent le blocklist de pilotes vulnérables → d'où les deux profils de sécurité (compat max / perf) de [[M14 Profils par jeu]], appliqués par [[M5 Micro-Windows]].
