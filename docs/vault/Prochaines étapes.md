---
type: pilotage
tags: [pilotage]
maj: 2026-11-12
---
# Prochaines étapes

Retour à [[Projet]]. Voir [[État actuel]].

Ordre de build (un module à la fois, testé avant le suivant) :
1. **[[M0 Noyau scx_rago]]** — noyau custom signé + ordonnanceur. Le fondement.
2. [[M1 Tuning hôte]] puis [[M14 Profils par jeu]] (tôt, car M2/M5 l'utilisent).
3. [[M2 Couche Proton]] · [[M3 Chiffrement LUKS]] · [[M4 Updates A-B]].
4. [[M5 Micro-Windows]] · [[M6 Fast OS Switch]] · [[M7 Bibliothèque partagée]] · [[M8 Optimisation switch]].
5. [[M9 GPU]] · [[M10 Télémétrie]] · [[M11 Rago UI]] · [[M12 Installateur]] · [[M13 Build ISO]].

Les modules durs (R&D réelle, prévoir du débogage matériel) : [[M0 Noyau scx_rago]], [[M5 Micro-Windows]], [[M6 Fast OS Switch]].
