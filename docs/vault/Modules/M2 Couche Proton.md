---
type: module
tags: [module, phase-A]
maj: 2026-11-13
statut: EN COURS
---
# M2 Couche Proton

> Phase A. Statut : **EN COURS** — code écrit le 13/11/2026, testé sans matériel (conteneur, chroot Ubuntu 25.10 avec les vrais paquets) ; **jamais testé sur vrai matériel**. Branche `claude/project-thread-8h2mbw`, PR #5 vers `main` (à relire). Affichage, VRR, HDR, tearing, `--rt`, FPS et effet du pré-chauffage : **en attente de matériel**. Retour à [[Projet]], carte [[Architecture]], vue d'ensemble [[Couche Proton]].

**Objectif.** Jeu natif Linux d'élite (Proton), avec les accroches profils ([[M14 Profils par jeu]]) et hint ordonnanceur ([[M0 Noyau scx_rago]]), par-dessus la base [[M1 Tuning hôte]].

## Fichiers de code (dans `kaliso-dev/rago-os-`)
- `host/setup_proton_layer.sh` — installateur : `deps` (paquets apt / pacman, `--enable-32bit`), `install`, `verify` / `status`, `uninstall`, `lock` (épinglage Proton-GE / Heroic), `user` (côté joueur, sans root, Steam fermé). Options mémorisées dans `/etc/rago/proton-layer.conf`.
- `host/lib/rago_proton_lib.sh` — fonctions communes (réglages, clé du jeu, GPU, cache par GPU, empreinte du pilote Vulkan, options gamescope, environnement de session…), installée dans `/usr/lib/rago/`.
- `host/proton/rago-launch.sh` → `/usr/bin/rago-launch` — **le hook de lancement** (option Steam `rago-launch %command%`, enveloppe Heroic, préfixe Lutris).
- `host/proton/rago-shader-cache.sh` → `/usr/bin/rago-shader-cache` — cache de shaders par GPU + pré-chauffage Fossilize (`gpu`, `status`, `prewarm`).
- `host/proton/rago_steam_config.py` → `/usr/bin/rago-steam-config` — écrit le hook dans Steam (`localconfig.vdf`), Proton-GE par défaut (`config.vdf`), Heroic, Lutris, runtimes EAC / BattlEye.
- `host/proton/sources.lock` — versions épinglées de Proton-GE et Heroic (**PENDING** : GitHub inaccessible depuis l'environnement de Claude).
- `host/gamescope/rago-session.sh` → `/usr/bin/rago-session` — session plein écran console ; `host/gamescope/rago.desktop` → `/usr/share/wayland-sessions/rago.desktop` (entrée du gestionnaire de connexion).
- `host/gamemode/gamemode.ini` → `/etc/gamemode.ini` ; `host/gamemode/40-rago-gamemode.rules` → `/etc/polkit-1/rules.d/`.
- `host/mangohud/MangoHud.conf` → `/etc/MangoHud.conf`.
- `host/systemd/user/rago-shader-prewarm.service` — pré-chauffage en fond (service utilisateur).
- `host/pacman/rago-gamescope-cap.hook` — remet `cap_sys_nice` sur gamescope après chaque mise à jour du paquet (Arch).
- Tests : `host/tests/run_m2_tests.sh` (lance tout), `host/tests/test_proton_lib.sh`, `host/tests/test_steam_config.py`, `host/tests/test_proton_sysroot.sh`, `host/tests/test_rago_launch.sh`, `host/tests/chroot/run_m2_chroot_test.sh` + `host/tests/chroot/m2_chroot_guest.sh`.

## Ce qu'il fait
**Paquets** (`deps`) : Steam, gamemode, MangoHud (+ mangoapp), gamescope, polkit, libcap ; Lutris si `--lutris`. Debian / Ubuntu : Steam et gamescope sont dans `/usr/games` (absent du PATH de `sudo`) : les scripts l'ajoutent eux-mêmes.

**Proton-GE épinglé** : archive vérifiée (sha512 de `sources.lock`) installée dans `/usr/share/steam/compatibilitytools.d/<version>/`, proposée comme outil Steam par défaut **seulement si le joueur n'en a pas choisi** (`--default-proton keep` pour ne rien toucher). Tant que `sources.lock` est PENDING, Proton-GE est sauté avec un avertissement (Steam garde son Proton). **Heroic** pareil (paquet .pacman / .deb épinglé). **Lutris** optionnel.

**Runtimes EAC / BattlEye** : Steam les installe avec le premier jeu qui en a besoin (« Proton EasyAntiCheat Runtime », « Proton BattlEye Runtime ») ; `rago-steam-config runtimes` note leurs chemins et `rago-launch` les donne aux jeux hors Steam (Heroic, Lutris) par `PROTON_EAC_RUNTIME` / `PROTON_BATTLEYE_RUNTIME`. Rien n'est caché ni contourné : ce sont les runtimes officiels de Valve.

**Hook de lancement `rago-launch`**, dans l'ordre :
1. caches de shaders **par GPU et par jeu** (`~/.local/share/rago/shader-cache/<pilote>-<vendor>-<device>/<jeu>/` : Mesa, NVIDIA, DXVK, vkd3d-proton), seulement pour les variables que Steam / Proton n'ont pas déjà posées ; il note l'environnement de cache du jeu pour que le pré-chauffage remplisse le même cache ;
2. jeux hors Steam : runtimes EAC / BattlEye ;
3. pré-chauffage avant le jeu si `RAGO_SHADER_PREWARM=before` ; sinon le pré-chauffage de fond se met en pause tant qu'un jeu tourne (marque dans `$XDG_RUNTIME_DIR/rago/games/`) ;
4. lance `rago-profiled launch --exe <exe> -- gamemoderun mangohud <jeu>` : **profil M14** par-dessus la base M1 (base remise à la fin), et M14 passe lui-même par `rago-sched-hint run` (**hint M0**). Sans rago-profiled : `rago-sched-hint run` seul ; sans les deux : le jeu seul. **Le jeu se lance toujours.** `exec` garde le même PID (Steam suit le jeu, SIGTERM transmis).
Réglages : env > `~/.config/rago/proton-layer.conf` > `/etc/rago/proton-layer.conf` (`RAGO_GAMEMODE`, `RAGO_MANGOHUD`, `RAGO_SHADER_CACHE`, `RAGO_PROFILE_ID`…). Ex. : `RAGO_MANGOHUD=0 rago-launch %command%`.

**Branché dans Steam sans clic** : `rago-steam-config sync` écrit `rago-launch %command%` dans les options de lancement de chaque jeu installé (Steam fermé : il réécrit sa config en quittant) ; l'option déjà posée par le joueur est gardée (`PROTON_LOG=1 %command% -novid` devient `PROTON_LOG=1 rago-launch %command% -novid`) ; un jeu dont le joueur a retiré le hook n'est plus touché ; `unsync` remet tout comme avant. La session Rago le refait à chaque démarrage, avant Steam.

**Session gamescope** (`rago-session`) : gamescope prend l'écran, Steam démarre en Big Picture (`steam -gamepadui`). Options : `-e`, `--xwayland-count 2`, `--adaptive-sync` (VRR), `--hdr-enabled` (+ `--hdr-itm-enabled` en option), `--immediate-flips` (tearing en jeu), `--rt` (gamescope reçoit `cap_sys_nice` à l'install), `--mangoapp` (HUD réglable depuis le menu rapide de Steam). Variables `STEAM_GAMESCOPE_*` pour que Steam affiche les réglages VRR / HDR / tearing. Mode natif de l'écran par défaut ; `RAGO_SESSION_WIDTH/HEIGHT/REFRESH`, `_OUTPUT`, `_VK_DEVICE`, `--nested` pour essayer sur un bureau.

