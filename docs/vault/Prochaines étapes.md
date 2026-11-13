---
type: pilotage
tags: [pilotage]
maj: 2026-11-13
---
# Prochaines étapes

Retour à [[Projet]]. Voir [[État actuel]].

Ordre de build (un module à la fois, testé avant le suivant) :
1. **[[M0 Noyau scx_rago]]** — noyau custom signé + ordonnanceur. Le fondement. **Code écrit (13/11), en attente du test sur matériel.**
2. [[M1 Tuning hôte]] — **code écrit (13/11), testé en VM, en attente du test sur matériel** — puis [[M14 Profils par jeu]] (tôt, car M2/M5 l'utilisent) — **code écrit (13/11), testé en conteneur, sur le vrai noyau du conteneur et en VM ; hooks M9 / M5-M6 en attente ; en attente du test sur matériel.**

Décision du 13/11 : tant qu'il n'y a pas de machine de test, on avance sur les modules testables sans matériel dédié, un à la fois ; chacun reste « jamais testé sur matériel » jusqu'au test de Sofiene.
3. [[M2 Couche Proton]] — **code écrit (13/11), testé en conteneur et en chroot Ubuntu 25.10 avec les vrais paquets ; Proton-GE / Heroic à épingler ; affichage, VRR, HDR, FPS en attente du test sur matériel** — · [[M3 Chiffrement LUKS]] — **code écrit (13/11), testé sur disques virtuels seulement (loop devices, VM UEFI avec TPM émulé) ; vrai TPM, clavier au démarrage, mkinitcpio réel et FPS en attente du test sur matériel** — · [[M4 Updates A-B]] — **code écrit (13/11), testé sans matériel (fausses racines, loop devices avec TPM émulé, VM UEFI avec Secure Boot actif et TPM émulé) ; PR #7 vers `main` à relire par Sofiene avant M5 ; vrai TPM / firmware, shim, noyau Rago dans l'UKI et mkinitcpio en attente du test sur matériel**.
4. [[M5 Micro-Windows]] (prochain module, après la relecture de la PR #7 de M4 par Sofiene) · [[M6 Fast OS Switch]] · [[M7 Bibliothèque partagée]] · [[M8 Optimisation switch]].
5. [[M9 GPU]] · [[M10 Télémétrie]] · [[M11 Rago UI]] · [[M12 Installateur]] · [[M13 Build ISO]].

Les modules durs (R&D réelle, prévoir du débogage matériel) : [[M0 Noyau scx_rago]], [[M5 Micro-Windows]], [[M6 Fast OS Switch]].
