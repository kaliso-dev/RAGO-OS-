---
type: carte
tags: [architecture]
maj: 2026-11-13
---
# Noyau et ordonnanceur

Retour à [[Architecture]]. Code : `kernel/`. Module : [[M0 Noyau scx_rago]].

Noyau Linux custom (base ≥6.12 + patchset CachyOS) : PREEMPT, 1000 Hz, ThinLTO, x86-64-v3/v4, MGLRU. **Signé Secure Boot** (obligatoire pour le switch, voir [[Sécurité et boot]]).

**L'innovation : `scx_rago`** (fork de scx_lavd via `sched_ext`). Au lieu de *deviner* quelles tâches sont critiques, **le launcher l'informe** : il tague l'arbre de processus du jeu (thread de rendu) comme latency-critical **avant** le lancement, via une BPF map (`host/bin/rago-sched-hint`). Routage auto de la topologie : jeu sur le **CCD à cache 3D** (Ryzen X3D) ou les **P-cores** (Intel hybride). Filet : EEVDF+BORE.

**Comment le hint arrive au noyau** (code écrit, testé en VM, jamais sur matériel) : le launcher lance le jeu via `rago-sched-hint run -- <jeu>`, qui se tague par le socket `/run/rago/sched-hint.sock` (servi par scx_rago, root:rago 0660, appelant vérifié), puis fait `exec` du jeu. scx_rago écrit le tag dans les maps BPF `rago_tgids` / `rago_tids` ; les enfants héritent du tag au fork ; les threads dont le nom ressemble à un thread de rendu (`dxvk-cs`, `vkd3d_queue`, `RenderThread`…) passent en classe RENDER. Pas de binaire à capacités (casserait `LD_PRELOAD` de MangoHud / Steam Runtime).

**Routage** : X3D → CCD au plus grand L3, avec affinité dure (tient même si scx_rago tombe) ; Intel hybride → P-cores en préférence douce, rendu toujours sur P-cores, fond poussé vers les E-cores ; CPU symétrique → boost seul. Limite : le routage strict suppose que le masque jeu est un domaine lavd entier (vrai pour les masques détectés).

**Contraintes techniques** : BPF compilé avec Clang ≥ 20 ; le noyau doit exposer `/proc/config.gz` et debugfs. Détail du fork : `kernel/scx/scx_rago/RAGO_FORK.md`.

Relié à : [[M11 Rago UI]] (appelle le hint), [[M14 Profils par jeu]], [[M1 Tuning hôte]].
