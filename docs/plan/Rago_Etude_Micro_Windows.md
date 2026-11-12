# ÉTUDE & CONCEPTION — Le Micro-Windows (moteur de jeu Rago)

> Étude de l'anatomie de Windows pour déterminer **exactement** ce qu'on peut retirer, ce qui est vital, et **jusqu'où** descendre — sans jamais casser les jeux ni l'anti-triche. Nettoyage standard et documenté (DISM/WinSxS), comme le font tiny11/NTLite/Windows IoT. Aucune dissimulation.
> Vérifié nov. 2026 (tiny11/nano11, NTLite, exigences anti-triche Vanguard On-Demand / EAC / BattlEye / EA Javelin).

---

## 1. Anatomie de Windows (ce qui compose le système)

De bas en haut, les couches qui doivent coexister pour qu'un jeu + son anti-triche tournent :

| Couche | Rôle | Vital pour un jeu ? |
|---|---|---|
| **Chaîne de boot UEFI** (bootmgr, winload) + **Secure Boot / TPM** | Démarrage vérifié | **OUI — exigé par l'anti-triche** |
| **Noyau NT** (`ntoskrnl.exe`) + **HAL** | Cœur du système | **OUI, incompressible** |
| **Pile de boot drivers** (stockage, etc.) | Accès disque au boot | **OUI** |
| **Session Manager** (`smss`), **csrss**, **wininit/winlogon** | Initialisation des sessions | **OUI** |
| **Sous-système Win32 / `win32k.sys`** | API graphique/fenêtrage que les jeux appellent | **OUI** |
| **Pile graphique WDDM + pilote GPU + DirectX/DXGI** | Rendu 3D | **OUI, incompressible** |
| **Runtimes** : **.NET**, **Visual C++ redistribuables** | Dépendances des jeux | **OUI** |
| **Pile réseau** (TCP/IP, Winsock) | Jeux en ligne | **OUI** |
| **Pilote anti-triche** (vgk, EAC, BattlEye) + service SYSTEM | L'anti-triche lui-même | **OUI** |
| **Services Windows** (centaines) | Fonctions système | **La plupart NON** |
| **Shell** (`explorer.exe`, barre des tâches, menu Démarrer) | Bureau | **NON** |
| **WinSxS** (magasin de composants) | Réparation/mise à jour | **NON** (au prix de la non-serviçabilité) |
| **Apps UWP, Store, Edge, Cortana, Search, Defender…** | Extras grand public | **NON** |

**Le principe clé** (confirmé par tiny11, approche "soustraction") : on retire **avant l'installation**, par **DISM** sur l'image montée — pas par des scripts post-install fragiles qui cassent aux updates.

---

## 2. Ce qu'on RETIRE (et jusqu'où)

### Retirable sans risque (gain RAM + disque) :
- **Toutes les apps UWP/Store** (Xbox app sauf si besoin des services de jeu, Cortana, Widgets, OneDrive, Mail, Photos…).
- **Microsoft Edge / IE hérité**.
- **Windows Search / indexation** (`SearchIndexer`) — gros consommateur RAM/IO.
- **Télémétrie / DiagTrack**, rapports d'erreurs, expériences consommateur.
- **Spouleur d'impression**, Fax, services de maintenance planifiée, SysMain (superfetch).
- **WinRE** (environnement de récupération).
- **Langues superflues**, Retail Demo, caches.
- **Le Shell** : `explorer.exe` remplacé → suppression du bureau/barre des tâches. **C'est le plus gros gain mémoire.**

### Retirable mais avec décision :
- **Windows Defender** : retirable (tiny11 le désactive). **Nuance anti-triche** : certains jeux/AC préfèrent voir un AV actif ; et Defender participe à la posture de sécurité que l'attestation anti-triche peut évaluer. → **Garder désactivable, pas forcément retiré.** À trancher par jeu.
- **WinSxS (magasin de composants)** : sa suppression (technique tiny11 core, "essai-erreur") rend le système **non-serviçable** (Windows Update feature-updates cassés). **Pour Rago, c'est ACCEPTABLE et même souhaitable** : notre moteur est **sans état et reconstruit** à chaque version — on n'a pas besoin de Windows Update. C'est un gain disque majeur que tiny11 doit limiter mais que **nous pouvons pousser plus loin**.
- **.NET précompilé (NativeImages)** : nano11 le retire pour l'espace, au prix d'un premier lancement plus lent. À évaluer.

