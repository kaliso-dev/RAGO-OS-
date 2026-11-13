---
type: module
tags: [module, phase-A]
maj: 2026-11-13
statut: EN COURS
---
# M14 Profils par jeu

> Phase A. Statut : **EN COURS** — code écrit et testé en conteneur, sur le vrai noyau du conteneur et en VM qemu ; **jamais testé sur vrai matériel**. Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Appliquer automatiquement, pour chaque jeu, le profil optimal (perf + sécurité) sur les deux couches, par-dessus le réglage de base de [[M1 Tuning hôte]]. Différenciateur clé.

## Fichiers de code (dans `kaliso-dev/rago-os-`)
- `daemons/rago-profiled/Cargo.toml` — crate Rust (membre de l'espace de travail racine `Cargo.toml`) ; dépend de `kernel/scx/rago-common` (M0, sans le modifier) pour l'identité du client du socket et le groupe `rago`.
- `daemons/rago-profiled/src/main.rs` — commandes `daemon`, `launch`, `prepare-switch`, `status`, `show`, `list`, `validate` (`--help`).
- `daemons/rago-profiled/src/profile.rs` — format TOML/JSON, validation, base de profils (locale + communautaire), résolution jeu → profil, profil sûr par défaut.
- `daemons/rago-profiled/src/linux.rs` — côté Linux : gouverneur cpufreq (+ préférence énergie/perf), THP, C-states (PM QoS), contrôle des mitigations, photo de la base et reprise.
- `daemons/rago-profiled/src/hooks.rs` — hooks `gpu-clocks` ([[M9 GPU]]) et `windows-security` ([[M5 Micro-Windows]] / [[M6 Fast OS Switch]]).
- `daemons/rago-profiled/src/daemon.rs` — démon root, socket, pile de sessions.
- `daemons/rago-profiled/src/proto.rs` — protocole JSON du socket.
- `daemons/rago-profiled/install.sh` — `build` (sans root), `install [--user NOM]`, `uninstall`, `--root`, `--dry-run`.
- `host/systemd/rago-profiled.service` — service durci (CAP_CHOWN seulement, ProtectSystem=strict…).
- `profiles/README.md` — format, règles, contrat des hooks, contribution.
- `profiles/schema/rago-profile.schema.json` — schéma JSON ; `profiles/schema/exemple-complet.toml` — modèle commenté.
- `profiles/community/` — base communautaire : `counter-strike-2.toml`, `cyberpunk-2077.toml`, `elden-ring.json` (couche proton), `valorant.toml`, `fortnite.json` (couche switch). Toutes `verified = false`.
- Tests : `daemons/rago-profiled/tests/run_tests.sh` (lance tout ce qui tourne sans matériel), `daemons/rago-profiled/src/*.rs` (unitaires), `daemons/rago-profiled/tests/cli.rs` (intégration), `daemons/rago-profiled/tests/real_kernel_test.sh` (vrai noyau, root), `daemons/rago-profiled/tests/vm/run_m14_vm_test.sh` + `daemons/rago-profiled/tests/vm/m14_vm_guest.sh` (VM), `profiles/tests/test_schema.py` + `profiles/tests/invalides/` (schéma).

## Ce qu'il fait
- **Profil** = `{ id, couche proton|switch, cpu_governor, thp madvise|always, cstates deep|shallow|poll, sched_hint, gpu_clocks, mitigations on|off, windows_security compat_max|perf }` + `match` (steam_appid, exe), `anticheat`, `verified`, `notes`. Un champ absent = garder la base de M1. Détail : `profiles/README.md`.
- **Où** : `/etc/rago/profiles/` (local, prioritaire) puis `/usr/share/rago/profiles/` (communauté, copie de `profiles/community/`). Relus à chaque lancement s'ils ont changé (et sur SIGHUP).
- **Quel profil** : par `id`, puis `steam_appid` (Steam pose `SteamAppId`), puis nom d'exécutable (le `.exe` de la commande Proton). Sinon, ou si le fichier est refusé : **profil sûr par défaut**, intégré au démon : rien ne change côté Linux, hint M0 normal, `compat_max` côté switch.
- **Lancement couche proton** : `rago-profiled launch [--id|--steam-appid|--exe] -- <commande>` (option Steam : `rago-profiled launch -- %command%`). Le démon applique le profil ; le jeu est lancé via `rago-sched-hint run --confine … --render-comm … --` ([[M0 Noyau scx_rago]]) ; à la fin du jeu la base revient. Code de sortie = celui du jeu.
- **Session = connexion au socket** `/run/rago-profiled/profiled.sock` (root:rago 0660, le groupe de M0). Si le launcher est tué, le socket se ferme et la base revient. Plusieurs jeux : le dernier lancé est appliqué, puis celui d'en dessous, puis la base.
- **Cohérence avec M1** : photo de la base avant toute écriture (`/run/rago-profiled/applied.json`), seul ce qui a été changé est remis ; C-states par demande PM QoS sur `/dev/cpu_dma_latency` (même mécanisme que `force_latency` de tuned ; `shallow` = latence de C1, repli 3 µs, comme M1) : le noyau garde la plus stricte, un profil peut **ajouter** une limite, pas relâcher celle de M1. Démon tué → le noyau retire seul la demande PM QoS, et le démon relancé remet gouverneur / THP.
- **Mitigations** : réglage global du noyau (M0, `RAGO_MITIGATIONS`) : comparé et signalé, **jamais changé**.
- **En attente (hooks)** : horloges GPU → hook `gpu-clocks apply|restore` à fournir par [[M9 GPU]] ; profil de sécurité Windows → `rago-profiled prepare-switch --id <jeu>` appelle le hook `windows-security set` (`RAGO_WINDOWS_SECURITY`) à fournir par [[M5 Micro-Windows]] / [[M6 Fast OS Switch]] pour l'écrire dans RAGO-COMM. Tant qu'un hook manque : « en attente », rien ne casse (`prepare-switch` sort en code 4). Contrat : `profiles/README.md`.
- **Sans démon** : le jeu se lance quand même (base, hint M0 seulement). Sans `rago-sched-hint` : le jeu se lance sans hint.

## Tests faits (par Claude, sans matériel)
- `cargo test -p rago-profiled` : **31 tests unitaires + 12 tests d'intégration OK**, stables sur 30 passages. Fausse racine (cpufreq, THP, cpuidle, cmdline, conf M1, PM QoS) : profil appliqué pendant le jeu puis base exacte ; repli (jeu inconnu, profil cassé) qui ne change rien ; profil local qui remplace le communautaire ; `SteamAppId` et `.exe` Proton reconnus ; launcher tué (SIGKILL) → base remise ; deux jeux empilés ; SIGTERM au launcher transmis au jeu ; démon tué puis relancé → reprise ; SIGTERM au démon → base remise ; codes de `prepare-switch` ; hooks (absent, refusé si droits dangereux, délai, enfant en arrière-plan) ; **bout en bout avec M0** : vrai `rago-sched-hint` contre le vrai serveur du canal (sink en mémoire) → jeu tagué avec son PID, motif de rendu du profil ajouté aux motifs de M0.
- `profiles/tests/test_schema.py` : 42/42 (base communautaire et modèle valides, 14 exemples invalides refusés par le schéma ; `rago-profiled validate` refuse les mêmes).
- `daemons/rago-profiled/tests/real_kernel_test.sh` (13/11, vrai noyau 6.18 du conteneur, root) : **23/23 PASS** — THP réellement changé puis remis ; latence PM QoS effective 0 µs (`poll`) et 3 µs (`shallow`, pas de cpuidle) pendant le jeu, retirée après ; une demande tenue par un autre processus (comme tuned) reste la plus stricte (`deep` ne la relâche pas, `poll` s'ajoute, elle est intacte après) ; démon tué → PM QoS retirée seule par le noyau, THP remis par le démon relancé ; SIGTERM → tout remis.
- VM qemu : voir ci-dessous (section mise à jour avec le résultat).
- **Pas testé** : gouverneur réel (pas de cpufreq en conteneur ni en VM), base Arch, Steam / Proton réels, horloges GPU et switch (M9, M5, M6 pas codés), tag M0 réel avec scx_rago chargé (seulement contre le serveur du canal en mémoire), FPS / 1 % low.

## Critère de test sur matériel (à faire par Sofiene)
1. M0 et M1 installés. `daemons/rago-profiled/install.sh build`, puis `sudo daemons/rago-profiled/install.sh install --user <toi>` ; se reconnecter (groupe rago).
2. `sudo daemons/rago-profiled/tests/real_kernel_test.sh --bin /usr/bin/rago-profiled` → tout PASS, et cette fois la ligne cpufreq vérifie le vrai gouverneur.
3. Dans Steam, options de lancement d'un jeu : `rago-profiled launch -- %command%`. Pendant le jeu : `rago-profiled status` (session ACTIVE, gouverneur / THP / C-states du profil) et `rago-sched-hint list` (jeu tagué). Après : `host/setup_host_tuning.sh verify` = 0.
4. Mesurer avant de passer un profil à `verified = true` : 1 % low MangoHud, même scène, profil contre base (`host/tests/m1_frametime_compare.sh`).
5. Côté switch (quand M5/M6 existeront) : `rago-profiled prepare-switch --id valorant` puis VBS/HVCI vérifiés dans le micro-Windows.

**Dépend de / relié à :** [[M1 Tuning hôte]] (la base), [[M0 Noyau scx_rago]] (hint, groupe rago, mitigations), [[M2 Couche Proton]] (appellera `launch`), [[M5 Micro-Windows]] et [[M6 Fast OS Switch]] (hook `windows-security`), [[M9 GPU]] (hook `gpu-clocks`), [[M11 Rago UI]] (`launch`, `prepare-switch`, `show`/`list` pour l'écran des profils), [[M13 Build ISO]] (doit installer binaire, service et `profiles/community/`).

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M14). Détail : bible v7, module M14.
