---
type: module
tags: [module, phase-A]
maj: 2026-11-12
statut: À FAIRE
---
# M4 Updates A-B

> Phase A. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** OS immuable redondant (slots A/B) avec rollback auto.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/manage_atomic_updates.sh` — bascule de slot + watchdog/rollback

**Ce qu'il fait.** Slot actif via findmnt, image signée sur le slot passif, bascule systemd-boot, rollback auto si multi-user.target non atteint. Jamais le slot actif. Deux slots chiffrés.

**Dépend de / relié à :** [[M3 Chiffrement LUKS]], [[M13 Build ISO]]

**Critère de test.** update → boot passif ; échec simulé → rollback auto.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M4). Détail : bible v7, module M4.
