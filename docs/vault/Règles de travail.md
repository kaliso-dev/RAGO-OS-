---
type: règle
tags: [règle]
maj: 2026-11-13
---
# Règles de travail

Retour à [[Projet]]. Détail daté dans [[Décisions]].

1. **Un module à la fois**, dans l'ordre de [[Prochaines étapes]], **testé sur vrai matériel avant le suivant**. Ne jamais balancer tous les prompts d'un coup. **Exception du 13/11 (pas de machine de test) :** on avance sur les modules testables sans matériel dédié (conteneur / VM), un à la fois, chacun sur feu vert de Sofiene ; ils restent « jamais testé sur matériel » ([[Décisions]]).
2. **Claude ne peut pas tester sur du vrai matériel** : chaque étape matérielle (boot, Secure Boot, switch, GPU) est marquée « jamais testé » jusqu'au test de Sofiene.
3. **Aucun secret** dans le chat, un commit ou une capture — seulement des noms de variables.
4. **Ne jamais affirmer une action sans preuve** (sortie de commande, log, test).
5. **Aucune dissimulation / masquage anti-triche** : hors périmètre, refusé. Tout est bare-metal légitime.
6. **Chaque note du vault est reliée à son code** : les fichiers de code que crée un module sont listés dans sa note (chemins en `backticks`).
7. **Règle n°1 : le vault correspond en tout point à l'état réel.** Le lire avant, détecter tout changement pendant, le mettre à jour à la fin de chaque tâche : [[Mettre à jour le vault]].
8. Français simple. Le public (si site/app un jour) sera en anglais US.

## PR et commits
- Branche de travail, PR vers `main`. « fusionne » de Sofiene = accord pour fusionner.
- Commits : phrases qui décrivent l'effet.
