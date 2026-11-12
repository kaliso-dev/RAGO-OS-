---
type: module
tags: [module, phase-A]
maj: 2026-11-12
statut: À FAIRE
---
# M14 Profils par jeu

> Phase A. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Appliquer automatiquement le profil optimal (perf + sécurité) par jeu, sur les deux couches. Différenciateur clé.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `profiles/` — base de profils par jeu (JSON/TOML)
- `daemons/rago-profiled/` — démon Rust qui applique le profil au lancement

**Ce qu'il fait.** Profil = { couche, cpu_governor, thp, sched_hint, gpu_clocks, mitigations, windows_security compat_max|perf }. Applique côté Linux (gouverneur, THP, hint M0, horloges M9) ; côté switch, écrit le profil de sécurité dans RAGO-COMM pour que [[M5 Micro-Windows]] règle VBS/HVCI. Base communautaire + fallback sûr.

**Dépend de / relié à :** [[M0 Noyau scx_rago]], [[M2 Couche Proton]], [[M5 Micro-Windows]], [[M9 GPU]], [[M11 Rago UI]]

**Critère de test.** jeu avec profil → gouverneur/THP/hint/horloges appliqués ; côté switch VBS on/off selon le profil ; fallback sûr sans profil.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M14). Détail : bible v7, module M14.
