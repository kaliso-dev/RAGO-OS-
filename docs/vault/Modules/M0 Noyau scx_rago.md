---
type: module
tags: [module, phase-A]
maj: 2026-11-13
statut: EN COURS
---
# M0 Noyau scx_rago

> Phase A. Statut : **EN COURS** — code écrit et testé en VM / conteneur ; **jamais testé sur vrai matériel**. Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Le meilleur noyau possible pour le jeu, signé Secure Boot, avec un ordonnanceur informé par le launcher.

## Fichiers de code (dans `kaliso-dev/rago-os-`)
- `kernel/build_rago_kernel.sh` — pipeline : `deps`, `lock`, `fetch`, `prepare`, `config`, `verify`, `build`, `package`, `scx` (sans root) ; `mok-gen`, `mok-enroll`, `install`, `sign`, `bootloader`, `scx-install`, `secureboot-status` (root). `--help` pour le détail.
- `kernel/lib/rago_kernel_lib.sh` — fonctions pures du build (niveau x86-64, vérification de config, ligne de commande, entrée systemd-boot).
- `kernel/config/rago-gaming.config` — fragment de config documenté (vérifié ligne par ligne après le build de la config).
- `kernel/config/rago-keep.config` — ce que `localmodconfig` ne doit jamais retirer (GPU, USB, réseau, stockage, hibernation).
- `kernel/patches/sources.lock` — sources épinglées (tarball 6.18, config et patchs CachyOS, sha256) ; `kernel/patches/README.md` ; `kernel/patches/local/` (patchs Rago, vide).
- `kernel/scx/scx_rago/` — fork de scx_lavd 1.1.4 ; ajouts : `src/bpf/rago.bpf.c`, `src/bpf/rago.bpf.h`, `src/bpf/rago_intf.h`, `src/rago.rs`, accroches `RAGO:` dans le code lavd. Explication : `kernel/scx/scx_rago/RAGO_FORK.md`.
- `kernel/scx/rago-common/` — brique commune Rust (protocole du socket, topologie, serveur, client, affinité).
- `host/bin/rago-sched-hint/` — outil du launcher (`rago-sched-hint run -- <jeu>`, `tag`, `untag`, `list`, `status`, `topology`).
- `host/systemd/rago-scx.service` — chargement de scx_rago au boot, relance limitée, filet EEVDF+BORE.
- `Cargo.toml` (racine) — espace de travail Rust (scx_rago, rago-common, rago-sched-hint ; depuis le 13/11 aussi `rago-profiled` de [[M14 Profils par jeu]]).
- Tests : `kernel/tests/test_kernel_lib.sh`, `kernel/tests/vm/run_scx_vm_test.sh` + `kernel/tests/vm/vm_init.sh`, `kernel/tests/m0_hardware_test.sh`, `kernel/tests/check_routing.sh`, `kernel/tests/fake_game.c`.

## Ce qu'il fait
- **Noyau** : Linux 6.18 LTS + patchset CachyOS (base + BORE) + config CachyOS, puis `localmodconfig` (sauf `--no-localmodconfig` pour l'ISO) + fragments Rago. PREEMPT, 1000 Hz, MGLRU, Clang ThinLTO (`LLVM=1`), x86-64-v3 (v4 si le CPU l'a), ZRAM, amd-pstate actif + gouverneur performance, `SCHED_CLASS_EXT=y`, BTF, `IKCONFIG_PROC`, hibernation LZ4, lockdown non imposé.
- **Reproductible** : sources vérifiées par sha256, `SOURCE_DATE_EPOCH` = date du commit Rago, utilisateur/hôte de build fixes, manifeste sha256 dans `kernel/out/manifest.txt`.
- **Secure Boot** : clé MOK de la machine (`openssl`, dans `/etc/rago/secureboot/`), inscrite via `mokutil` + MokManager ; noyau et systemd-boot signés par `sbsign` ; chaîne shim → systemd-boot → noyau si `shim-signed` est installé ; modules DKMS signés MOK.
- **mitigations=off** : option exposée, `RAGO_MITIGATIONS=off` dans `/etc/rago/kernel.conf` (défaut : `auto`).
- **scx_rago** : le launcher tague l'arbre de processus du jeu **avant** l'exec via le socket `/run/rago/sched-hint.sock` (root:rago, 0660). En BPF : héritage du tag au fork, thread de rendu reconnu par son nom, boost de latence, routage (X3D : CCD à cache 3D + affinité dure ; Intel hybride : P-cores, fond vers E-cores), garde contre le vol des threads confinés. Détail : [[Noyau et ordonnanceur]].
- **Filet** : si scx_rago s'arrête ou plante, retour automatique à EEVDF + BORE ; le jeu se lance quand même.

## Tests faits (par Claude, sans matériel)
- `cargo test` : 34 tests rago-common + 7 tests rago-sched-hint, OK.
- `kernel/tests/test_kernel_lib.sh` : 57 tests OK.
- VM qemu (noyau Ubuntu 7.0 avec sched_ext, 8 vCPU sur 2 sockets, faux X3D) : **9/9 PASS** le 12/11 et à nouveau le 13/11 avec les binaires finaux — scx_rago accepté par le vérifieur BPF et actif ; jeu tagué avant exec ; enfant tagué par héritage ; jeu 100 % sur le « CCD X3D » sous charge (52 % sans Rago) ; thread de rendu 100 % ; tâches de fond 92 % sur l'autre CCD ; untag ; arrêt de scx_rago → retour EEVDF, jeu vivant ; lancement sans scx_rago OK.
- Pipeline noyau dans le conteneur (13/11), faute d'accès à kernel.org : sur les sources Ubuntu **6.8** (pas la 6.18 visée, pas de patch CachyOS), config de base = noyau 7.0 d'Ubuntu, `localmodconfig` → fusion des fragments → build **Clang ThinLTO** (`6.8.12-rago`) → tarball + manifeste sha256 → clé MOK (`mok-gen`) → signature `sbsign` vérifiée par `sbverify` → **le noyau signé démarre dans qemu** (uname `6.8.12-rago`, PREEMPT, HZ 1000, ThinLTO, MGLRU confirmés dans `/proc/config.gz`). La config est identique d'un passage à l'autre (même sha256). `verify` signale bien les 8 options absentes de la 6.8 (sched_ext, BORE, NTSYNC…) : c'est attendu, elles existent en 6.18.
- Pas testé : `fetch` / `prepare` réels (sources non épinglées), paquet pacman, `install`, `bootloader` (seulement en `--dry-run`), shim, `mok-enroll`, démarrage avec Secure Boot actif.

## Critère de test sur matériel (à faire par Sofiene)
`kernel/tests/m0_hardware_test.sh` : uname = `-rago` ; `SCHED_CLASS_EXT=y` et toutes les options du fragment ; Secure Boot ON + clé MOK inscrite + noyau signé ; scx_rago chargé ; cyclictest meilleur que le noyau d'origine (référence avec `--save-baseline`) ; jeu tagué → bons cœurs (X3D ≥ 95 %, hybride ≥ 80 %, rendu ≥ 95 %).

**Dépend de / relié à :** [[Noyau et ordonnanceur]], [[Sécurité et boot]], [[M11 Rago UI]], [[M14 Profils par jeu]]

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M0). Détail : bible v7, module M0.
