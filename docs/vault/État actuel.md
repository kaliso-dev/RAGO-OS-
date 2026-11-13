---
type: pilotage
tags: [état, pilotage]
maj: 2026-11-13
---
# État actuel (13/11/2026)

Voir aussi [[Prochaines étapes]], [[Questions ouvertes]], [[Journal]]. Retour à [[Projet]].

## En une phrase
**[[M0 Noyau scx_rago]], [[M1 Tuning hôte]], [[M14 Profils par jeu]] et [[M2 Couche Proton]] sont codés** et testés là où Claude peut le faire (VM qemu, conteneur, chroot) ; aucun n'a **jamais été testé sur vrai matériel** (pas de machine de test pour l'instant). M0 : fusionné dans `main` (PR #1, 13/11). M1 : fusionné dans `main` le 13/11 (PR #2 d'abord dans la branche de M0, puis PR #3 vers `main`). M14 : fusionné dans `main` le 13/11 (PR #4). M2 : branche `claude/project-thread-8h2mbw`, construite sur `main` (M0 + M1 + M14) ; PR #5 vers `main`, à relire. Décision du 13/11 : en attendant la machine, on avance sur les modules testables sans matériel dédié, un à la fois.

## Tableau
| Sujet | État | Statut |
|---|---|---|
| Architecture | 2 couches (Proton natif + Fast OS Switch), VM abandonnée | DÉCIDÉ |
| Plan technique | bible v7 + 4 études dans `docs/plan/` | CONFIRMÉ |
| M0 (noyau + scx_rago) | code écrit ; VM 9/9, pipeline noyau OK sur un arbre 6.8 ; jamais testé sur matériel ; dans `main` (PR #1) | EN COURS |
| M1 (tuning hôte) | code écrit ; 105 + 89 tests en conteneur, VM qemu 59/59 sur 2 démarrages ; jamais testé sur matériel ; dans `main` (PR #3) | EN COURS |
| M14 (profils par jeu) | code écrit ; 31 + 12 tests Rust, schéma 42/42, vrai noyau 23/23, VM qemu 43/43 ; hooks M9 / M5-M6 en attente ; jamais testé sur matériel ; dans `main` (PR #4) | EN COURS |
| M2 (couche Proton) | code écrit ; 94 + 22 + 64 + 72 tests en conteneur (dont vrais binaires M14 / M0), chroot Ubuntu 25.10 avec les vrais paquets 116/116 (Steam, gamescope, gamemode, vrai polkit, MangoHud ; la session gamescope elle-même demande un vrai GPU) ; Proton-GE / Heroic pas encore épinglés ; affichage / VRR / HDR / FPS en attente de matériel ; PR #5 vers `main`, à relire | EN COURS |
| Modules M3 à M13 | rien d'écrit | CONFIRMÉ |
| Machine de test | aucune pour l'instant (13/11) ; piste : portable de Sofiene avec un SSD externe pour ne pas risquer son disque | À VÉRIFIER |
| Modèle économique | freemium (base gratuite + Rago Pro ~30-40 € one-time), Console premium plus tard | À DÉCIDER ([[Monétisation]]) |

## Ce qui attend Sofiene
1. Relire et fusionner la PR #5 de [[M2 Couche Proton]]. Puis, quand une machine de test existe, M0 sur la machine de test (Arch / base Rago) : `kernel/build_rago_kernel.sh lock …` (épingler), `all`, puis en root `mok-gen`, `mok-enroll`, redémarrer (MokManager), `install`, `scx-install --user <toi>`. Avant : `m0_hardware_test.sh --save-baseline` sur le noyau d'origine ; après : `m0_hardware_test.sh --baseline …`.
2. M1 sur la même machine : `sudo host/setup_host_tuning.sh deps`, `install`, `kernel/build_rago_kernel.sh bootloader`, redémarrer, `host/setup_host_tuning.sh verify`, puis comparaison 1 % low MangoHud (`host/tests/m1_frametime_compare.sh`). Détail : [[M1 Tuning hôte]].
3. M14 sur la même machine : `daemons/rago-profiled/install.sh build`, `sudo … install --user <toi>`, `sudo daemons/rago-profiled/tests/real_kernel_test.sh --bin /usr/bin/rago-profiled`, puis un jeu Steam avec `rago-profiled launch -- %command%`. Détail : [[M14 Profils par jeu]].
4. M2 sur la même machine : `sudo host/setup_proton_layer.sh deps --enable-32bit`, `install`, `verify` ; démarrer Steam une fois puis le fermer, `host/setup_proton_layer.sh user` ; session « Rago » au gestionnaire de connexion ; un jeu Proton (MangoHud, profil M14, gamemode). Détail et critères : [[M2 Couche Proton]]. Avant : épingler Proton-GE et Heroic (`host/setup_proton_layer.sh lock`, accès GitHub).
5. Dire quel module suit (ordre prévu : [[M3 Chiffrement LUKS]], [[M4 Updates A-B]] ; voir [[Prochaines étapes]]).
6. Prévoir la machine/SSD de test et une ISO Windows (BYOL, voir [[Micro-Windows]]).
