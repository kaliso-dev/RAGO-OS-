---
type: module
tags: [module, phase-A]
maj: 2026-11-13
statut: EN COURS
---
# M1 Tuning hôte

> Phase A. Statut : **EN COURS** — code écrit et testé en conteneur et en VM qemu ; **jamais testé sur vrai matériel**. Retour à [[Projet]], carte [[Architecture]].

**Objectif.** Régler l'hôte Linux pour le jeu natif ([[Couche Proton]]), sans isolation de cœurs : le jeu natif utilise tous les cœurs et [[M0 Noyau scx_rago]] le route déjà.

## Fichiers de code (dans `kaliso-dev/rago-os-`)
- `host/setup_host_tuning.sh` — commandes `install` (défaut), `verify` / `status`, `uninstall`, `deps` ; `--help` pour le détail. Choix mémorisés dans `/etc/rago/host-tuning.conf`, état d'avant l'installation dans `/var/lib/rago/host-tuning/`.
- `host/lib/rago_host_lib.sh` — fonctions pures (C-states, dossier des profils tuned, édition de `kernel.conf`, ordonnanceur d'E/S attendu, sysctl, 1 % low).
- `host/tuned/rago-gaming/tuned.conf` — profil tuned dérivé de `latency-performance`.
- `host/tuned/rago-gaming-variables.conf` — variables du profil (mode C-states) ; le script réécrit ce fichier à chaque installation.
- `host/sysctl.d/99-rago.conf` — sysctl.
- `host/udev/60-rago-iosched.rules` — ordonnanceur d'E/S par type de disque (`@NVME_SCHED@` remplacé à l'installation).
- `host/zram/rago-zram.conf` — swap zram (drop-in zram-generator).
- Tests : `host/tests/test_host_lib.sh`, `host/tests/test_setup_sysroot.sh`, `host/tests/vm/run_m1_vm_test.sh` + `host/tests/vm/m1_vm_guest.sh`, `host/tests/m1_frametime_compare.sh` (critère matériel).

## Ce qu'il fait
| Réglage | Valeur | Où |
|---|---|---|
| Profil tuned | `rago-gaming`, hérite de `latency-performance` (gouverneur performance, EPB/EPP performance, `min_perf_pct=100`, boost, `platform_profile=performance`, dirty bytes) | `/etc/tuned/profiles/rago-gaming/` (tuned ≥ 2.23) ou `/etc/tuned/rago-gaming/` (avant) |
| `vm.stat_interval` | 60 | tuned |
| `kernel.watchdog` | 0 (détecteurs de blocage coupés) | tuned |
| C-states | `--cstates deep` (défaut, aucune limite) · `shallow` (C1 max, comme latency-performance) · `poll` (aucun) | variable `rago_force_latency` → `[cpu] force_latency` |
| THP | `madvise` ; un profil de jeu [[M14 Profils par jeu]] peut le changer pendant un jeu | tuned `[vm]` |
| `vm.max_map_count` | 2147483642 (comme SteamOS) | sysctl |
| `vm.swappiness` / `vm.page-cluster` | 10 / 0 | sysctl |
| Tampons réseau | rmem/wmem max 16 Mio, défaut 1 Mio, tcp_rmem/wmem, udp min | sysctl |
| File réseau | `fq_codel` | sysctl |
| `kernel.split_lock_mitigate` | 0, documenté dans le fichier (perf des jeux Proton contre un déni de service local possible) ; ignoré si le CPU n'a pas la clé | sysctl |
| E/S | NVMe `none` (ou `--nvme-scheduler mq-deadline`), SSD SATA/eMMC `mq-deadline`, HDD `bfq` | udev |
| zram | moitié de la RAM, max 8 Gio, zstd, priorité 100 ; jamais utilisé pour l'hibernation ([[M8 Optimisation switch]] a son swap NVMe) ; zswap coupé (pas de double compression) | zram-generator + `zswap.enabled=0` |
| IRQ | `threadirqs` ; irqbalance actif ; `--irq-ban LISTE` optionnel (CPU évités par les IRQ, sans isoler les tâches) | `RAGO_CMDLINE_EXTRA` de `/etc/rago/kernel.conf` (M0) + irqbalance |
| power-profiles-daemon | arrêté (il se battrait avec tuned), remis à la désinstallation ; `--keep-ppd` pour le garder | systemd |

