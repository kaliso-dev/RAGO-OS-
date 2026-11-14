---
type: module
tags: [module, phase-B]
maj: 2026-11-14
statut: À FAIRE
---
# M6 Fast OS Switch

> Phase B. Statut : **À FAIRE** (aucun code écrit). Retour à [[Projet]], carte [[Architecture]].

**Objectif.** La bascule vers le micro-Windows : rapide et fluide, sans jamais voir Windows.

**Fichiers de code** (dans `kaliso-dev/rago-os-`) :
- `host/bin/rago-switch-to-windows.sh` — écrit le jeu, one-shot, hibernate
- `windows/rago-shell/` — shell Winlogon : lance le jeu, surveille, retour (remplacera `windows/rago/bin/rago-shell.ps1` de M5)
- `(config)` — hibernation/resume, entrées systemd-boot, partition RAGO-COMM

**Ce qu'il fait.** Design asymétrique (Windows sans état, one-shot auto-consommé). Deux modes (Rapide / Session préservée). Continuité visuelle (gel de frame + splash UEFI de [[M8 Optimisation switch]]). Pré-conditionnement GPU + warm reset. Fast Startup Windows off ; Linux ne monte jamais le NTFS système de Windows (comm FAT32) ; la bibliothèque RAGO-LIB (NTFS, [[M7 Bibliothèque partagée]]) seulement quand Windows est éteint.

**Ce que [[M5 Micro-Windows]] fournit déjà** (code du 14/11, jamais exécuté côté Windows) :
- **RAGO-COMM** : partition FAT32 « Microsoft basic data » nommée `RAGO-COMM`, montée par Linux **à la demande** (`host/systemd/run-rago-comm.mount`, `Conflicts=sleep.target`, réglages `/etc/rago/rago-comm.conf`), jamais en même temps que Windows. Fichiers : `security/profile.json` (Linux → Windows), `security/status.json` et `reports/m5-engine.json` (Windows → Linux). M6 y ajoutera la demande de jeu.
- **Profil de sécurité** : `rago-profiled prepare-switch --id <jeu>` ([[M14 Profils par jeu]]) → hook `host/hooks/windows-security` ; Windows l'applique à chaque démarrage (`C:\Rago\bin\rago-security.ps1`). Un **changement** de profil coûte un démarrage de Windows de plus : Windows pose l'hyperviseur puis se redémarre une fois sur lui-même par **BootNext** (`bcdedit /set {fwbootmgr} bootsequence {bootmgr}`, à usage unique). C'est la seule écriture de Windows dans les variables de démarrage ; l'ordre de démarrage n'est jamais touché. M6 pourrait éviter ce double démarrage (régler l'hyperviseur depuis Linux, ou deux entrées BCD) : [[Questions ouvertes]].
- **Shell** : `C:\Rago\bin\rago-shell.ps1` (Winlogon\Shell, posé par `rago-boot.ps1`), provisoire. M6 le remplace par le lanceur de jeu (attendre `security-status.json` de ce démarrage avant de lancer quoi que ce soit, comme lui) et le retour automatique.
- **Windows sans état** (décision du 14/11) : démarrage rapide coupé, **hibernation de Windows coupée par défaut** (`-Hibernation off`), arrêt complet ; écran bleu → redémarrage → Linux. Le micro-Windows démarre à froid et revient par `shutdown /r` : il ne s'hiberne jamais lui-même, **l'hibernation du switch est celle de Linux** (celle que M6 code). Reprendre Windows depuis sa propre hibernation n'est plus le défaut : c'est un arbitrage disque / vitesse à étudier en [[M8 Optimisation switch]] (`hiberfil.sys` ≈ 40 % de la RAM sur le disque) ; s'il était retenu, il faudrait démonter RAGO-COMM avant que Windows dorme (Linux y écrit pendant ce temps, le cache FAT de Windows serait périmé).
- **Pas de mise à jour en ligne** dans Windows (décision du 14/11) : aucun écran « mise à jour en cours » ni redémarrage imposé par Windows Update pendant une bascule ; les correctifs arrivent avec une image reconstruite (`-UpdatePath`). Une nouvelle image peut changer PCR 7 (dbx / SBAT) : au retour, passphrase de secours puis `reseal` ([[Questions ouvertes]]).
- Ordre de démarrage : Windows Setup se met devant Linux ; à remettre depuis Linux (`efibootmgr -o`, `windows/README.md`). En M5, l'aller vers Windows se fait à la main (`efibootmgr -n`).

**Ce que [[M7 Bibliothèque partagée]] lui demande** (code du 14/11, côté Windows jamais exécuté) :
- **`rago-library umount` avant de basculer et avant toute hibernation de Linux, et basculer seulement sur le code 0** ; code 1 = RAGO-LIB occupée, ou démontée ici mais encore ouverte ailleurs (par exemple dans l'espace de noms privé d'une mise à jour [[M4 Updates A-B]] en cours, ou démontage différé) : la bascule doit attendre ou s'arrêter (jamais de démontage forcé). Ne pas monter RAGO-LIB pendant une veille : `rago-library mount` refuse quand une veille démarre. Une unité (`rago-library-sleep-guard.service`, exigée par `systemd-hibernate`, `systemd-hybrid-sleep`, `systemd-suspend-then-hibernate`) **refuse l'hibernation** tant qu'un volume NTFS est monté : M6 doit donc hiberner par systemd, après le démontage.
- Windows démarre à froid et s'arrête complètement : c'est le **script d'arrêt** de l'agent (stratégie de groupe locale) qui met RAGO-LIB hors ligne et écrit `off` dans `RAGO-COMM\library\windows-state.json` ; un écran bleu ou une coupure laissent `running` → Linux reste en lecture seule sur RAGO-LIB (jusqu'à un démarrage + arrêt propre de Windows, ou `rago-library confirm-windows-off`).
- Lancement direct au switch : les requêtes `launch` de M7 (`RAGO-COMM\library\requests\`) sont prises par l'agent dans la session du joueur ; le lanceur de M6 pourra s'en servir (ou les remplacer par sa propre demande de jeu).

**Avec [[M4 Updates A-B]]** (code du 13/11) : l'entrée à usage unique de systemd-boot (`bootctl set-oneshot`) sert aussi à l'essai d'une mise à jour, et le crochet d'hibernation de M4 (`host/systemd/system-sleep/rago-update`) fait reprendre Linux sur la même entrée quand il n'a pas démarré par l'entrée par défaut ; il laisse en place une entrée à usage unique déjà choisie (celle de M6). Les deux se marchent dessus pendant un essai : à régler en codant M6, voir [[Questions ouvertes]].

**Ordre** : construit **après** [[M7 Bibliothèque partagée]] (décision du 14/11 : « le switch doit être bâti contre une bibliothèque partagée déjà figée »).

**Dépend de / relié à :** [[Fast OS Switch]], [[M0 Noyau scx_rago]], [[M3 Chiffrement LUKS]], [[M5 Micro-Windows]], [[M7 Bibliothèque partagée]], [[M8 Optimisation switch]], [[Loi physique du POST]]

**Critère de test.** clic → jeu plein écran sans écran noir ni login ; fermeture → session Rago restaurée ; reboot inattendu → Linux.

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M6). Détail : bible v7, module M6.
