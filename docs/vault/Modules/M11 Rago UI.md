---
type: module
tags: [module, phase-C]
maj: 2026-11-14
statut: À FAIRE
---
# M11 Rago UI

> Phase C. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Le launcher unique : bibliothèque, lancement, profils, switch.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `rago-ui/src-tauri/` — backend Rust Tauri v2
- `rago-ui/src/App.tsx` — frontend React

**Ce qu'il fait.** Tauri v2. Commandes : launch_native_game (Proton + profil M14 + hint M0), launch_switch_game (switch M6 + profil sécurité), install_game (M7), get_system_stats. Écrans : Dashboard, Bibliothèque unifiée (Proton + switch), Réglages (mode de switch, profils). Thème sombre/néon.

**Accroche prête (M14, 13/11).** `launch_native_game` → `rago-profiled launch --id <jeu> -- <commande>` ; `launch_switch_game` → `rago-profiled prepare-switch --id <jeu>` avant le switch ; écran des profils → `rago-profiled list`, `show --json`, `validate` (profils locaux dans `/etc/rago/profiles/`).

**Accroche prête (M7, 14/11).** `install_game` → `rago-library install steam|epic|riot <id> [--name <nom>]` (requête prise au prochain démarrage du micro-Windows) ; bibliothèque Windows → `rago-library list --json` (jeux de RAGO-LIB, fiches écrites par Windows) et `status --json` (état de Windows, requêtes, résultats) ; `cancel` / `forget` pour une requête. Commandes en root : l'UI passera par un service ou polkit (à décider). Codes de sortie : 0 fait, 1 erreur, 2 refusé, 3 lecture seule (doute). Voir [[M7 Bibliothèque partagée]].

**Dépend de / relié à :** [[M2 Couche Proton]], [[M6 Fast OS Switch]], [[M7 Bibliothèque partagée]], [[M14 Profils par jeu]], [[M0 Noyau scx_rago]]

**Critère de test.** cargo tauri build OK ; lance Proton + switch ; profils visibles ; bibliothèque unifiée.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M11). Détail : bible v7, module M11.
