---
type: pilotage
tags: [pilotage]
maj: 2026-11-14
---
# Prochaines étapes

Retour à [[Projet]]. Voir [[État actuel]].

Ordre de build (un module à la fois, testé avant le suivant) :
1. **[[M0 Noyau scx_rago]]** — noyau custom signé + ordonnanceur. Le fondement. **Code écrit (13/11), en attente du test sur matériel.**
2. [[M1 Tuning hôte]] — **code écrit (13/11), testé en VM, en attente du test sur matériel** — puis [[M14 Profils par jeu]] (tôt, car M2/M5 l'utilisent) — **code écrit (13/11), testé en conteneur, sur le vrai noyau du conteneur et en VM ; hook M5 fourni le 14/11, hook M9 en attente ; en attente du test sur matériel.**

Décision du 13/11 : tant qu'il n'y a pas de machine de test, on avance sur les modules testables sans matériel dédié, un à la fois ; chacun reste « jamais testé sur matériel » jusqu'au test de Sofiene.
3. [[M2 Couche Proton]] — **code écrit (13/11), testé en conteneur et en chroot Ubuntu 25.10 avec les vrais paquets ; Proton-GE / Heroic à épingler ; affichage, VRR, HDR, FPS en attente du test sur matériel** — · [[M3 Chiffrement LUKS]] — **code écrit (13/11), testé sur disques virtuels seulement (loop devices, VM UEFI avec TPM émulé) ; vrai TPM, clavier au démarrage, mkinitcpio réel et FPS en attente du test sur matériel** — · [[M4 Updates A-B]] — **code écrit (13/11), testé sans matériel (fausses racines, loop devices avec TPM émulé, VM UEFI avec Secure Boot actif et TPM émulé) ; fusionné dans `main` (PR #7, 13/11) ; vrai TPM / firmware, shim, noyau Rago dans l'UKI et mkinitcpio en attente du test sur matériel**.

Ordre retenu le 14/11 (Sofiene) : **M5 → M7 → M6 → M8 → M9 → M10 → M11 → M12 → M13** — « M7 passe AVANT M6 : le switch doit être bâti contre une bibliothèque partagée déjà figée ».
4. [[M5 Micro-Windows]] — **code écrit (14/11) ; côté Linux testé (conteneur, VM sur deux noyaux) ; côté Windows jamais exécuté (scripts Windows, conteneur Linux) ; ablation réelle + boot + jeu réel + taille finale en attente de l'ISO (Windows 11 Pro 25H2+) et de la machine ; PR vers `main` à relire par Sofiene avant M7.**
5. [[M7 Bibliothèque partagée]] (prochain module, après la relecture de la PR de M5) · [[M6 Fast OS Switch]] · [[M8 Optimisation switch]].
6. [[M9 GPU]] · [[M10 Télémétrie]] · [[M11 Rago UI]] · [[M12 Installateur]] · [[M13 Build ISO]].

Les modules durs (R&D réelle, prévoir du débogage matériel) : [[M0 Noyau scx_rago]], [[M5 Micro-Windows]], [[M6 Fast OS Switch]].
