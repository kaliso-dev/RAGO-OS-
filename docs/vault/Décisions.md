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

## Méthode
- **13/11 — Avancer sans machine de test.** « M0 (noyau + scx_rago) est codé […] mais JAMAIS testé sur vrai matériel (pas de machine de test pour l'instant). On avance donc sur les modules qui se testent sans matériel dédié, en commençant par M1. M0 reste « jamais testé sur matériel » dans le vault. » Puis M1, « et lui seul (M2 attend mon feu vert) ». Remplace, en attendant la machine, la règle « testé sur vrai matériel avant le suivant » ([[Règles de travail]]).

## Choix techniques de Claude (M0, 12/11) — à valider par Sofiene
Ce ne sont pas des décisions de Sofiene : choix d'implémentation faits pendant M0, modifiables.
- **Noyau 6.18 LTS** comme base (≥ 6.12 demandé ; LTS = correctifs longtemps). Version exacte épinglée dans `kernel/patches/sources.lock`.
- **Canal launcher → ordonnanceur = socket Unix** servi par scx_rago (root:rago, 0660), pas un binaire `setcap` : un binaire à capacités casserait `LD_PRELOAD` (MangoHud, Steam Runtime) dans le jeu.
- **X3D : affinité dure + routage BPF** (le jeu reste sur le CCD à cache même si scx_rago tombe). **Hybride : préférence douce** (le jeu peut déborder sur les E-cores si les P-cores sont pleins), rendu toujours sur P-cores.
- **Lockdown non imposé** : le mode integrity interdit l'hibernation du [[Fast OS Switch]].
- **Clang ≥ 20 pour le BPF** de scx_rago (Clang 18 produit un code refusé par le vérifieur).
- **Modules du noyau signés par une clé de build** (hors dépôt) intégrée au noyau ; la **clé MOK** signe noyau, systemd-boot et modules DKMS. Le build reste non privilégié.
- **Groupe `rago`** : seul un membre peut taguer ses jeux (le joueur y est ajouté par `scx-install --user`).

## Choix techniques de Claude (M1, 13/11) — à valider par Sofiene
- **C-states : `deep` par défaut** (aucune limite) ; `shallow` (= latency-performance, C1 max) et `poll` en option (`--cstates`). Raison : sur portable et sur X3D, bloquer les C-states profonds chauffe et peut baisser le boost des cœurs actifs. À trancher par la mesure 1 % low ([[M1 Tuning hôte]]).
- **swappiness = 10 gardé** (demandé) malgré zram : zram reste un dernier recours.
- **zram = moitié de la RAM, 8 Gio max, zstd, priorité 100** ; **zswap coupé** quand zram est actif (pas de double compression).
- **HDD → bfq**, SSD SATA / eMMC → mq-deadline, NVMe → none (`--nvme-scheduler mq-deadline` possible).
- **threadirqs passe par `RAGO_CMDLINE_EXTRA` de `/etc/rago/kernel.conf`** (mécanisme de M0, code de M0 inchangé) plutôt que par le plugin bootloader de tuned (pensé pour GRUB, pas systemd-boot).
- **IRQ : irqbalance réparti sur tous les CPU par défaut** ; `--irq-ban` optionnel. Pas d'isolation.
- **power-profiles-daemon arrêté** à l'installation (il change le gouverneur derrière tuned), remis à la désinstallation ; `--keep-ppd` pour le garder.
- **`vm.max_map_count = 2147483642`** (valeur SteamOS).

## Abandonné
- **VM gaming (passthrough/Looking Glass)** — 12/11, remplacé par le Fast OS Switch. Ne pas relancer.
- **Masquage anti-détection d'hyperviseur** — refusé, inutile sans VM. Ne pas relancer.
