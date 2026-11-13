---
type: pilotage
tags: [journal]
maj: 2026-11-13
---
# Journal

Une ligne datée par événement marquant. Retour à [[Projet]].

- **12/11/2026** — Conception terminée : bible v7 (2 couches), 4 études (switch, micro-Windows, innovations, marché), vault Obsidian créé comme cerveau du projet. VM abandonnée au profit du Fast OS Switch. Découverte clé : Vanguard On-Demand aligne l'anti-triche sur le modèle Rago ([[Vanguard On-Demand]]).
- **13/11/2026** — [[M0 Noyau scx_rago]] codé : fork scx_lavd → scx_rago (canal launcher par socket, héritage au fork, rendu reconnu par nom, routage X3D / hybride, garde de vol), `rago-sched-hint`, pipeline noyau signé MOK, service `rago-scx`, tests. Test VM qemu 9/9 (jeu 100 % sur le faux CCD X3D contre 52 % sans Rago). Pipeline noyau validé sur un arbre 6.8 (kernel.org bloqué) jusqu'au boot qemu du noyau signé. Jamais testé sur matériel.
- **13/11/2026** — Pas de machine de test pour l'instant : Sofiene décide d'avancer sur les modules testables sans matériel. [[M1 Tuning hôte]] codé : `host/setup_host_tuning.sh` (install / verify / uninstall / deps), profil tuned `rago-gaming` (dérivé de latency-performance, C-states au choix), sysctl, udev E/S, zram, threadirqs via `kernel.conf` de M0, irqbalance. Tests : 105 unitaires, 89 en fausse racine, VM qemu 59/59 sur 2 démarrages (vrais tuned, udev, zram, NVMe/SSD/HDD émulés). Jamais testé sur matériel.
