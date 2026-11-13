---
type: pilotage
tags: [état, pilotage]
maj: 2026-11-13
---
# État actuel (13/11/2026)

Voir aussi [[Prochaines étapes]], [[Questions ouvertes]], [[Journal]]. Retour à [[Projet]].

## En une phrase
Le **module [[M0 Noyau scx_rago]] est codé** (branche `claude/project-thread-gw35xo`, PR vers `main`) et testé là où Claude peut le faire (VM qemu, conteneur) ; il n'a **jamais été testé sur vrai matériel**. Prochaine étape : Sofiene épingle les sources, compile, installe et lance `kernel/tests/m0_hardware_test.sh` sur sa machine. M1 n'est pas commencé (attend le feu vert).

## Tableau
| Sujet | État | Statut |
|---|---|---|
| Architecture | 2 couches (Proton natif + Fast OS Switch), VM abandonnée | DÉCIDÉ |
| Plan technique | bible v7 + 4 études dans `docs/plan/` | CONFIRMÉ |
| M0 (noyau + scx_rago) | code écrit ; VM 9/9, pipeline noyau OK sur un arbre 6.8 ; jamais testé sur matériel | EN COURS |
| Modules M1 à M14 | rien d'écrit | CONFIRMÉ |
| Machine de test | portable de Sofiene ; conseil : SSD externe pour ne pas risquer son disque | À VÉRIFIER |
| Modèle économique | freemium (base gratuite + Rago Pro ~30-40 € one-time), Console premium plus tard | À DÉCIDER ([[Monétisation]]) |

## Ce qui attend Sofiene
1. Relire et fusionner la PR M0, puis sur la machine de test (Arch / base Rago) : `kernel/build_rago_kernel.sh lock …` (épingler), `all`, puis en root `mok-gen`, `mok-enroll`, redémarrer (MokManager), `install`, `scx-install --user <toi>`. Avant : `m0_hardware_test.sh --save-baseline` sur le noyau d'origine ; après : `m0_hardware_test.sh --baseline …`.
2. Donner le feu vert pour M1 seulement après ce test.
3. Prévoir la machine/SSD de test et une ISO Windows (BYOL, voir [[Micro-Windows]]).
