---
type: carte
tags: [architecture]
maj: 2026-11-12
---
# Noyau et ordonnanceur

Retour à [[Architecture]]. Code : `kernel/`. Module : [[M0 Noyau scx_rago]].

Noyau Linux custom (base ≥6.12 + patchset CachyOS) : PREEMPT, 1000 Hz, ThinLTO, x86-64-v3/v4, MGLRU. **Signé Secure Boot** (obligatoire pour le switch, voir [[Sécurité et boot]]).

**L'innovation : `scx_rago`** (fork de scx_lavd via `sched_ext`). Au lieu de *deviner* quelles tâches sont critiques, **le launcher l'informe** : il tague l'arbre de processus du jeu (thread de rendu) comme latency-critical **avant** le lancement, via une BPF map (`host/bin/rago-sched-hint`). Routage auto de la topologie : jeu sur le **CCD à cache 3D** (Ryzen X3D) ou les **P-cores** (Intel hybride). Filet : EEVDF+BORE.

Relié à : [[M11 Rago UI]] (appelle le hint), [[M14 Profils par jeu]].
