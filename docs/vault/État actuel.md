---
type: pilotage
tags: [état, pilotage]
maj: 2026-11-13
---
# État actuel (13/11/2026)

Voir aussi [[Prochaines étapes]], [[Questions ouvertes]], [[Journal]]. Retour à [[Projet]].

## En une phrase
**[[M0 Noyau scx_rago]] et [[M1 Tuning hôte]] sont codés** et testés là où Claude peut le faire (VM qemu, conteneur) ; aucun n'a **jamais été testé sur vrai matériel** (pas de machine de test pour l'instant). M0 : PR #1 (branche `claude/project-thread-gw35xo`), pas encore fusionnée dans `main`. M1 : branche `claude/project-thread-v4x2l5`, construite sur celle de M0 ; sa PR vise la branche de M0 (elle passera sur `main` une fois #1 fusionnée). Décision du 13/11 : en attendant la machine, on avance sur les modules testables sans matériel dédié ; [[M2 Couche Proton]] attend le feu vert de Sofiene.

## Tableau
| Sujet | État | Statut |
|---|---|---|
| Architecture | 2 couches (Proton natif + Fast OS Switch), VM abandonnée | DÉCIDÉ |
| Plan technique | bible v7 + 4 études dans `docs/plan/` | CONFIRMÉ |
| M0 (noyau + scx_rago) | code écrit ; VM 9/9, pipeline noyau OK sur un arbre 6.8 ; jamais testé sur matériel ; PR #1 ouverte | EN COURS |
| M1 (tuning hôte) | code écrit ; 105 + 89 tests en conteneur, VM qemu 59/59 sur 2 démarrages ; jamais testé sur matériel | EN COURS |
| Modules M2 à M14 | rien d'écrit ; M2 attend le feu vert | CONFIRMÉ |
| Machine de test | aucune pour l'instant (13/11) ; piste : portable de Sofiene avec un SSD externe pour ne pas risquer son disque | À VÉRIFIER |
| Modèle économique | freemium (base gratuite + Rago Pro ~30-40 € one-time), Console premium plus tard | À DÉCIDER ([[Monétisation]]) |

## Ce qui attend Sofiene
1. Relire et fusionner la PR M0 (#1), puis la PR M1 (construite dessus). Puis, quand une machine de test existe, M0 sur la machine de test (Arch / base Rago) : `kernel/build_rago_kernel.sh lock …` (épingler), `all`, puis en root `mok-gen`, `mok-enroll`, redémarrer (MokManager), `install`, `scx-install --user <toi>`. Avant : `m0_hardware_test.sh --save-baseline` sur le noyau d'origine ; après : `m0_hardware_test.sh --baseline …`.
2. M1 sur la même machine : `sudo host/setup_host_tuning.sh deps`, `install`, `kernel/build_rago_kernel.sh bootloader`, redémarrer, `host/setup_host_tuning.sh verify`, puis comparaison 1 % low MangoHud (`host/tests/m1_frametime_compare.sh`). Détail : [[M1 Tuning hôte]].
3. Donner (ou non) le feu vert pour [[M2 Couche Proton]].
4. Prévoir la machine/SSD de test et une ISO Windows (BYOL, voir [[Micro-Windows]]).
