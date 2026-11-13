---
type: carte
tags: [architecture]
maj: 2026-11-13
---
# Sécurité et boot

Retour à [[Architecture]]. Modules : [[M3 Chiffrement LUKS]], [[M0 Noyau scx_rago]].

**Secure Boot** : exigé par l'anti-triche, donc **activé en global** sur la machine. Comme c'est global, le noyau Linux custom **doit être signé** (clé MOK : `openssl`/`sbsign`/`mokutil`, gratuit). Sinon le switch casse.

**Chaîne signée Rago (M0, code écrit, jamais testé sur matériel)** : clé MOK propre à chaque machine, créée par `build_rago_kernel.sh mok-gen` dans `/etc/rago/secureboot/` (jamais dans le dépôt), inscrite par `mok-enroll` puis MokManager au redémarrage. Chaîne : firmware (clé Microsoft) → shim → systemd-boot signé MOK → noyau signé MOK (`sbsign`). Modules DKMS (NVIDIA) signés MOK. Sans shim, la clé devrait être dans la db UEFI.

**Lockdown non imposé** (`LOCK_DOWN_KERNEL_FORCE_NONE`) : le mode « integrity » interdit l'hibernation, dont le [[Fast OS Switch]] a besoin.

**TPM 2.0 + VBS + HVCI + IOMMU** : activés côté [[Micro-Windows]] (exigés par [[Vanguard On-Demand]]).

**Chiffrement hôte** : LUKS2 lié au TPM (PCR 0+7) + passphrase de secours obligatoire ([[M3 Chiffrement LUKS]]). Le swap d'hibernation chiffré doit se déverrouiller avant le resume du [[Fast OS Switch]].
