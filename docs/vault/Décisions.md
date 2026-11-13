---
type: règle
tags: [décisions]
maj: 2026-11-13
---
# Décisions

Chaque décision de Sofiene, datée. Retour à [[Projet]]. La plus récente prime.

## Architecture
- **12/11 — Deux couches, pas de VM.** La couche VM est abandonnée : les jeux qui tolèrent une VM tournent déjà sur Proton, ceux qui la refusent refusent aussi la VM. Le Fast OS Switch (bare-metal) remplace la VM pour l'anti-triche. Voir [[Fast OS Switch]].
- **12/11 — Aucune dissimulation / aucun masquage d'hyperviseur.** Hors périmètre, non développé. Tout est bare-metal légitime.
- **12/11 — BYOL (Bring Your Own License).** Rago ne distribue pas Windows ; l'utilisateur fournit son ISO + sa licence. Voir [[Micro-Windows]].

## Choix techniques de Claude (M0, 12/11) — à valider par Sofiene
Ce ne sont pas des décisions de Sofiene : choix d'implémentation faits pendant M0, modifiables.
- **Noyau 6.18 LTS** comme base (≥ 6.12 demandé ; LTS = correctifs longtemps). Version exacte épinglée dans `kernel/patches/sources.lock`.
- **Canal launcher → ordonnanceur = socket Unix** servi par scx_rago (root:rago, 0660), pas un binaire `setcap` : un binaire à capacités casserait `LD_PRELOAD` (MangoHud, Steam Runtime) dans le jeu.
- **X3D : affinité dure + routage BPF** (le jeu reste sur le CCD à cache même si scx_rago tombe). **Hybride : préférence douce** (le jeu peut déborder sur les E-cores si les P-cores sont pleins), rendu toujours sur P-cores.
- **Lockdown non imposé** : le mode integrity interdit l'hibernation du [[Fast OS Switch]].
- **Clang ≥ 20 pour le BPF** de scx_rago (Clang 18 produit un code refusé par le vérifieur).
- **Modules du noyau signés par une clé de build** (hors dépôt) intégrée au noyau ; la **clé MOK** signe noyau, systemd-boot et modules DKMS. Le build reste non privilégié.
- **Groupe `rago`** : seul un membre peut taguer ses jeux (le joueur y est ajouté par `scx-install --user`).

## Abandonné
- **VM gaming (passthrough/Looking Glass)** — 12/11, remplacé par le Fast OS Switch. Ne pas relancer.
- **Masquage anti-détection d'hyperviseur** — refusé, inutile sans VM. Ne pas relancer.
