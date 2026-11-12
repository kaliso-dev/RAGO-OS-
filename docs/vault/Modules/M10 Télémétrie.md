---
type: module
tags: [module, phase-C]
maj: 2026-11-12
statut: À FAIRE
---
# M10 Télémétrie

> Phase C. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Diagnostic anonymisé des crashs (noyau, session, switch).

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `daemons/rago-telemetry/` — démon Rust
- `host/systemd/rago-telemetry.service` — unité systemd

**Ce qu'il fait.** Lit journald + erreurs ; JSON sur anomalie ; anonymisation regex AVANT écriture ; HTTPS reqwest ; cache hors-ligne. Opt-in RGPD (off par défaut).

**Dépend de / relié à :** [[M6 Fast OS Switch]], [[Architecture]]

**Critère de test.** build OK ; crash simulé → JSON anonymisé (aucune donnée perso).

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M10). Détail : bible v7, module M10.