- `threadirqs` et `zswap.enabled=0` vont dans `/etc/rago/kernel.conf` du noyau Rago : il faut ensuite `sudo kernel/build_rago_kernel.sh bootloader` et redémarrer (`verify` le signale en « REDÉMARRER »). Sans noyau Rago, le script avertit et ne crée pas ce fichier. Le code de M0 n'est pas modifié.
- `uninstall` remet tout comme avant : profil tuned d'origine (même si le daemon était arrêté), sysctl et ordonnanceurs d'origine, fichiers de l'utilisateur sauvegardés puis restaurés, jetons retirés de `kernel.conf` (seulement ceux que M1 a ajoutés), zram/zswap, irqbalance, power-profiles-daemon.
- Aucune isolation : `verify` signale `isolcpus` / `nohz_full` / `rcu_nocbs` / `irqaffinity` s'ils sont sur la ligne de commande.

## Tests faits (par Claude, sans matériel)
- `host/tests/test_host_lib.sh` : 105 tests OK (fonctions pures, outil 1 % low).
- `host/tests/test_setup_sysroot.sh` : 89 tests OK — fausse racine, faux `/sys` et `/proc`, `systemctl` / `tuned-adm` / `udevadm` factices : installation, sauvegarde et restauration d'un fichier existant, idempotence, changements d'options mémorisés, refus des options invalides sans rien écrire, `--dry-run`, ancien et nouveau dossier tuned, sans `kernel.conf`, jeton de l'utilisateur jamais retiré, `verify` qui détecte un gouverneur, un sysctl ou power-profiles-daemon revenus, désinstallation complète.
- `host/tests/vm/run_m1_vm_test.sh` (13/11) : VM qemu Ubuntu 24.04 (noyau 6.8, tuned 2.21, vrais systemd, udev, irqbalance, zram-generator, power-profiles-daemon) avec un NVMe, un SSD SATA et un HDD SATA émulés : **59/59 PASS sur deux démarrages**. Démarrage 1 : install puis effets réels (profil actif, `tuned-adm verify`, THP, chaque sysctl, NVMe none, SSD mq-deadline, HDD bfq, zram prio 100, zswap coupé, irqbalance, ppd arrêté), C-states mesurés dans `/dev/cpu_dma_latency` (deep 2000000000, shallow 3, poll 0), NVMe mq-deadline et retour, `--irq-ban 0`, désinstallation qui remet exactement l'état d'origine, réinstallation. Démarrage 2 (avec `threadirqs zswap.enabled=0`, comme l'entrée de M0) : tout est revenu seul au démarrage, `verify` = 0 échec, 19 threads d'IRQ, aucun CPU isolé.
- **Pas testé** : gouverneur (pas de cpufreq en VM), base Arch / tuned ≥ 2.23 (seulement la logique de chemin), vraie entrée systemd-boot, FPS / 1 % low.

## Critère de test sur matériel (à faire par Sofiene)
1. `sudo host/setup_host_tuning.sh deps` puis `sudo host/setup_host_tuning.sh install` ; si le noyau Rago est installé : `sudo kernel/build_rago_kernel.sh bootloader` et redémarrer.
2. `host/setup_host_tuning.sh verify` → code 0 (`tuned-adm active` = rago-gaming, gouverneur performance sur tous les CPU, threadirqs actif).
3. 1 % low MangoHud : journal de 60 s dans la même scène, avant (`uninstall`) et après (`install`), puis `host/tests/m1_frametime_compare.sh avant.csv après.csv` → pas de régression (tolérance 2 %). Refaire avec `--cstates shallow` pour choisir le défaut.

**Dépend de / relié à :** [[M0 Noyau scx_rago]] (ligne de commande via `kernel.conf`), [[Couche Proton]], [[M14 Profils par jeu]] (THP par jeu), [[M8 Optimisation switch]] (hibernation hors zram).

**Prompt complet** : `docs/plan/Rago_Prompts_Sequence.md` (M1). Détail : bible v7, module M1.
