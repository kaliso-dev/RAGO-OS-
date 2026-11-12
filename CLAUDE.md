# Instructions pour Claude — Rago OS

**Avant toute chose, lis `docs/vault/Projet.md`, puis `docs/vault/État actuel.md` et `docs/vault/Règles de travail.md`.**

Le `docs/vault/` est le **cerveau** du projet : la mémoire de Claude est désactivée, donc ce qui n'y est pas écrit est perdu. **Règle n°1 : le vault doit correspondre en tout point à l'état réel.** À la fin de chaque tâche, suis `docs/vault/Mettre à jour le vault.md` (mettre à jour les notes touchées, relier le code, passer le statut des modules, dater).

Le plan détaillé est dans `docs/plan/` (bible v7 + études). On construit **un module à la fois**, dans l'ordre, **testé sur vrai matériel avant le suivant**. Chaque note de module relie ses fichiers de code (chemins en backticks).

Périmètre : deux couches (Proton natif + Fast OS Switch bare-metal). **Pas de VM, aucune dissimulation / masquage anti-triche.** Tout est légitime.
