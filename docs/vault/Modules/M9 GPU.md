---
type: module
tags: [module, phase-C]
maj: 2026-11-12
statut: À FAIRE
---
# M9 GPU

> Phase C. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Verrouiller les fréquences GPU et surveiller la température.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/bin/rago_gpu_lock_pstates.sh` — lock P-states Nvidia/AMD
- `host/bin/rago_gpu_thermal_monitor.py` — monitoring thermique

**Ce qu'il fait.** nvidia-smi -pm 1/-ac ou AMD pp_*. Monitor T° (NVML/hwmon), seuil ~83°C, courbe ventilateurs. Horloges surchargées par le profil jeu ([[M14 Profils par jeu]]).

**Dépend de / relié à :** [[M1 Tuning hôte]], [[M14 Profils par jeu]]

**Critère de test.** lecture T° correcte ; P-states verrouillés ; profil horloges appliqué.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M9). Détail : bible v7, module M9.
