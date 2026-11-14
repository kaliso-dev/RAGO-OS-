# Rago OS — micro-Windows (module M5)

Le micro-Windows est le Windows du Fast OS Switch : un Windows 11 réduit à un
moteur de jeu, sans bureau, sans écran de connexion, démarré seulement pour
les jeux dont l'anti-triche refuse Linux. Tout est bare-metal et légitime :
**aucune dissimulation**, Secure Boot, TPM, VBS, HVCI, IOMMU, Defender et le
pare-feu restent actifs, et leur état réel est mesuré et renvoyé à Linux.

> **État (14/11/2026).** Les scripts Windows n'ont **jamais été exécutés**
> (ils ont été écrits et vérifiés dans un conteneur Linux) et rien n'a été
> testé sur du vrai matériel. L'ablation réelle, l'installation, le
> démarrage, un jeu réel et la taille finale attendent l'ISO et la machine de
> test. Seuls le côté Linux (hook, RAGO-COMM) et la lecture statique des
> fichiers Windows sont testés : `host/tests/run_m5_tests.sh`.

## BYOL : Rago ne fournit jamais Windows

Tu télécharges toi-même l'ISO Windows 11 chez Microsoft, pour **ta** licence.
Les scripts ne téléchargent rien et refusent de tourner sans ton ISO.

Quelle édition ? **Windows 11 Pro 25H2 ou plus récent** (décision du
14/11) :
- 25H2 (build 26200) est le minimum de Vanguard On-Demand (Riot). Le script
  refuse une build plus ancienne, sauf `-AllowOlderBuild` pour un essai.
- Il prend l'édition **Professional** de l'ISO (l'ISO Windows 11 grand public
  de Microsoft la contient). Une autre édition seulement avec `-Edition` ou
  `-Index`, signalée dans le rapport.
- Pourquoi pas « IoT Enterprise LTSC 25H2 » : **elle n'existe pas**. La
  dernière LTSC est la 2024 (24H2, build 26100), donc **sans** Vanguard
  On-Demand ; les licences IoT / LTSC sont prévues pour des appareils à usage
  fixe, et League of Legends refuse les éditions Enterprise.

## Ce qu'il faut

