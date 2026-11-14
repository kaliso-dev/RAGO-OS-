# Rago OS — bibliothèque partagée (module M7)

Installer et gérer ses jeux Windows depuis Rago, puis les lancer dans le
micro-Windows (M5) à vitesse native. Tout est légitime : **pas de VM**,
**aucun masquage**, les jeux sont installés et lancés par les **clients
officiels** (Steam, Epic Games Launcher, Riot Client). Pas de Microsoft Store
ni de Game Pass (le Store est retiré par M5).

> **État (14/11/2026).** Côté Linux : testé en conteneur et en machine
> virtuelle qemu (vrai pilote ntfs3, image NTFS) : `host/tests/run_m7_tests.sh`.
> Côté Windows (`windows/rago-agent/`) : **jamais exécuté** (écrit et vérifié
> par lecture dans un conteneur Linux : `windows/tests/test_agent.py`).
> **Rien n'a été testé sur du vrai matériel.** Les points à vérifier sont dans
> `docs/vault/Questions ouvertes.md` (lignes M7).

## L'idée

- **RAGO-LIB** : une partition **NTFS** sur le disque, partagée par les deux
  OS. Windows y installe les jeux (`L:\Games\Steam`, `L:\Games\Epic`,
  `L:\Games\Riot`) ; Linux la lit (liste des jeux) avec le pilote noyau
  **ntfs3** (jamais ntfs-3g / FUSE).
- **RAGO-COMM** : la petite partition FAT32 de M5. Linux y écrit les
  **requêtes** (« installe Steam 730 »), Windows y écrit son **état** et les
  **résultats**.
- **L'installation réelle se fait toujours dans Windows**, par le client
  officiel. Linux gère, liste et déclenche.

## Règle de sûreté : jamais les deux OS en même temps sur RAGO-LIB

NTFS n'a **aucun verrou entre deux systèmes**. Si Linux écrivait pendant que
Windows a le volume ouvert (ou l'a laissé dans son cache d'hibernation), le
volume serait corrompu. Donc :

1. **Le switch (M6) n'a qu'un OS actif à la fois.**
2. **Windows** écrit « running » dans RAGO-COMM **avant** de mettre RAGO-LIB
   en ligne ; à l'arrêt, un script d'arrêt (stratégie de groupe locale, compte
   SYSTEM) vide le cache, met RAGO-LIB **hors ligne** (`mountvol L:\ /P`),
   fait **confirmer** par Windows que le volume est hors ligne, puis écrit
   « off ». Sans RAGO-COMM, RAGO-LIB reste hors ligne.
3. **Linux** ne monte RAGO-LIB **en écriture** que si les deux sont vrais :
   - RAGO-COMM dit « off » avec RAGO-LIB hors ligne (ou le joueur a certifié
     que Windows est éteint, `rago-library confirm-windows-off`, valable
     seulement pour l'état qu'il a vu) ;
   - le volume NTFS est **propre sur le disque** : bit « sale » éteint,
     journal `$LogFile` vide ou propre, pas de cache de veille prolongée ni de
     démarrage rapide de Windows (même règle que ntfs-3g, relue par Rago).
   Au moindre doute : **lecture seule**. Jamais l'option `force`.
4. **Pas d'hibernation de Linux** tant qu'un volume NTFS est monté
   (`rago-library-sleep-guard.service`) : Windows pourrait démarrer pendant
   ce temps. M6 doit démonter RAGO-LIB (`rago-library umount`) avant
   d'hiberner Linux.

## Côté Linux

```
rago-library status                 # Windows éteint proprement ? requêtes, résultats
rago-library list                   # jeux de RAGO-LIB (montée en lecture seule le temps de lire)
rago-library install steam 730      # requête pour le prochain démarrage du micro-Windows
rago-library install epic Fortnite
rago-library install riot valorant
rago-library launch steam 730
rago-library mount [--rw | --ro]    # /run/rago/lib ; sans option : écriture si permise
rago-library umount                 # avant de passer sous Windows
rago-library check                  # n'écrit rien : pilote ntfs3, partition, réglages
```

Fichiers : `host/bin/rago-library.sh`, `host/lib/rago_library.py`,
`host/rago-library.conf` (→ `/etc/rago/rago-library.conf`),
`host/systemd/rago-library-sleep-guard.service`, installation
`host/setup_library.sh install`.