**gamemode** : garde seulement la priorité d'E/S, l'écran de veille bloqué et le signal « GameMode actif ». Il **ne touche pas** au gouverneur (M14 / M1), aux cœurs (M0), au renice / temps réel (M0), au split lock (M1), au GPU ([[M9 GPU]]) : `gamemode.ini` + règle polkit `40-rago-gamemode.rules` qui refuse ses 4 assistants (gouverneur, cœurs, GPU, sysctl) et passe avant la règle `gamemode.rules` du paquet.

**MangoHud** : `/etc/MangoHud.conf` (compact : FPS, 1 % low, temps d'image, CPU / GPU, RAM / VRAM, GameMode ; Shift droit + F12 pour cacher) ; le réglage du joueur (`~/.config/MangoHud/`) reste prioritaire.

**Pré-chauffage des shaders** : `rago-shader-cache prewarm` rejoue les bases Fossilize de chaque jeu (celles de Steam et celles capturées par Rago pour les jeux hors Steam) avec `fossilize-replay` en priorité basse, dans le cache du jeu pour **son** GPU ; tampon par base (rien n'est refait sans changement) ; tout est rejoué si le pilote Vulkan change ; pause automatique pendant un jeu ; délai max ; verrou (un seul à la fois). `fossilize-replay` : paquet sur Arch, sinon celui de Steam (`ubuntu12_64/fossilize_replay`) ; absent → « en attente » (code 4). Stockage : par défaut sous `~/.local/share/rago/shader-cache` ([[M7 Bibliothèque partagée]] pourra le déplacer vers RAGO-LIB : `--shader-cache-root`).

## Tests faits (13/11/2026, sans matériel)
- `host/tests/test_proton_lib.sh` : **94/94** (fonctions pures : réglages, clés, GPU, cache, options gamescope, environnement).
- `host/tests/test_steam_config.py` : **22/22** (VDF Steam lu / écrit, option du joueur gardée, retrait, Proton-GE par défaut, Steam en cours → refus, Heroic, Lutris, runtimes).
- `host/tests/test_proton_sysroot.sh` : **64/64** (install / verify / uninstall en fausse racine, Proton-GE au bon hash installé et au mauvais hash **refusé**, fichiers d'avant remis).
- `host/tests/test_rago_launch.sh` : **72/72** avec les **vrais binaires** `rago-profiled` (démon + launch, fausse racine comme les tests de M14) et `rago-sched-hint` : profil Cyberpunk appliqué pendant le jeu (THP `always` vu par le jeu), base M1 remise après (`madvise`), jeu inconnu → rien ne bouge, SIGTERM transmis, démon arrêté → jeu lancé quand même, code du jeu rendu ; pré-chauffage (bases rejouées dans le cache du jeu, tampon, pilote changé, échec refait, pause pendant un jeu, délai, verrou).
- `host/tests/chroot/run_m2_chroot_test.sh` (root, chroot Ubuntu 25.10, **vrais paquets**, pas de systemd) : **116/116**. `deps --enable-32bit` par le vrai apt (526 paquets : Steam 1.0.0.83, gamescope 3.16.15, gamemode 1.8.2, MangoHud 0.7.2, polkit 126) ; `install`, `verify` (0 échec, 3 points « matériel »), réinstallation identique, `uninstall` (tout remis comme avant, paquets gardés) ; les 15 options gamescope produites existent dans `gamescope --help` ; `cap_sys_nice` vu par le vrai gamescope lancé en joueur ; **vrai polkitd** : sans la règle Rago, `gamemode.rules` autorise les 4 assistants au joueur du groupe gamemode, avec elle les 4 sont refusés ; **vrai gamemoded** : lit `/etc/gamemode.ini`, le jeu est inscrit, le changement de gouverneur est refusé (« Not authorized »), pas de pin / park / renice, relâché après le jeu ; vraie chaîne `rago-launch` → `rago-profiled launch` → `rago-sched-hint run` → `gamemoderun` → `mangohud` → jeu (code rendu) ; MangoHud (vrai calque Vulkan sur lavapipe) lit `/etc/MangoHud.conf` sans option inconnue ; `user` en joueur ; pré-chauffage « en attente » sans `fossilize-replay`. **La session gamescope elle-même ne démarre pas ici** : gamescope 3.16 exige un GPU Vulkan avec `VK_EXT_physical_device_drm`, que le Vulkan logiciel (lavapipe) n'a pas → en attente de matériel.
- Ce test a trouvé 4 vrais défauts, corrigés : gamescope jamais installé par `deps` (« apt-cache | grep -q » faux avec pipefail) ; steam, gamescope et gamemoderun introuvables dans `/usr/games` (Debian / Ubuntu) ; `apply_gpu_optimisations=0` faisait écrire une erreur à gamemoded à chaque jeu ; la vérification polkit demandait polkitd en marche.
- Tout d'un coup : `host/tests/run_m2_tests.sh` (sans root) ; `--chroot` ajoute le test avec les vrais paquets (root).
- `shellcheck` propre sur tous les scripts.

## Pas encore testé — EN ATTENTE DE MATÉRIEL
- La session gamescope démarrée (impossible sans GPU, voir plus haut), puis affichage plein écran, VRR, HDR, tearing en jeu et `--rt` sur un vrai écran / GPU.
- mangoapp (HUD de la session) : absent du paquet mangohud d'Ubuntu 25.10, la session part alors sans HUD (MangoHud par jeu à la place).
- Priorité d'E/S de gamemode : en chroot (noyau 6.18), gamemode l'a sautée (« ioprio was (0) but we expected (4) ») ; à regarder sur la vraie machine ([[Questions ouvertes]]).
- FPS, 1 % low, saccades de compilation de shaders avec / sans pré-chauffage.
- Un vrai jeu Proton (et un jeu EAC / BattlEye compatible Linux) lancé par Steam avec le hook.
- Vrai Steam démarré (il se télécharge au premier lancement) : formats `localconfig.vdf` / `config.vdf` réels, fossilize de Steam.
- Proton-GE et Heroic : pas encore épinglés (`host/setup_proton_layer.sh lock` à lancer avec accès GitHub).
- Base Arch / base Rago : seulement Ubuntu 25.10 testé.

## Critère de test sur la vraie machine
1. `sudo host/setup_proton_layer.sh deps --enable-32bit`, `sudo host/setup_proton_layer.sh install`, puis `host/setup_proton_layer.sh verify` : 0 échec.
2. Démarrer Steam une fois (connexion), le fermer, puis `host/setup_proton_layer.sh user` : « hook rago-launch dans les options de lancement ».
3. Se déconnecter, choisir la session « Rago » : Steam Big Picture plein écran ; menu rapide : VRR, HDR, tearing proposés.
4. Lancer un jeu Proton : MangoHud visible, `rago-profiled status` montre le profil du jeu, `gamemoded -s` actif, `cat /sys/kernel/mm/transparent_hugepage/enabled` suit le profil (ex. Cyberpunk : `always`), puis revient à la base à la fin.
5. `rago-shader-cache status` puis `rago-shader-cache prewarm` : comparer les saccades d'un premier lancement avec / sans pré-chauffage (MangoHud, temps d'image).

**Dépend de / relié à :** [[Couche Proton]], [[M0 Noyau scx_rago]], [[M1 Tuning hôte]], [[M14 Profils par jeu]], [[M9 GPU]] (horloges GPU : pas gamemode), [[M7 Bibliothèque partagée]] (emplacement du cache).

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M2). Détail : bible v7, module M2.
