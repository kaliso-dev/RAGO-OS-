---
type: carte
tags: [architecture]
maj: 2026-11-12
---
# Architecture

Repo `kaliso-dev/rago-os-`. Retour à [[Projet]]. Deux couches, zéro VM, zéro masquage.

## Carte du code
| Chemin | Rôle | Module / note |
|---|---|---|
| `kernel/` | Noyau custom + ordonnanceur scx_rago | [[M0 Noyau scx_rago]], [[Noyau et ordonnanceur]] |
| `host/` | Scripts & configs de l'hôte Linux (tuning, proton, luks, a/b, gpu, switch, profils) | [[M1 Tuning hôte]] … |
| `windows/` | Micro-Windows (ablation DISM) + `rago-shell` + `rago-agent` | [[M5 Micro-Windows]], [[M6 Fast OS Switch]] |
| `daemons/` | Démons Rust (télémétrie, profils) | [[M10 Télémétrie]], [[M14 Profils par jeu]] |
| `rago-ui/` | Launcher Tauri v2 | [[M11 Rago UI]] |
| `installer/` | Installateur + migration | [[M12 Installateur]] |
| `profiles/` | Base de profils par jeu | [[M14 Profils par jeu]] |
| `iso/Rago_ISO_Builder/` | Build de l'ISO | [[M13 Build ISO]] |
| `docs/vault/` | Ce vault (le cerveau) | [[Mettre à jour le vault]] |
| `docs/plan/` | Bible v7 + 4 études (détail complet) | — |

## Le flux
L'utilisateur vit sur **Rago (Linux)**. La plupart des jeux se lancent via **Proton** ([[Couche Proton]]). Un jeu anti-triche déclenche le **[[Fast OS Switch]]** : Linux hiberne, le **[[Micro-Windows]]** démarre bare-metal direct sur le jeu, et à la fermeture on revient dans la session Rago. Une **couche d'optimisation transversale** (le launcher qui connaît le jeu) pilote l'ordonnanceur ([[Noyau et ordonnanceur]]) et les [[M14 Profils par jeu]].

Contrainte fondamentale : [[Loi physique du POST]]. Prérequis : [[Prérequis matériel]], [[Sécurité et boot]].