Machine de construction (n'importe quel PC Windows, pas forcément le PC de jeu) :
- Windows 10 ou 11 x64, **PowerShell en administrateur** (Windows PowerShell
  5.1, celui de Windows ; pas besoin de PowerShell 7) ;
- 40 Go libres sur un disque NTFS (`-WorkDir`, défaut `C:\RagoBuild`) ;
- un DISM au moins aussi récent que l'image : sur un Windows plus ancien que
  l'ISO, installer le DISM de l'ADK Windows récent ;
- facultatif : `oscdimg.exe` (ADK, outils de déploiement) pour `-MakeIso`.

PC de jeu (réglages du BIOS / UEFI) : mode UEFI, **Secure Boot activé**, **TPM
2.0 activé** (fTPM AMD ou PTT Intel : si un compte Riot est restreint, seul un
fTPM convient), virtualisation (Intel VT-x, AMD SVM), **IOMMU** (Intel VT-d,
AMD IOMMU / AMD-Vi). Un espace libre sur le disque pour Windows (Setup
demande où l'installer ; **ne jamais choisir une partition de Linux**).

## 1. Voir ce qui serait retiré (rien n'est écrit)

Dans un PowerShell administrateur, dans le dossier `windows\` du dépôt :

```powershell
powershell -ExecutionPolicy Bypass -File .\compile_micro_engine.ps1 -SourcePath D:\Iso\Win11_25H2_French_x64.iso -PlanOnly
```

Résultat : `C:\RagoBuild\out\m5-plan-report.json` (Appx, fonctions à la
demande, packs de langue, fonctionnalités, pilotes qui seraient retirés).

## 2. Construire

```powershell
powershell -ExecutionPolicy Bypass -File .\compile_micro_engine.ps1 -SourcePath D:\Iso\Win11_25H2_French_x64.iso -DriverPath D:\Pilotes -RedistPath D:\Redist
```

Options utiles :
- `-DriverPath` : pilotes du PC de jeu à ajouter (dossier de `.inf`, réseau
  surtout) ;
- `-RedistPath` : dossier copié dans `C:\Rago\redist` et installé au premier
  démarrage : `VC_redist.x64.exe`, `VC_redist.x86.exe` (Microsoft Visual C++)
  et, si besoin, le DirectX de juin 2010 décompressé (`DXSETUP.exe`). Rien
  n'est téléchargé : tu les prends chez Microsoft ;
- `-UpdatePath` : mises à jour cumulatives (`.msu` / `.cab` du catalogue
  Microsoft Update) intégrées à l'image. Windows Update est coupé dans le
  micro-Windows : c'est **la** façon de le mettre à jour (reconstruire) ;
- `-FinalCompression recovery` : image `.esd` plus petite (LZMS), au lieu de
  `max` (`.wim`, LZX) ;
- `-Hibernation off` : pas d'hibernation de Windows (voir plus bas) ;
- `-PageFileMB 1024` : fichier d'échange fixe (256 à 65536 Mio) ;
- `-PlayerName`, `-ComputerName`, `-UILanguage`, `-InputLocale`, `-TimeZone` ;
- `-MakeIso` : ISO amorçable en plus du dossier de média ;
- `-InstallToDisk N -InstallToPartition P` : installation sans question de
  disque (numéros vus dans Setup avec Maj+F10 puis `diskpart` ; rien n'est
  effacé, la partition doit exister). Sans ces options, Setup demande ;
- `-NoNetFx3`, `-SkipMeasure`, `-AllowUnknownEdition`, `-AllowOlderBuild`.

Le script refuse de tourner si le plan (`micro_engine_plan.json`) touchait à
un service de sécurité ou s'il manquait la base VBS + HVCI, et il relit cette
base dans l'image avant de l'enregistrer.

Ce qu'il produit, dans `C:\RagoBuild\out\` :
- `install.wim` (ou `install.esd`) ;
- `autounattend.xml` réglé (langue, clavier, fuseau, nom du joueur) ;
- `media\` : le média d'installation complet, `autounattend.xml` à la racine,
  image découpée en `install*.swm` si elle dépasse 4 Go (clé FAT32) ;
- `m5-build-report.json` : ce qui a été retiré, et les **tailles mesurées**.
  La mesure applique vraiment l'image (CompactOS) dans un disque virtuel :
  rien n'est estimé. La taille installée sur le PC de jeu est mesurée à part
  (`rago-report.ps1`, plus bas) ;
- journaux : `C:\RagoBuild\logs\`.

## 3. Installer sur le PC de jeu

1. Clé USB en **FAT32** (table GPT) : copier tout le contenu de `media\` à
   la racine de la clé.
2. Démarrer le PC de jeu sur la clé (UEFI). Setup est silencieux, sauf :
   la clé de produit (si Setup la demande : la tienne, ou « Je n'ai pas de
   clé ») et **le choix du disque** (prendre l'espace libre prévu pour
   Windows).
3. Le compte local `RagoPlayer` (administrateur, UAC actif, **sans mot de
   passe**, aucun compte Microsoft) s'ouvre tout seul. Le premier démarrage
   finit l'installation (C:\Rago verrouillé, tâche `\Rago\Boot`, profil de
   sécurité, CompactOS, VC++ / DirectX) ; la toute première session peut
   s'ouvrir une fois avec le bureau classique, ensuite c'est le shell Rago.
4. **Remettre Linux en premier** dans l'ordre de démarrage : Windows Setup
   se met devant. Depuis Linux :
   ```sh
   efibootmgr                      # repérer le numéro de Linux (systemd-boot) et de « Windows Boot Manager »
   sudo efibootmgr -o XXXX,YYYY    # XXXX = Linux d'abord, YYYY = Windows
   ```
   Ensuite un redémarrage de Windows (menu `[L]`, écran bleu, coupure)
   revient toujours sur Linux.

Le mot de passe vide est un choix pour qu'aucun écran de connexion Windows ne
s'affiche : Windows refuse alors toute connexion par le réseau à ce compte,
mais quelqu'un devant le PC peut ouvrir la session. BitLocker n'est pas
activé (question ouverte dans le vault).

## 4. Côté Linux : RAGO-COMM et profil de sécurité

RAGO-COMM est une petite partition **FAT32** (64 Mio) de type GPT
« Microsoft basic data » (code `0700` de `sgdisk`), nommée `RAGO-COMM`, que
Linux et Windows lisent **tour à tour**, jamais en même temps. Linux ne monte
jamais le NTFS de Windows. Création à la main (efface la partition choisie) :
`sudo mkfs.vfat -F 32 -n RAGO-COMM /dev/<partition>` ; plus tard
l'installateur (M12) le fera.

```sh
sudo host/setup_windows_security.sh install   # hook + unité de montage à la demande + /etc/rago/rago-comm.conf
sudo host/setup_windows_security.sh check     # n'écrit rien
rago-profiled prepare-switch --id valorant    # écrit le profil du jeu dans RAGO-COMM (M14 → hook)
sudo efibootmgr -n YYYY && systemctl reboot   # démarrer Windows une fois (YYYY = Windows Boot Manager)
# … au retour sur Linux :
sudo host/setup_windows_security.sh status    # profil demandé, état réel écrit par Windows, rapport M5
```

Fichiers dans RAGO-COMM :
- `security/profile.json` : écrit par Linux (hook `windows-security`) ;
- `security/status.json` : écrit par Windows (profil appliqué, état réel) ;
- `reports/m5-engine.json` : écrit par Windows (rapport de mesure).

La bascule automatique (clic sur le jeu → Windows → retour) est le travail
de M6.

## Les deux profils de sécurité (pilotés par M14)

- `compat_max` : hyperviseur lancé, **VBS + HVCI tournent** (Vanguard
  On-Demand, Ricochet…). Profil par défaut.
- `perf` : hyperviseur coupé (`hypervisorlaunchtype Off`), VBS / HVCI ne
  tournent pas, pour les jeux dont l'anti-triche ne les demande pas.

Dans les deux : Secure Boot, TPM, IOMMU (réglages du firmware, jamais
touchés), Defender, pare-feu, liste de blocage des pilotes vulnérables. La
configuration du registre reste celle de `compat_max` (sans verrou UEFI) :
seul l'hyperviseur change, au démarrage. Un **changement** de profil coûte
donc un redémarrage de Windows de plus (le script redémarre une fois sur
Windows grâce à l'entrée à usage unique `BootNext`, jamais deux fois de
suite) ; le même profil deux fois de suite ne coûte rien.

À savoir : EAC et BattlEye refusent de charger leur pilote quand la
« protection de pile matérielle en mode noyau » (Sécurité Windows > Sécurité
des appareils > Isolation du noyau) est active. Rago ne l'active pas et ne la
coupe pas : le shell et `status.json` la montrent.

## Le shell Rago (à la place du bureau)

`C:\Rago\bin\rago-shell.ps1`, lancé par Winlogon. Il attend l'état de
sécurité de ce démarrage, l'affiche (profil demandé, VBS, HVCI, Secure Boot,
TPM, conditions de Vanguard On-Demand ; le verdict officiel est dans VGTray
de Riot), puis propose : `[1]` console, `[2]` console administrateur, `[3]`
navigateur (Edge s'il est là), `[4]` lancer un programme (launcher,
installateur), `[5]` rapport M5, `[S]` état de sécurité, `[L]` retour à Linux
(redémarrage), `[E]` éteindre. Gestionnaire des tâches : Ctrl+Maj+Échap.
Si le shell est fermé : Ctrl+Alt+Suppr > Gestionnaire des tâches >
Exécuter une nouvelle tâche > `powershell -File C:\Rago\bin\rago-shell.ps1`.
Le lancement direct du jeu viendra avec M6.

## Où sont les choses dans Windows

- `C:\Rago\` (SYSTEM et Administrateurs seuls en écriture) : `bin\`
  (scripts), `setup\` (premier démarrage), `tasks\rago-boot.xml`, `redist\`,
  `micro-engine.json` (réglages de la construction), `comm\` (point de
  montage de RAGO-COMM si Windows ne lui donne pas de lettre).
- `C:\ProgramData\Rago\` : `logs\`, `reports\m5-engine-<date>.json`,
  `security-state.json`, `security-status.json`, `firstboot-<phase>.json`.
- Journal du shell : `%LOCALAPPDATA%\Rago\logs\shell.log`.

## Critère de test de M5 (à faire sur le PC de jeu)

1. `compile_micro_engine.ps1 -PlanOnly`, puis la construction ; garder
   `m5-build-report.json`.
2. Installation, ordre de démarrage remis, `status` depuis Linux.
3. `reports/m5-engine.json` : RAM au repos (cible ~300-500 Mo), pas
   d'`explorer.exe` ni de `SearchIndexer`, taille de `C:` sans
   pagefile / hiberfil / swapfile (cible 5-8 Go), CompactOS.
4. Un **jeu réel** et son anti-triche, en `compat_max` (Valorant : VGTray
   doit dire Pre-Check OK) et en `perf` (un jeu EAC ou BattlEye).
5. Rapporter les fichiers JSON (aucun ne contient de clé de produit ni de
   mot de passe).

L'hibernation de Windows est gardée par défaut (demande du 14/11 : « le
switch M6 s'en sert ») : `hiberfil.sys` fait environ 40 % de la RAM et n'est
pas compté dans la cible de taille. `-Hibernation off` la coupe.

## Limites connues

- Jeux du Microsoft Store / Game Pass : pas pris en charge (Store retiré).
- Windows Update coupé : correctifs en reconstruisant avec `-UpdatePath`.
  Les définitions de Defender sont prises à chaque démarrage directement chez
  Microsoft (`MpCmdRun -SignatureUpdate -MMPC`, à vérifier sur la machine).
- Pilotes inbox : DISM ne sait pas les retirer (seuls les pilotes tiers le
  sont) ; ils ne coûtent rien en RAM.
- Désactiver une fonctionnalité Windows ne libère pas de place sur une
  édition client (doc Microsoft) : ça retire seulement des services.
- Fichiers à jour de ces notes et questions ouvertes : `docs/vault/` (note
  « M5 Micro-Windows »).
