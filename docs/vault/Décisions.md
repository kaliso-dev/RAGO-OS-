---
type: règle
tags: [décisions]
maj: 2026-11-12
---
# Décisions

Chaque décision de Sofiene, datée. Retour à [[Projet]]. La plus récente prime.

## Architecture
- **12/11 — Deux couches, pas de VM.** La couche VM est abandonnée : les jeux qui tolèrent une VM tournent déjà sur Proton, ceux qui la refusent refusent aussi la VM. Le Fast OS Switch (bare-metal) remplace la VM pour l'anti-triche. Voir [[Fast OS Switch]].
- **12/11 — Aucune dissimulation / aucun masquage d'hyperviseur.** Hors périmètre, non développé. Tout est bare-metal légitime.
- **12/11 — BYOL (Bring Your Own License).** Rago ne distribue pas Windows ; l'utilisateur fournit son ISO + sa licence. Voir [[Micro-Windows]].

## Abandonné
- **VM gaming (passthrough/Looking Glass)** — 12/11, remplacé par le Fast OS Switch. Ne pas relancer.
- **Masquage anti-détection d'hyperviseur** — refusé, inutile sans VM. Ne pas relancer.
