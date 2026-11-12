---
type: module
tags: [module, phase-A]
maj: 2026-11-12
statut: À FAIRE
---
# M3 Chiffrement LUKS

> Phase A. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Disque hôte chiffré, déverrouillage TPM, compatible hibernation du switch.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/setup_secure_encryption.sh` — LUKS2 + enrôlement TPM

**Ce qu'il fait.** LUKS2 (aes-xts, argon2id), enrôlement TPM PCR 0+7 + passphrase de secours obligatoire, crypttab + initramfs. Swap d'hibernation chiffré déverrouillé avant resume ([[Fast OS Switch]]).

**Dépend de / relié à :** [[Sécurité et boot]], [[M4 Updates A-B]], [[M6 Fast OS Switch]]

**Critère de test.** auto-unlock si intègre ; fallback passphrase ; FPS inchangé.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M3). Détail : bible v7, module M3.
