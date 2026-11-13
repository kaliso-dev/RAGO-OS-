---
type: carte
tags: [architecture]
maj: 2026-11-13
---
# Sécurité et boot

Retour à [[Architecture]]. Modules : [[M3 Chiffrement LUKS]], [[M0 Noyau scx_rago]], [[M4 Updates A-B]].

**Secure Boot** : exigé par l'anti-triche, donc **activé en global** sur la machine. Comme c'est global, le noyau Linux custom **doit être signé** (clé MOK : `openssl`/`sbsign`/`mokutil`, gratuit). Sinon le switch casse.

**Chaîne signée Rago (M0, code écrit, jamais testé sur matériel)** : clé MOK propre à chaque machine, créée par `build_rago_kernel.sh mok-gen` dans `/etc/rago/secureboot/` (jamais dans le dépôt), inscrite par `mok-enroll` puis MokManager au redémarrage. Chaîne : firmware (clé Microsoft) → shim → systemd-boot signé MOK → noyau signé MOK (`sbsign`). Modules DKMS (NVIDIA) signés MOK. Sans shim, la clé devrait être dans la db UEFI.

**Chaîne avec [[M4 Updates A-B]] (code écrit le 13/11, testé en VM seulement, jamais sur matériel)** : firmware → shim → systemd-boot signé MOK → **UKI signée MOK par slot** (`EFI/Linux/rago-a.efi`, `rago-b.efi` : noyau + initramfs du slot + ligne de commande, faite par `ukify`, signée par `sbsign` avec la même clé MOK, aucune nouvelle clé). Éditeur de systemd-boot coupé (`editor no`). Le noyau nu n'est plus signé ni posé sur l'ESP. Prouvé en VM avec Secure Boot actif (clé MOK de test dans la db, sans shim) : une UKI modifiée d'un octet (`rd.shell=0` → `rd.shell=1`) est refusée au démarrage.

**Lockdown non imposé** (`LOCK_DOWN_KERNEL_FORCE_NONE`) : le mode « integrity » interdit l'hibernation, dont le [[Fast OS Switch]] a besoin.

**TPM 2.0 + VBS + HVCI + IOMMU** : activés côté [[Micro-Windows]] (exigés par [[Vanguard On-Demand]]).

**Chiffrement hôte ([[M3 Chiffrement LUKS]], code écrit le 13/11, testé sur disques virtuels seulement, jamais sur matériel)** : LUKS2 (aes-xts-plain64, clé 512 bits, sha512, argon2id) pour la racine de chaque slot A / B et le swap d'hibernation. Le TPM rend la clé au démarrage si PCR 0 (firmware) et PCR 7 (état et clés Secure Boot) sont ceux de l'enrôlement ; sinon la **passphrase de secours, obligatoire**, est demandée. Le swap chiffré est ouvert dans l'initramfs **avant** le resume du [[Fast OS Switch]] (prouvé en VM : hibernation puis reprise). Avec [[M4 Updates A-B]] : un jeton TPM par entrée de démarrage, lié aussi à **PCR 11** (mesure de l'UKI par systemd-stub, valeur prédite depuis le fichier) ; la passphrase de secours n'est jamais retirée.

**Risque PCR 7** : une mise à jour du BIOS / UEFI, de la liste dbx ou l'activation de Secure Boot change PCR 0 / 7 ; au démarrage suivant le TPM refuse, la passphrase de secours est demandée (rien n'est perdu), puis `sudo rago-encryption reseal`. Le contrôle `rago-tpm-check` le signale après chaque démarrage. Prouvé en VM (Secure Boot activé avec les clés de test d'OVMF). Avec M4, chaque nouvelle UKI change PCR 11 : `rago-update` relance `reseal` lui-même ; s'il ne peut pas (pas de passphrase sous la main), la passphrase est demandée au premier démarrage de la nouvelle UKI, jamais de machine verrouillée.

**Limite « devant la machine » : résolue par [[M4 Updates A-B]]** (décision de Sofiene le 13/11 : « oui, il faut une image UKI signée », voir [[Décisions]]). Sans M4, PCR 0+7 ne couvrent ni l'initramfs (fichier non signé sur l'ESP) ni la ligne de commande (modifiable au menu systemd-boot) de l'entrée `rago.conf` de [[M0 Noyau scx_rago]] : quelqu'un devant la machine pourrait obtenir la clé du TPM sans passphrase. Avec M4 : tout est dans l'UKI signée, l'éditeur est coupé, PCR 11 lie chaque jeton à son UKI. Restent : l'entrée de repli sans UKI (si `ukify` ou la clé manquent : PCR 0+7 seulement, signalé), et un **ancien noyau nu signé MOK** (de M0 avant M4) gardé ailleurs, qui pourrait rejouer la mesure PCR 11 d'une UKI (À DÉCIDER, [[Questions ouvertes]]).