Le pilote ntfs3 est dans le noyau (Linux 5.15 et plus). Sur Ubuntu, il est
dans `linux-modules-extra-*` pour les noyaux `generic` (absent des noyaux
`virtual`). `mount -t ntfs3` est toujours demandé explicitement : `-t ntfs`
désigne selon les versions un alias en lecture seule ou un autre pilote.

## Côté Windows (micro-Windows)

Installé dans `C:\Rago\agent\` par `windows/compile_micro_engine.ps1`
(`-AgentPath`, défaut `windows\rago-agent`).

| Moment | Qui | Quoi |
|---|---|---|
| Chaque démarrage | tâche `\Rago\Boot` (SYSTEM) → `rago-agent.ps1 -Boot` | « running » dans RAGO-COMM, RAGO-LIB en ligne sur `L:` (trouvée par son PARTUUID, noté par Linux dans `library\partition.json`), droits d'écriture des Utilisateurs, finalisation des jeux |
| Session du joueur | `rago-shell.ps1` → `rago-agent.ps1 -Session` (fenêtre) | prend les requêtes, ouvre le client officiel au bon endroit, suit l'installation, écrit les résultats et la fiche du jeu (`L:\.rago\games\<clé>.json`) |
| Arrêt / redémarrage | script d'arrêt de la stratégie locale (SYSTEM) → `rago-agent.ps1 -Shutdown` | vide, met RAGO-LIB hors ligne, « off » dans RAGO-COMM |
| Menu `[B]` du shell | joueur | état, relancer la fenêtre, abandonner une requête |

Ce que fait chaque client :

- **Steam** : client installé depuis l'adresse de Valve si absent (signature
  Authenticode « Valve » vérifiée), puis `steam://install/<id>` ; le joueur
  choisit la bibliothèque `L:\Games\Steam` (« Ajouter un dossier de
  bibliothèque » la première fois). Fini quand le manifeste
  `appmanifest_<id>.acf` de RAGO-LIB dit « installé ». Lancement :
  `steam.exe -silent steam://rungameid/<id>`.
- **Epic** : lanceur installé par son MSI officiel si absent (signature
  « Epic Games »), puis l'URI d'installation ; le joueur choisit
  `L:\Games\Epic`. Fini quand le manifeste `.item` du lanceur pointe sur
  RAGO-LIB sans installation en cours. Lancement :
  `com.epicgames.launcher://apps/<espace>%3A<article>%3A<AppName>?action=launch&silent=true`.
- **Riot** : installateur officiel du jeu (signature « Riot Games ») ; le
  joueur choisit `L:\Games\Riot` dans « Options avancées » (aucune option
  documentée pour le faire sans lui). Fini quand les fichiers principaux du
  jeu sont là. Lancement : `RiotClientServices.exe --launch-product=<id>
  --launch-patchline=live`. **Riot Vanguard** s'installe avec le jeu et
  bloque « Jouer » jusqu'au redémarrage de Windows.

Les jeux installés **ailleurs** que sur RAGO-LIB sont signalés en échec (à
désinstaller puis réinstaller dans le bon dossier) : rien n'est déplacé en
douce.

### Finalisation (« VC++ / .NET / registre »)

Les prérequis propres à chaque jeu (VC++, DirectX, .NET, clés de registre)
sont installés **par le client officiel** : Steam rejoue les scripts
d'installation du jeu au premier lancement, Epic installe les prérequis à
l'installation. L'agent, au démarrage :

- vérifie le runtime VC++ 2015-2022 (x64 et x86) et, s'il manque, installe
  ceux que le joueur a mis dans `C:\Rago\redist` (`-RedistPath` de la
  construction, même mécanisme que M5 ; Rago ne les télécharge pas) ;
- après une **reconstruction** du micro-Windows (C: neuf, jeux toujours sur
  RAGO-LIB), remet les métadonnées des clients gardées dans
  `L:\.rago\cache\` (manifeste `.item` d'Epic, `product_settings.yaml` de
  Riot) : **méthode non officielle, à vérifier** ; la méthode documentée par
  Epic reste « installer, annuler, recopier, reprendre, Vérifier », et Riot
  vérifie les fichiers si on lui désigne le dossier existant ;
- note la finalisation dans la fiche du jeu, pour CETTE installation de
  Windows (`MachineGuid`).

## Ce que Linux ne fait jamais

- installer un jeu Windows lui-même, ou écrire dans les dossiers des jeux
  (le correcteur de League vérifie la taille et la date de chaque fichier) ;
  Linux n'écrit que `.rago\` ;
- monter RAGO-LIB en écriture sur un doute, ou avec `force` ;
- utiliser ntfs-3g (FUSE).
