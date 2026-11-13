---
type: pilotage
tags: [état, pilotage]
maj: 2026-11-13
---
# État actuel (13/11/2026)

Voir aussi [[Prochaines étapes]], [[Questions ouvertes]], [[Journal]]. Retour à [[Projet]].

## En une phrase
**[[M0 Noyau scx_rago]], [[M1 Tuning hôte]] et [[M14 Profils par jeu]] sont codés** et testés là où Claude peut le faire (VM qemu, conteneur) ; aucun n'a **jamais été testé sur vrai matériel** (pas de machine de test pour l'instant). M0 : fusionné dans `main` (PR #1, 13/11). M1 : la PR #2 a été fusionnée le 13/11 dans la branche de M0 (`claude/project-thread-gw35xo`) et **pas dans `main`** : M1 manque encore dans `main`, un autre fil le remet. M14 : branche `claude/project-thread-vqtjpu`, construite sur la branche de M1 ; sa PR vise `main` (elle montre aussi les commits de M1 tant que M1 n'y est pas). Décision du 13/11 : en attendant la machine, on avance sur les modules testables sans matériel dédié ; [[M2 Couche Proton]] attend le feu vert de Sofiene.

## Tableau
| Sujet | État | Statut |
|---|---|---|
| Architecture | 2 couches (Proton natif + Fast OS Switch), VM abandonnée | DÉCIDÉ |
| Plan technique | bible v7 + 4 études dans `docs/plan/` | CONFIRMÉ |
| M0 (noyau + scx_rago) | code écrit ; VM 9/9, pipeline noyau OK sur un arbre 6.8 ; jamais testé sur matériel ; dans `main` (PR #1) | EN COURS |
| M1 (tuning hôte) | code écrit ; 105 + 89 tests en conteneur, VM qemu 59/59 sur 2 démarrages ; jamais testé sur matériel ; PR #2 fusionnée dans la branche de M0, **absent de `main`** | EN COURS |
| M14 (profils par jeu) | code écrit ; 31 + 12 tests Rust, schéma 42/42, vrai noyau 23/23, VM qemu (voir la note) ; hooks M9 / M5-M6 en attente ; jamais testé sur matériel ; PR vers `main` | EN COURS |
| Modules M2 à M13 | rien d'écrit ; M2 attend le feu vert | CONFIRMÉ |
| Machine de test | aucune pour l'instant (13/11) ; piste : portable de Sofiene avec un SSD externe pour ne pas risquer son disque | À VÉRIFIER |
| Modèle économique | freemium (base gratuite + Rago Pro ~30-40 € one-time), Console premium plus tard | À DÉCIDER ([[Monétisation]]) |

## Ce qui attend Sofiene
1. Remettre M1 dans `main` (un autre fil s'en occupe), puis relire et fusionner la PR M14. Puis, quand une machine de test existe, M0 sur la machine de test (Arch / base Rago) : `kernel/build_rago_kernel.sh lock …` (épingler), `all`, puis en root `mok-gen`, `mok-enroll`, redémarrer (MokManager), `install`, `scx-install --user <toi>`. Avant : `m0_hardware_test.sh --save-baseline` sur le noyau d'origine ; après : `m0_hardware_test.sh --baseline …`.
2. M1 sur la même machine : `sudo host/setup_host_tuning.sh deps`, `install`, `kernel/build_rago_kernel.sh bootloader`, redémarrer, `host/setup_host_tuning.sh verify`, puis comparaison 1 % low MangoHud (`host/tests/m1_frametime_compare.sh`). Détail : [[M1 Tuning hôte]].
3. M14 sur la même machine : `daemons/rago-profiled/install.sh build`, `sudo … install --user <toi>`, `sudo daemons/rago-profiled/tests/real_kernel_test.sh --bin /usr/bin/rago-profiled`, puis un jeu Steam avec `rago-profiled launch -- %command%`. Détail : [[M14 Profils par jeu]].
4. Donner (ou non) le feu vert pour [[M2 Couche Proton]].
5. Prévoir la machine/SSD de test et une ISO Windows (BYOL, voir [[Micro-Windows]]).
