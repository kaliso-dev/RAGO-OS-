---
type: module
tags: [module, phase-C]
maj: 2026-11-12
statut: À FAIRE
---
# M11 Rago UI

> Phase C. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Le launcher unique : bibliothèque, lancement, profils, switch.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `rago-ui/src-tauri/` — backend Rust Tauri v2
- `rago-ui/src/App.tsx` — frontend React

**Ce qu'il fait.** Tauri v2. Commandes : launch_native_game (Proton + profil M14 + hint M0), launch_switch_game (switch M6 + profil sécurité), install_game (M7), get_system_stats. Écrans : Dashboard, Bibliothèque unifiée (Proton + switch), Réglages (mode de switch, profils). Thème sombre/néon.

**Dépend de / relié à :** [[M2 Couche Proton]], [[M6 Fast OS Switch]], [[M7 Bibliothèque partagée]], [[M14 Profils par jeu]], [[M0 Noyau scx_rago]]

**Critère de test.** cargo tauri build OK ; lance Proton + switch ; profils visibles ; bibliothèque unifiée.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M11). Détail : bible v7, module M11.
