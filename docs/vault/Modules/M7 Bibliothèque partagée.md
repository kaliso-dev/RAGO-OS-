---
type: module
tags: [module, phase-B]
maj: 2026-11-14
statut: EN COURS
---
# M7 Bibliothèque partagée

> Phase B. Statut : **EN COURS** — code écrit le 14/11 sur la branche `claude/m7-bibliotheque-partagee` (une seule PR vers `main`, à relire par Sofiene). Côté Linux testé en conteneur et en VM qemu (vrai pilote ntfs3) ; côté Windows **jamais exécuté (Windows, conteneur Linux)**, validé seulement par lecture ; **jamais testé sur matériel**. Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Installer et gérer ses jeux Windows depuis Rago ; le micro-Windows ([[M5 Micro-Windows]]) les lance à vitesse native. Clients **officiels** seulement (Steam, Epic Games Launcher, Riot Client), pas de VM, aucun masquage, pas de Microsoft Store / Game Pass (Store retiré par M5). BYOL inchangé.

**Ordre** : après [[M5 Micro-Windows]] (fusionné dans `main` le 14/11, PR #8), **avant** [[M6 Fast OS Switch]] (décision du 14/11 : « M7 passe AVANT M6 : le switch doit être bâti contre une bibliothèque partagée déjà figée »). M6 se fait avec Sofiene (module dur).

## Fichiers de code (dans `kaliso-dev/rago-os-`)
Côté Linux :
- `host/bin/rago-library.sh` — commande `rago-library` (root) : `status`, `list`, `mount [--rw|--ro]`, `umount`, `install|launch steam|epic|riot ID`, `cancel`, `forget`, `confirm-windows-off`, `check` ; montage **ntfs3** (`mount -i -t ntfs3`, jamais ntfs-3g, jamais `force`) ; garde d'hibernation (`__sleep-guard`).
- `host/lib/rago_library.py` — décision lecture / écriture, lecture du NTFS sur le disque (bit « sale », `$LogFile`), requêtes et résultats dans RAGO-COMM, liste des jeux.
- `host/rago-library.conf` → `/etc/rago/rago-library.conf` (périphérique `/dev/disk/by-label/RAGO-LIB`, montage `/run/rago/lib`, options `uid=0,gid=0,umask=022,iocharset=utf8,windows_names,nosuid,nodev,noexec,noatime`).
- `host/systemd/rago-library-sleep-guard.service` — refuse l'hibernation de Linux tant qu'un volume NTFS est monté.
- `host/setup_library.sh` — `install | uninstall | check`.
- `host/rago-comm.conf` — commentaire seulement (RAGO-COMM lue aussi par M7).
- Tests : `host/tests/test_library.py`, `host/tests/run_m7_tests.sh [--vm]`, `host/tests/vm/run_m7_vm_test.sh`, `host/tests/vm/m7_vm_guest.sh`.

Côté Windows (copié dans `C:\Rago\agent\`) :
- `windows/rago-agent/rago-agent.ps1` — `-Boot` (SYSTEM, au démarrage), `-Shutdown` (SYSTEM, script d'arrêt), `-Session` (joueur), `-Status`, `-Abandon ID`, `-RegisterShutdown`.
- `windows/rago-agent/RagoAgent.psm1` — RAGO-COMM\library, RAGO-LIB en ligne / hors ligne, script d'arrêt de la stratégie locale, fiches des jeux.
- `windows/rago-agent/RagoLaunchers.psm1` — Steam, Epic, Riot (installateurs officiels vérifiés, détection de fin d'installation).
- `windows/rago-agent/launchers.json` (adresses, URI, formats, chacun avec sa source), `windows/rago-agent/agent.json` (lettre `L`, attente, délai), `windows/rago-agent/README.md` (mode d'emploi des deux côtés, installé aussi dans `/usr/share/doc/rago/library/`).
- Branchement : `windows/rago/bin/rago-boot.ps1` (script d'arrêt posé, aussi en `-SettingsOnly` ; `-Boot` après le contrôle « redémarrage pour la sécurité »), `windows/rago/bin/rago-shell.ps1` (fenêtre de la bibliothèque, menu `[B]`), `windows/compile_micro_engine.ps1` (`-AgentPath`, copie dans `C:\Rago\agent`).
- Tests (lecture seule) : `windows/tests/test_agent.py` ; `windows/tests/test_payload.py` (syntaxe, BOM, règles PowerShell 5.1 pour tous les scripts).

## Comment ça marche
- **RAGO-LIB** : partition NTFS (type GPT « Microsoft basic data », étiquette `RAGO-LIB`) ; jeux dans `Games\Steam`, `Games\Epic`, `Games\Riot` ; `.rago\` : `library.json`, fiches `games\<clé>.json` (écrites par Windows, lues par Linux), `cache\` (métadonnées des clients). Lettre fixe **`L:`** côté Windows (les manifestes des clients gardent le chemin).
- **RAGO-COMM\library\** (FAT32 de M5) : `windows-state.json` (Windows : `running` / `off`, `lib.found`, `lib.offline`), `partition.json` (Linux : PARTUUID + numéro de série NTFS de RAGO-LIB), `requests\<id>.json` (Linux), `results\<id>.json` (Windows : `waiting_user`, `running`, `done`, `failed`, `cancelled`), `linux-confirm.json` (Linux). Identifiants : `install|launch-steam|epic|riot-<slug>` ; mêmes expressions des deux côtés (testé).
- **Installation toujours dans Windows** : l'agent ouvre le client officiel au bon endroit (`steam://install/<id>`, URI d'Epic, installateur Riot), le joueur choisit le dossier `L:\Games\…` (aucun client ne le permet sans lui de façon documentée), l'agent suit la fin (manifeste Steam, `.item` d'Epic, fichiers principaux Riot) et écrit le résultat. Un jeu installé ailleurs que sur RAGO-LIB est signalé en échec, rien n'est déplacé. Installateurs des clients téléchargés chez l'éditeur, **signature Authenticode vérifiée** (Valve, Epic Games, Riot Games) ; rien n'est redistribué.
- **Finalisation** (« VC++ / .NET / registre ») : les prérequis de chaque jeu sont posés par le client officiel (Steam rejoue ses scripts d'installation au premier lancement, Epic installe les prérequis). L'agent vérifie le runtime VC++ 2015-2022 et installe ceux de `C:\Rago\redist` (fournis par le joueur, `-RedistPath`) ; après une reconstruction de Windows, il remet le `.item` d'Epic et le `product_settings.yaml` de Riot depuis `.rago\cache\` (**méthode non officielle, à vérifier**) ; il note la finalisation par installation de Windows (`MachineGuid`).

## Règle de sûreté : jamais les deux OS sur RAGO-LIB (décision du 14/11)
NTFS n'a aucun verrou entre deux systèmes ; le switch ([[M6 Fast OS Switch]]) garantit un seul OS actif.
1. **Windows** écrit `running` (et vide le cache de RAGO-COMM) **avant** de mettre RAGO-LIB en ligne ; sans RAGO-COMM, RAGO-LIB reste hors ligne. À l'arrêt (script d'arrêt de la stratégie de groupe locale, SYSTEM) : vidage, `mountvol L:\ /P` (démonte et met hors ligne), **confirmation par Windows** que le volume est hors ligne (`IOCTL_VOLUME_IS_OFFLINE`), puis `off`. `offline` n'est jamais écrit vrai sans cette confirmation.
2. **Linux** ne monte en écriture que si (a) RAGO-COMM dit `off` avec RAGO-LIB hors ligne (ou pas trouvée), ou le joueur a certifié Windows éteint (`confirm-windows-off`, valable seulement pour le fichier d'état qu'il a vu, empreinte sha256), **et** (b) le volume est propre sur le disque : bit « sale » éteint, `$LogFile` vide ou propre (règle de ntfs-3g refaite : page de redémarrage la plus récente en version 2.0 = cache de Windows, hibernation ou démarrage rapide ; clients encore ouverts sans le drapeau « propre » = arrêt brutal). Au moindre doute : **lecture seule**, jamais `force`.
3. **Pas d'hibernation de Linux** tant qu'un volume NTFS est monté (unité exigée par `systemd-hibernate`, `systemd-hybrid-sleep`, `systemd-suspend-then-hibernate` ; elle ne touche pas RAGO-COMM). **M6 doit faire `rago-library umount` avant d'hiberner** et hiberner par systemd.

## Tests (14/11)
- Conteneur : `host/tests/test_library.py` 45 tests (2 sautés, faits en VM) : décision, lecture du NTFS sur images fabriquées (bit sale, `$LogFile` 1.1 / 2.0 / ouvert / propre / CHKD, fragmenté, taille), requêtes, réglages, `rago-library.sh` de bout en bout sur périphériques loop (RAGO-LIB en ext4 faute de ntfs3 dans le noyau du conteneur). `windows/tests/test_agent.py` 33/33 (contrat Linux ↔ Windows, ordre de sûreté, interdits, adresses officielles, branchement), `windows/tests/test_payload.py` 23/23, tests de M5 toujours bons.
- VM qemu (`host/tests/vm/run_m7_vm_test.sh` : Ubuntu 24.04, noyau 6.8.0-31, vrai pilote ntfs3, vrai systemd 255, disque GPT avec RAGO-COMM FAT32 + RAGO-LIB NTFS créée par mkntfs) : **58/58**, dont les 45 tests de `test_library.py` repassés en vrai NTFS + ntfs3 sans aucun test sauté (bit « sale » posé par Rago refusé aussi par ntfs3 ; page de journal « cache de Windows » trouvée au bon endroit, recoupée par ntfscat), installation M5 + M7, montage par étiquette, PARTUUID réel noté pour Windows (relu sur la FAT32 sans Linux), lecture seule sans état / pendant `running`, écriture après `off` écrit sur la FAT32 comme Windows, type `ntfs3` (pas fuseblk), fichiers écrits par ntfs3 relus par ntfs-3g, volume propre après démontage, `systemd-hibernate.service` refusé tant que RAGO-LIB est montée (RAGO-COMM jamais touchée), démontage refusé si occupée, Store / Game Pass refusés, désinstallation (RAGO-LIB gardée).
- **Jamais exécuté côté Windows (Windows, conteneur Linux). Jamais testé sur matériel.**

## À vérifier sur la machine (voir [[Questions ouvertes]])
`mountvol /P` encore hors ligne au démarrage suivant ; réponse exacte de `IOCTL_VOLUME_IS_OFFLINE` ; script d'arrêt actif dès la première session ; lettre `L:` libre ; installateurs (`SteamSetup.exe /S`, MSI d'Epic ou nouvel installateur 2026, installateurs Riot) et noms des signataires ; `.item` d'Epic et `product_settings.yaml` de Riot remis après reconstruction ; bibliothèque Steam à rajouter après reconstruction ; Vanguard et redémarrage ; installateurs qui demandent l'Explorateur (shell sans explorer.exe).

## Ce que les autres modules doivent faire
- [[M6 Fast OS Switch]] : `rago-library umount` avant le switch et avant toute hibernation de Linux ; hiberner par systemd (la garde s'y accroche) ; Windows démarre à froid et s'arrête complètement (le script d'arrêt écrit `off`). Les requêtes `launch` serviront au « lancement direct au switch ».
- [[M11 Rago UI]] : appelle `rago-library status --json`, `list --json`, `install`, `launch`, `cancel`, `forget`.
- [[M12 Installateur]] : crée RAGO-LIB (GPT « Microsoft basic data », NTFS, étiquette `RAGO-LIB`, sans le bit « caché ») à côté de RAGO-COMM, puis `rago-library mount` une fois (note le PARTUUID pour Windows) ; installe `host/setup_library.sh`. Base Rago (Arch) : le noyau de [[M0 Noyau scx_rago]] garde ntfs3 en module (`CONFIG_NTFS3_FS=m`, `kernel/config/rago-keep.config`) ; chargement réel à vérifier sur la machine.

**Dépend de / relié à :** [[M5 Micro-Windows]], [[M6 Fast OS Switch]], [[M11 Rago UI]], [[M12 Installateur]], [[Micro-Windows]], [[Fast OS Switch]], [[Vanguard On-Demand]]

**Critère de test (bible).** Installation depuis l'UI → finalisée → lancement direct au switch. Aujourd'hui : requête depuis Linux → installation par le client officiel dans le micro-Windows → résultat et fiche lus par Linux ; « depuis l'UI » attend [[M11 Rago UI]], « au switch » attend [[M6 Fast OS Switch]].

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M7). Détail : bible v7, module M7.
