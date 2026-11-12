---
type: carte
tags: [architecture]
maj: 2026-11-12
---
# Sécurité et boot

Retour à [[Architecture]]. Modules : [[M3 Chiffrement LUKS]], [[M0 Noyau scx_rago]].

**Secure Boot** : exigé par l'anti-triche, donc **activé en global** sur la machine. Comme c'est global, le noyau Linux custom **doit être signé** (clé MOK : `openssl`/`sbsign`/`mokutil`, gratuit). Sinon le switch casse.

**TPM 2.0 + VBS + HVCI + IOMMU** : activés côté [[Micro-Windows]] (exigés par [[Vanguard On-Demand]]).

**Chiffrement hôte** : LUKS2 lié au TPM (PCR 0+7) + passphrase de secours obligatoire ([[M3 Chiffrement LUKS]]). Le swap d'hibernation chiffré doit se déverrouiller avant le resume du [[Fast OS Switch]].
