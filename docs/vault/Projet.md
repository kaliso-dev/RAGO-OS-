---
type: index
tags: [index]
maj: 2026-11-14
---
# Rago OS : le projet

> **Nouveau Claude ? Lis cette note, puis [[État actuel]], puis [[Règles de travail]], puis [[Mettre à jour le vault]].**
> **Règle n°1 : ce vault est le cerveau du projet. Il doit correspondre en tout point à l'état réel. Avant de finir une tâche, suis [[Mettre à jour le vault]].**

Rago OS est un **système d'exploitation Linux pour joueurs**, à **deux couches** :
1. **Jeu natif** via Proton (la grande majorité des jeux Windows tournent directement).
2. **Fast OS Switch** : pour les jeux à anti-triche strict (Valorant, Fortnite, CoD…), bascule bare-metal vers un **micro-Windows** invisible (hibernation Linux → Windows démarre direct sur le jeu → retour dans la session Rago). **Pas de VM, pas de masquage.**

Différenciateur : **le seul OS où Linux est l'OS principal et où les jeux anti-triche s'ouvrent sans jamais voir Windows.** Voir [[Marché]] et [[Monétisation]].

Repo code : `kaliso-dev/rago-os-`. Plan détaillé : `docs/plan/` (bible + études). Décideur : Sofiene (17 ans).

## Les deux couches
| Couche | Pour quoi | Notes |
|---|---|---|
| Jeu natif (Proton) | la majorité des jeux | [[M2 Couche Proton]], [[Couche Proton]] |
| Fast OS Switch | jeux anti-triche | [[Fast OS Switch]], [[Micro-Windows]] |

Vue d'ensemble technique : [[Architecture]].

## Carte du vault
- **Pilotage** : [[État actuel]] · [[Prochaines étapes]] · [[Questions ouvertes]] · [[Journal]] · [[Décisions]]
- **Règles** : [[Règles de travail]] · [[Mettre à jour le vault]]
- **Architecture** : [[Architecture]] · [[Noyau et ordonnanceur]] · [[Fast OS Switch]] · [[Micro-Windows]] · [[Couche Proton]] · [[Sécurité et boot]] · [[Prérequis matériel]] · [[Loi physique du POST]]
- **Modules (le code, dans l'ordre de build)** : [[M0 Noyau scx_rago]] · [[M1 Tuning hôte]] · [[M14 Profils par jeu]] · [[M2 Couche Proton]] · [[M3 Chiffrement LUKS]] · [[M4 Updates A-B]] · [[M5 Micro-Windows]] · [[M7 Bibliothèque partagée]] · [[M6 Fast OS Switch]] · [[M8 Optimisation switch]] · [[M9 GPU]] · [[M10 Télémétrie]] · [[M11 Rago UI]] · [[M12 Installateur]] · [[M13 Build ISO]]
- **Recherche** : [[Vanguard On-Demand]] · [[Innovations avancées]]
- **Marketing** : [[Marché]] · [[Monétisation]]
- **Premium (roadmap)** : [[Rago Console coreboot]]

## Statuts utilisés dans les notes
CONFIRMÉ (vérifié dans une source primaire : code, git, test matériel) · DÉCIDÉ (décision datée de Sofiene) · À FAIRE · EN COURS · À VÉRIFIER · À DÉCIDER · R&D · OBSOLÈTE. **La décision la plus récente de Sofiene prime.**
