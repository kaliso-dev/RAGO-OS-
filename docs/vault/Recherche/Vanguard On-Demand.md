---
type: recherche
tags: [recherche]
maj: 2026-11-12
---
# Vanguard On-Demand

Retour à [[Projet]]. Source : recherche nov. 2026 (`docs/plan/Rago_Etude_Micro_Windows.md`).

**Découverte clé qui valide le modèle Rago.** Riot a sorti en 2026 un mode où l'anti-triche Vanguard **ne se charge plus au boot, mais au lancement du jeu, et se décharge à la fermeture** — à condition que le PC ait **Windows 11 25H2 + Secure Boot + TPM 2.0 + VBS + HVCI + IOMMU** activés.

**Pourquoi ça compte** : c'est **exactement** le modèle du [[Fast OS Switch]] (on boote dans le jeu, on joue, on quitte). L'industrie de l'anti-triche converge vers l'architecture de Rago. Conséquence directe : le [[Micro-Windows]] doit **garder ces protections activées**, pas les stripper.

Nuance : VBS/HVCI coûtent un peu de FPS et activent le blocklist de pilotes vulnérables → d'où les deux profils de sécurité (compat max / perf) de [[M14 Profils par jeu]].
