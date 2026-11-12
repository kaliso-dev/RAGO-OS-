---
type: règle
tags: [règle, vault]
maj: 2026-11-12
---
# Mettre à jour le vault

> **Règle n°1 du projet.** Ce vault est le **cerveau** de Rago OS. La mémoire intégrée de Claude est désactivée : ce qui n'est pas écrit ici est perdu à la fin d'un fil. Si Sofiene change de Claude ou reprend le projet plus tard, **ce vault est tout ce qui reste**. Il doit correspondre **en tout point** à l'état réel : chaque module, chaque fonctionnement, chaque décision. Jamais d'info fausse, périmée ou abandonnée. Retour à [[Projet]].

## 1. Avant de commencer
1. Lire [[Projet]], [[État actuel]], [[Règles de travail]], puis la note du module/sujet traité.
2. **Comparer avec la réalité** (code du repo, résultat des tests de Sofiene, ce qu'il dit). Toute différence est corrigée dans le vault **dans la même tâche**.

## 2. Pendant le travail
À chaque info nouvelle, se demander : **est-ce que ça change une note ?** — un module codé/testé/cassé, un fichier de code ajouté ou renommé, une décision de Sofiene, un choix technique, un résultat de test matériel, un abandon.

## 3. À la fin de chaque tâche (avant de dire « fini »)
1. **Mettre à jour** la note de chaque sujet touché pour décrire **l'état réel d'aujourd'hui**.
2. **Relier le code** : dans la note du module, lister les fichiers de code créés/modifiés (chemins en `backticks`), et passer le `statut:` du module (À FAIRE → EN COURS → CONFIRMÉ une fois testé sur matériel).
3. **Supprimer** ce qui n'est plus vrai ; garder une ligne dans [[Décisions]] section « Abandonné » pour qu'aucun Claude ne le relance.
4. [[État actuel]] : où en est le build. [[Journal]] : une ligne datée. [[Décisions]] : chaque décision de Sofiene, datée, avec ses mots entre « ».
5. [[Questions ouvertes]] : retirer les questions répondues, ajouter les nouveaux doutes.
6. Mettre `maj:` à la date du jour dans l'en-tête des notes touchées.
7. Vérifier qu'aucun lien `[[…]]` n'est cassé et que chaque nouvelle note est reliée depuis [[Projet]].

## 4. En cas de doute
Ne jamais deviner. Écrire la question dans [[Questions ouvertes]] en **À VÉRIFIER** / **À DÉCIDER** et prévenir Sofiene. Le code, les tests et la parole la plus récente de Sofiene font foi, dans cet ordre.

## 5. Règles d'écriture
- Une note par sujet ; nom de fichier = titre, unique dans tout le vault (les liens se font par nom).
- Chaque note pointe vers au moins deux autres notes avec des liens `[[doubles crochets]]`. C'est la toile de la vue graphe.
- Statut et source pour ce qui n'est pas évident.
- **Chaque note de module relie ses fichiers de code** (chemins en `backticks`).