### À NE JAMAIS retirer :
Noyau NT, HAL, chaîne de boot, **Secure Boot/TPM/VBS/HVCI** (voir §3), **win32k/Win32**, **WDDM + pilote GPU + DirectX**, **.NET**, **VC++**, **pile réseau**, le **pilote anti-triche**, et les composants dont dépend le Shell de remplacement (`Kerberos Client`/`SMB Common` sont requis pour que le shell fonctionne — point documenté NTLite).

---

## 3. Les exigences de l'anti-triche (la limite basse — et une découverte clé)

C'est **la contrainte qui fixe le plancher du dépouillement**. On ne descend pas en dessous.

**Prérequis matériels/firmware communs (kernel anti-cheat 2026) :**
- **Secure Boot** activé + **TPM 2.0** — exigés par Vanguard et Ricochet (compétitif), EA Javelin (BF6), etc. (BattlEye/EAC : TPM optionnel mais recommandé.)
- **Windows en mode UEFI + disque GPT**.

**🔑 Découverte majeure — Vanguard On-Demand (2026) :** Riot a introduit un mode où **l'anti-triche ne se charge plus au boot, mais au lancement du jeu, et se décharge à la fermeture** — **à condition** que le PC ait **Windows 11 25H2 + Secure Boot + TPM 2.0 + VBS + HVCI + IOMMU** tous activés. L'anti-triche fait alors confiance à la chaîne de boot vérifiée au lieu de tout surveiller lui-même.

**Pourquoi c'est énorme pour Rago :** c'est **exactement notre modèle** — on boote dans le jeu, on joue, on quitte. Un moteur de jeu éphémère avec une chaîne de boot durcie **coche toutes les cases**. L'industrie de l'anti-triche **converge vers le design de Rago**. → Notre micro-Windows doit donc :
- Être **Windows 11 25H2+**,
- Garder **Secure Boot, TPM 2.0, VBS, HVCI, IOMMU ACTIVÉS** (ne pas les stripper !),
- Ce qui satisfait **le plus strict des anti-triche** tout en étant la posture de sécurité moderne.

**Nuance de perf à acter :** VBS/HVCI ont un **léger coût FPS** et activent le **blocklist de pilotes vulnérables** de Microsoft (peut bloquer de vieux pilotes RGB/capture). → Pour les jeux qui n'exigent **pas** VBS/HVCI (beaucoup de BattlEye/EAC), on peut proposer un **profil "perf"** avec VBS off ; pour Vanguard/Ricochet compétitif, un **profil "compatibilité maximale"** avec tout activé. **Configurable par jeu.** C'est une vraie valeur Rago : router le bon profil de sécurité selon le titre.

---

## 4. Jusqu'où descendre : les planchers réels

| Référence | Disque installé | RAM idle | Serviçable ? |
|---|---|---|---|
| Windows 11 standard | ~20-25 Go | ~2-4 Go | Oui |
| **tiny11** | ~8-10 Go | ~1-1,5 Go | Partiellement |
| **tiny11 core / nano11** (extrême) | ~3-5 Go (image compressée ~700 Mo) | quelques centaines de Mo | **Non** |
| **Cible Rago (moteur sans état)** | **~2-3,5 Go** | **~300-500 Mo** | **Non (assumé)** |

**Pourquoi Rago peut viser le bas de la fourchette** : parce qu'on **assume la non-serviçabilité** (pas de Windows Update — on reconstruit l'image) et qu'on **supprime le Shell** (lancement direct du jeu). tiny11 doit garder un système utilisable au quotidien ; nous, non — c'est un **moteur d'exécution jetable**.

**Le point de rupture (à ne pas franchir)** : en dessous de ce qui fait tourner jeux + AC — c'est-à-dire si on touche au noyau NT, à Win32k, à WDDM/DirectX, aux runtimes, à la pile réseau, ou à la chaîne de sécurité exigée par l'AC — **le jeu ne lance plus ou l'AC refuse**. Le "Windows de quelques Mo" est de l'autre côté de ce mur : impossible.

