---
type: pilotage
tags: [pilotage]
maj: 2026-11-13
---
# Prochaines étapes

Retour à [[Projet]]. Voir [[État actuel]].

Ordre de build (un module à la fois, testé avant le suivant) :
1. **[[M0 Noyau scx_rago]]** — noyau custom signé + ordonnanceur. Le fondement. **Code écrit (13/11), en attente du test sur matériel.**
2. [[M1 Tuning hôte]] — **code écrit (13/11), testé en VM, en attente du test sur matériel** — puis [[M14 Profils par jeu]] (tôt, car M2/M5 l'utilisent).

Décision du 13/11 : tant qu'il n'y a pas de machine de test, on avance sur les modules testables sans matériel dédié, un à la fois ; chacun reste « jamais testé sur matériel » jusqu'au test de Sofiene. [[M2 Couche Proton]] attend son feu vert.
3. [[M2 Couche Proton]] · [[M3 Chiffrement LUKS]] · [[M4 Updates A-B]].
4. [[M5 Micro-Windows]] · [[M6 Fast OS Switch]] · [[M7 Bibliothèque partagée]] · [[M8 Optimisation switch]].
5. [[M9 GPU]] · [[M10 Télémétrie]] · [[M11 Rago UI]] · [[M12 Installateur]] · [[M13 Build ISO]].

Les modules durs (R&D réelle, prévoir du débogage matériel) : [[M0 Noyau scx_rago]], [[M5 Micro-Windows]], [[M6 Fast OS Switch]].
