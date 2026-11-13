---
type: carte
tags: [architecture]
maj: 2026-11-13
---
# Couche Proton

Retour à [[Architecture]]. Module : [[M2 Couche Proton]] (code écrit le 13/11, jamais testé sur matériel). Code : `host/setup_proton_layer.sh`, `host/proton/`, `host/gamescope/`, `host/gamemode/`, `host/mangohud/`.

La couche 1 : le jeu natif Linux d'élite. Steam (+ Proton-GE épinglé), Heroic (Epic/GOG), Lutris en option. Session **gamescope** plein écran console-like (VRR/HDR, temps réel `--rt`, tearing en jeu), Steam en Big Picture. gamemode (réduit à ce qui ne se bat avec aucun module) + MangoHud. Runtimes Proton EAC/BattlEye de Valve (débloquent les jeux dont le dev a activé l'anti-triche Linux) ; rien n'est caché ni contourné.

**Chaîne de lancement d'un jeu** (option Steam `rago-launch %command%`, posée automatiquement) :
`rago-launch` (caches de shaders par GPU) → `rago-profiled launch` ([[M14 Profils par jeu]] : profil par-dessus la base [[M1 Tuning hôte]]) → `rago-sched-hint run` (hint de [[Noyau et ordonnanceur]], [[M0 Noyau scx_rago]]) → `gamemoderun` → `mangohud` → le jeu. Si un maillon manque, le jeu se lance quand même.

**Partage des rôles** (pour qu'aucun réglage ne se batte) : gouverneur CPU = M14 / M1 ; cœurs et priorités = M0 ; horloges GPU = [[M9 GPU]] ; gamemode ne garde que la priorité d'E/S, l'écran de veille et le signal « GameMode actif » (règle polkit).

**Anti-stutter** : cache de shaders par GPU et par jeu, pré-chauffage Fossilize en fond (pause pendant les jeux, refait si le pilote change). Emplacement : `~/.local/share/rago/shader-cache` (pourra aller sur la bibliothèque partagée de [[M7 Bibliothèque partagée]]).

La majorité des jeux passent par ici ; seuls les anti-triche stricts vont au [[Fast OS Switch]].