**L'empreinte qui compte** : la **RAM idle (~300-500 Mo)**, obtenue surtout en **supprimant le Shell et les services**, pas en grattant le disque. Le disque (~2-3,5 Go) est incompressible sous ~2 Go car les runtimes + la pile graphique pèsent ce qu'ils pèsent.

---

## 5. La méthode (pipeline de construction)

1. **Base** : Windows 11 **IoT Enterprise LTSC** (25H2) — déjà la plus mince licenciable, sans Store ni appx grand public, cycle long. **BYOL** : l'utilisateur fournit son ISO/licence ; Rago construit localement.
2. **DISM offline** (`compile_micro_engine.ps1`) : monter le WIM, `Remove-AppxProvisionedPackage`, `Remove-WindowsCapability`/`Disable-WindowsOptionalFeature`, purge ciblée du **WinSxS** (gain disque, non-serviçabilité assumée).
3. **Ruche SYSTEM offline** : désactiver les services non critiques (`SysMain`, `DiagTrack`, `WSearch`, `Spooler`, `wuauserv`, indexation) ; **forcer les services anti-triche en automatique**.
4. **Shell** : `Winlogon\Shell` = `rago-shell` (lance le jeu plein écran, surveille, déclenche le retour). Réversible pour maintenance.
5. **autounattend.xml** : OOBE sauté, **compte local RagoPlayer AutoLogon silencieux, aucun compte Microsoft, aucun écran de connexion/verrouillage**, pas de BitLocker.
6. **Garder activés** : Secure Boot, TPM, VBS/HVCI/IOMMU (profil compatibilité) + pilote GPU + DirectX + .NET + VC++.
7. **Tester un JEU RÉEL + son anti-triche** (pas seulement "Windows démarre").

---

## 6. Innovations de conception Rago

1. **Profils de sécurité par jeu** : "compatibilité max" (VBS/HVCI/IOMMU on → Vanguard On-Demand, Ricochet) vs "perf" (VBS off → BattlEye/EAC, FPS max). Rago choisit le bon profil selon le titre. Personne ne fait ça.
2. **Exploiter Vanguard On-Demand** : aligner le micro-Windows sur les prérequis 25H2+sécurité → on est dans le sens de l'histoire de l'anti-triche, pas contre.
3. **Non-serviçabilité assumée = dépouillement plus agressif que tiny11** : pas de Windows Update à préserver → on peut purger plus de WinSxS. L'image est reconstruite à chaque version de Rago.
4. **Moteur sans état** : aucune donnée utilisateur dans le micro-Windows (elles vivent côté Linux) → l'image est identique pour tous, reproductible, et peut être pré-cuite (lien avec le resume pré-cuit de l'étude switch).
5. **Shell = jeu** : zéro overhead bureau, et c'est ce qui donne l'empreinte RAM minimale + le lancement direct.

---

## 7. Limites honnêtes

- **Pas de "quelques Mo"** : le plancher fonctionnel est ~2-3,5 Go disque / ~300-500 Mo RAM. En dessous, on casse jeux ou AC.
- **VBS/HVCI** coûtent un peu de FPS et peuvent bloquer de vieux pilotes périphériques (blocklist) — d'où les profils.
- **Licence** : la redistribution d'une image LTSC modifiée se cadre juridiquement ; **BYOL l'évite** (l'utilisateur fournit son Windows).
- **Chaque patch de jeu / version Windows** → reconstruire l'image (automatisable, mais c'est une maintenance réelle).

---

## 8. Récapitulatif des décisions

| Question | Réponse Rago |
|---|---|
| Base | Windows 11 IoT Enterprise LTSC 25H2, BYOL |
| Shell | Supprimé → `rago-shell` lance le jeu |
| WinSxS | Purgé agressivement (non-serviçabilité assumée) |
| Secure Boot / TPM / VBS / HVCI / IOMMU | **GARDÉS activés** (profil compat) — exigés par l'AC moderne |
| Defender | Désactivable, pas forcément retiré |
| Cible | ~2-3,5 Go disque, ~300-500 Mo RAM idle |
| Auth Windows | Aucune (AutoLogon silencieux, zéro login) |
| Profils | "compat max" (Vanguard/Ricochet) vs "perf" (EAC/BattlEye) |

*Cette étude affine le module M5 (micro-Windows) de la bible.*
