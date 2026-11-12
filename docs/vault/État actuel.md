---
type: pilotage
tags: [état, pilotage]
maj: 2026-11-12
---
# État actuel (12/11/2026)

Voir aussi [[Prochaines étapes]], [[Questions ouvertes]], [[Journal]]. Retour à [[Projet]].

## En une phrase
Le projet est en **phase de conception terminée** : la bible technique (`docs/plan/Rago_OS_Pro_Build_Bible.md`, v7) et les 4 études sont écrites ; **aucun code n'est encore écrit**. Prochaine étape : coder [[M0 Noyau scx_rago]] et le tester sur une machine réelle.

## Tableau
| Sujet | État | Statut |
|---|---|---|
| Architecture | 2 couches (Proton natif + Fast OS Switch), VM abandonnée | DÉCIDÉ |
| Plan technique | bible v7 + 4 études dans `docs/plan/` | CONFIRMÉ |
| Code | rien d'écrit | CONFIRMÉ |
| Machine de test | portable de Sofiene ; conseil : SSD externe pour ne pas risquer son disque | À VÉRIFIER |
| Modèle économique | freemium (base gratuite + Rago Pro ~30-40 € one-time), Console premium plus tard | À DÉCIDER ([[Monétisation]]) |

## Ce qui attend Sofiene
1. Lancer le projet Claude avec la bible + le prompt M0 (`docs/plan/Rago_Prompts_Sequence.md`).
2. Prévoir la machine/SSD de test et une ISO Windows (BYOL, voir [[Micro-Windows]]).
