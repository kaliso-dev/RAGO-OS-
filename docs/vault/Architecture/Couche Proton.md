---
type: carte
tags: [architecture]
maj: 2026-11-12
---
# Couche Proton

Retour à [[Architecture]]. Module : [[M2 Couche Proton]]. Code : `host/setup_proton_layer.sh`, `host/gamescope/`.

La couche 1 : le jeu natif Linux d'élite. Steam (+ Proton-GE), Heroic (Epic/GOG), Lutris. Session **gamescope** plein écran console-like (VRR/HDR, temps réel, tearing en jeu). gamemode + MangoHud. Runtimes Proton EAC/BattlEye activés (débloquent les jeux dont le dev a activé l'anti-triche Linux).

Au lancement d'un jeu, applique son [[M14 Profils par jeu]] et appelle le hint de [[Noyau et ordonnanceur]]. Pré-chauffage du cache de shaders (anti-stutter).

La majorité des jeux passent par ici ; seuls les anti-triche stricts vont au [[Fast OS Switch]].
