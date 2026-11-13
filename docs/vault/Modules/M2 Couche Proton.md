---
type: module
tags: [module, phase-A]
maj: 2026-11-13
statut: À FAIRE
---
# M2 Couche Proton

> Phase A. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Jeu natif Linux d'élite (Proton), avec les accroches profils et anti-stutter.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/setup_proton_layer.sh` — install/réglage Steam/Proton-GE/Heroic/Lutris
- `host/gamescope/rago-session.sh` — session gamescope console-like

**Ce qu'il fait.** Steam + Proton-GE épinglé, Heroic, runtimes EAC/BattlEye. Session gamescope plein écran (VRR/HDR, --rt, tearing). gamemode + MangoHud. Au lancement : applique le profil [[M14 Profils par jeu]] + hint [[Noyau et ordonnanceur]]. Pré-chauffage cache shaders.

**Accroche prête (M14, 13/11).** Le hook de lancement = `rago-profiled launch -- %command%` (option de lancement Steam) : profil + hint M0 en une commande. À coordonner : gamemode ne doit pas reprendre la main sur le gouverneur ([[Questions ouvertes]]).

**Dépend de / relié à :** [[Couche Proton]], [[M0 Noyau scx_rago]], [[M14 Profils par jeu]]

**Critère de test.** jeu Proton plein écran ; MangoHud ; profil appliqué ; shaders pré-chauffés.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M2). Détail : bible v7, module M2.
