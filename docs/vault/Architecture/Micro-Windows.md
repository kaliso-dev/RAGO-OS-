---
type: carte
tags: [architecture]
maj: 2026-11-14
---
# Micro-Windows

Retour à [[Architecture]]. Module : [[M5 Micro-Windows]] (code écrit le 14/11, jamais exécuté ni testé sur matériel). Code : `windows/`.

Windows réduit à un **moteur de jeu invisible** : pas de bureau, pas d'écran de connexion, démarré seulement pour les jeux dont l'anti-triche refuse Linux. Base **Windows 11 Pro 25H2 ou plus** (décision du 14/11 ; « IoT Enterprise LTSC 25H2 » n'existe pas, voir [[M5 Micro-Windows]]), **BYOL** : ISO et licence fournies par le joueur, Rago ne distribue jamais Windows.

**Cibles.** RAM au repos ~300-500 Mo ; disque **5-8 Go** installés (cible donnée par Sofiene le 14/11 pour M5, sans pagefile ni hiberfil ; l'étude de 2026 visait 2-3,5 Go avec une purge de WinSxS que M5 ne fait pas, voir plus bas) ; démarrage ~2-4 s (étude). **Rien n'est encore mesuré** : les rapports de M5 mesurent, ils n'estiment jamais.

**Méthode (M5)** : ablation DISM hors ligne (`windows/compile_micro_engine.ps1`, plan `windows/micro_engine_plan.json`) — Appx, fonctions à la demande, langues en trop, fonctionnalités inutiles, pilotes tiers inutiles, services de bruit / d'interface coupés (jamais ceux de la sécurité), magasin de composants nettoyé (`ResetBase`), sauvegardes / journaux / WinRE effacés, export compressé, CompactOS à l'installation. **Pas de purge totale de WinSxS** (casse comctl32, VC++ 2005/2008, .NET). Shell Winlogon remplacé par le shell Rago (`rago-shell.ps1`, provisoire jusqu'à [[M6 Fast OS Switch]]). `autounattend.xml` : ouverture de session automatique, compte local sans mot de passe, aucun compte Microsoft. Les services des anti-triche sont laissés tels que leur installateur les pose (la bible disait « forcés en automatique » : [[Questions ouvertes]]). **Sans état et mis à jour à la construction** (décisions du 14/11) : hibernation de Windows coupée par défaut (seul Linux hiberne au switch ; reprise de Windows = étude de [[M8 Optimisation switch]]) ; pas de mise à jour en ligne (`wuauserv` coupé + `NoAutoUpdate`, `UsoSvc` et le réparateur `WaaSMedicSvc` gardés) ; cumulatifs courants intégrés par `-UpdatePath` à chaque reconstruction ([[M13 Build ISO]], [[M4 Updates A-B]]).

**À garder activés** (exigés par l'anti-triche moderne) : Secure Boot, TPM 2.0, **VBS, HVCI, IOMMU** → voir [[Vanguard On-Demand]]. Plus noyau NT, WDDM/DirectX, pilote GPU, .NET, VC++, réseau, Defender, pare-feu, liste de blocage des pilotes vulnérables. Deux profils pilotés par [[M14 Profils par jeu]] : `compat_max` (hyperviseur lancé, VBS + HVCI tournent) et `perf` (hyperviseur coupé) ; l'état réel est renvoyé à Linux par la partition FAT32 RAGO-COMM.

**Le mur** : pas de « Windows de quelques Mo » — en dessous de ce qui fait tourner jeu + anti-triche, ça casse.

**Bibliothèque de jeux ([[M7 Bibliothèque partagée]], 14/11)** : les jeux vivent sur une partition NTFS à part, RAGO-LIB (lettre `L:` dans Windows), installés par les clients officiels (Steam, Epic, Riot) dans le micro-Windows ; Linux les liste et dépose des requêtes dans RAGO-COMM. Jamais les deux OS en même temps sur RAGO-LIB : Windows la met hors ligne à chaque arrêt (et la répare au démarrage si elle est marquée « sale »), Linux ne l'écrit que si Windows s'est arrêté proprement et que le volume est propre. Le compte SYSTEM de Windows ne lit rien dans RAGO-LIB (modifiable par le joueur) : la finalisation des jeux se fait dans la session du joueur. Une reconstruction du micro-Windows garde les jeux (côté Windows : métadonnées des clients remises, à vérifier).

Relié à : [[Fast OS Switch]], [[Vanguard On-Demand]], [[Sécurité et boot]], [[M7 Bibliothèque partagée]].
