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

**Chiffrement hôte ([[M3 Chiffrement LUKS]], code écrit le 13/11, testé sur disques virtuels seulement, jamais sur matériel)** : LUKS2 (aes-xts-plain64, clé 512 bits, sha512, argon2id) pour la racine de chaque slot A / B et le swap d'hibernation. Le TPM rend la clé au démarrage si PCR 0 (firmware) et PCR 7 (état et clés Secure Boot) sont ceux de l'enrôlement ; sinon la **passphrase de secours, obligatoire**, est demandée. Le swap chiffré est ouvert dans l'initramfs **avant** le resume du [[Fast OS Switch]] (prouvé en VM : hibernation puis reprise).

**Risque PCR 7** : une mise à jour du BIOS / UEFI, de la liste dbx ou l'activation de Secure Boot change PCR 0 / 7 ; au démarrage suivant le TPM refuse, la passphrase de secours est demandée (rien n'est perdu), puis `sudo rago-encryption reseal`. Le contrôle `rago-tpm-check` le signale après chaque démarrage. Prouvé en VM (Secure Boot activé avec les clés de test d'OVMF).

**Limite connue (À DÉCIDER)** : PCR 0+7 ne couvrent ni l'initramfs (fichier non signé sur l'ESP) ni la ligne de commande (modifiable au menu systemd-boot) de l'entrée écrite par [[M0 Noyau scx_rago]]. Quelqu'un devant la machine pourrait donc obtenir la clé du TPM sans passphrase. Correctif possible hors M3 : image UKI signée MOK (noyau + initramfs + ligne de commande) et éditeur de systemd-boot coupé. Détail : [[M3 Chiffrement LUKS]], [[Questions ouvertes]].
