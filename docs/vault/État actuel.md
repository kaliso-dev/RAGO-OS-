---
type: pilotage
tags: [état, pilotage]
maj: 2026-11-13
---
# État actuel (13/11/2026)

Voir aussi [[Prochaines étapes]], [[Questions ouvertes]], [[Journal]]. Retour à [[Projet]].

## En une phrase
**[[M0 Noyau scx_rago]], [[M1 Tuning hôte]], [[M14 Profils par jeu]], [[M2 Couche Proton]], [[M3 Chiffrement LUKS]] et [[M4 Updates A-B]] sont codés** et testés là où Claude peut le faire (VM qemu, conteneur, chroot, disques virtuels) ; aucun n'a **jamais été testé sur vrai matériel** (pas de machine de test pour l'instant). M0 : fusionné dans `main` (PR #1, 13/11). M1 : fusionné dans `main` le 13/11 (PR #2 d'abord dans la branche de M0, puis PR #3 vers `main`). M14 : fusionné dans `main` le 13/11 (PR #4). M2 : fusionné dans `main` le 13/11 (PR #5). M3 : fusionné dans `main` le 13/11 (PR #6). M4 : branche `claude/project-thread-8u4yl8`, construite sur `main` (M0 + M1 + M2 + M3 + M14) ; une seule PR vers `main` (PR #7), à relire par Sofiene avant M5. Décision du 13/11 : en attendant la machine, on avance sur les modules testables sans matériel dédié, un à la fois.

## Tableau
| Sujet | État | Statut |
|---|---|---|
| Architecture | 2 couches (Proton natif + Fast OS Switch), VM abandonnée | DÉCIDÉ |
| Plan technique | bible v7 + 4 études dans `docs/plan/` | CONFIRMÉ |
| M0 (noyau + scx_rago) | code écrit ; VM 9/9, pipeline noyau OK sur un arbre 6.8 ; `sign` / `bootloader` et démarrage Secure Boot actif (systemd-boot signé → noyau signé) vus dans la VM de M4 ; mode A/B ajouté par M4 (PR #7 à relire) ; jamais testé sur matériel ; dans `main` (PR #1) | EN COURS |
| M1 (tuning hôte) | code écrit ; 105 + 89 tests en conteneur, VM qemu 59/59 sur 2 démarrages ; jamais testé sur matériel ; dans `main` (PR #3) | EN COURS |
| M14 (profils par jeu) | code écrit ; 31 + 12 tests Rust, schéma 42/42, vrai noyau 23/23, VM qemu 43/43 ; hooks M9 / M5-M6 en attente ; jamais testé sur matériel ; dans `main` (PR #4) | EN COURS |
| M2 (couche Proton) | code écrit ; 94 + 22 + 64 + 72 tests en conteneur (dont vrais binaires M14 / M0), chroot Ubuntu 25.10 avec les vrais paquets 116/116 (Steam, gamescope, gamemode, vrai polkit, MangoHud ; la session gamescope elle-même demande un vrai GPU) ; Proton-GE / Heroic pas encore épinglés (`host/setup_proton_layer.sh lock`, GitHub bloqué) ; affichage / VRR / HDR / FPS en attente de matériel ; dans `main` (PR #5) | EN COURS |
| M3 (chiffrement LUKS2 + TPM) | code écrit ; 160 tests de fonctions, 168 en fausse racine (dracut, mkinitcpio), 116 sur loop devices avec TPM émulé (swtpm), VM qemu UEFI + TPM émulé 90/90 sur 6 démarrages (déverrouillage par le TPM sans passphrase, hibernation et reprise vers le swap chiffré, slots A et B, Secure Boot activé → passphrase de secours puis `reseal`) ; vrai TPM / firmware, passphrase au vrai clavier, mkinitcpio réel et FPS en attente de matériel ; fusionné dans `main` (PR #6, 13/11) ; étendu par M4 (un jeton TPM par entrée de démarrage, PCR 11 ; PR #7 à relire) | EN COURS |
| M4 (mises à jour A/B + UKI signée) | code écrit ; 101 + 149 tests sans root (aussi dans un chroot Ubuntu 26.04), 74 sur loop devices avec TPM émulé, VM UEFI Secure Boot + TPM émulé 141/141 sur 12 démarrages (UKI modifiée refusée par Secure Boot, retours automatiques, re-scellement manqué → passphrase de secours) ; jamais testé sur matériel ; PR #7 vers `main` à relire | EN COURS |
| Modules M5 à M13 | rien d'écrit | CONFIRMÉ |
| Machine de test | aucune pour l'instant (13/11) ; piste : portable de Sofiene avec un SSD externe pour ne pas risquer son disque | À VÉRIFIER |
| Modèle économique | freemium (base gratuite + Rago Pro ~30-40 € one-time), Console premium plus tard | À DÉCIDER ([[Monétisation]]) |

## Ce qui attend Sofiene
1. Relire la PR de [[M4 Updates A-B]] (PR #7) avant M5, et dire si les choix techniques de M4 conviennent ([[Décisions]], « Choix techniques de Claude (M4) »). Questions de M4 à trancher ([[Questions ouvertes]]) : ancien noyau nu signé MOK (rejeu de PCR 11), volume `/home` partagé par les deux slots, clé des images de mise à jour, `panic=10`, politique PCR 11 signée, enrôlement TPM pendant l'installation.
2. Quand une machine de test existe, M0 sur la machine de test (Arch / base Rago) : `kernel/build_rago_kernel.sh lock …` (épingler), `all`, puis en root `mok-gen`, `mok-enroll`, redémarrer (MokManager), `install`, `scx-install --user <toi>`. Avant : `m0_hardware_test.sh --save-baseline` sur le noyau d'origine ; après : `m0_hardware_test.sh --baseline …`.
3. M1 sur la même machine : `sudo host/setup_host_tuning.sh deps`, `install`, `kernel/build_rago_kernel.sh bootloader`, redémarrer, `host/setup_host_tuning.sh verify`, puis comparaison 1 % low MangoHud (`host/tests/m1_frametime_compare.sh`). Détail : [[M1 Tuning hôte]].
4. M14 sur la même machine : `daemons/rago-profiled/install.sh build`, `sudo … install --user <toi>`, `sudo daemons/rago-profiled/tests/real_kernel_test.sh --bin /usr/bin/rago-profiled`, puis un jeu Steam avec `rago-profiled launch -- %command%`. Détail : [[M14 Profils par jeu]].
5. M2 sur la même machine : `sudo host/setup_proton_layer.sh deps --enable-32bit`, `install`, `verify` ; démarrer Steam une fois puis le fermer, `host/setup_proton_layer.sh user` ; session « Rago » au gestionnaire de connexion ; un jeu Proton (MangoHud, profil M14, gamemode). Détail et critères : [[M2 Couche Proton]]. Avant : épingler Proton-GE et Heroic (`host/setup_proton_layer.sh lock`, accès GitHub).
6. M3 sur la même machine, **seulement sur le SSD de test** (formater efface le volume ; garder la passphrase de secours notée à part) : `sudo host/setup_secure_encryption.sh check` (n'écrit rien), puis l'installation chiffrée décrite dans [[M3 Chiffrement LUKS]] (« Utilisation »). À vérifier : démarrage sans rien taper (vrai TPM), passphrase de secours tapée au vrai clavier après une mise à jour du BIOS ou l'activation de Secure Boot, `sudo rago-encryption reseal`, `sudo rago-encryption verify`, hibernation et reprise, FPS inchangés.
7. M4 sur la même machine, après M0 + M3 (SSD de test) : `sudo host/manage_atomic_updates.sh check`, `setup`, redémarrer (l'UKI du slot A est essayée puis confirmée), `sudo rago-update verify` ; une mise à jour `sudo rago-update apply --clone --run "…"`, redémarrer ; vérifier le retour automatique sur une mise à jour cassée, et que Secure Boot refuse une UKI modifiée. À regarder : déverrouillage par le vrai TPM avec PCR 11 (la confirmation compare PCR 11 mesuré et prédit), chaîne shim → systemd-boot → UKI, noyau Rago dans l'UKI. Détail : [[M4 Updates A-B]].
8. Prévoir la machine/SSD de test et une ISO Windows (BYOL, voir [[Micro-Windows]]).
