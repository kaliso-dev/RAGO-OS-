# Profils par jeu (M14)

Un **profil** dit, pour un jeu, ce qui change **par-dessus le réglage de base** de la machine (M1, profil tuned `rago-gaming`) pendant que ce jeu tourne. Un champ absent veut dire « garder la base ». Le démon `rago-profiled` l'applique au lancement et remet la base exacte à la fin.

- `community/` : base communautaire livrée avec Rago (installée dans `/usr/share/rago/profiles/`).
- `/etc/rago/profiles/` : réglages locaux de la machine ; un profil local remplace le profil communautaire de même `id`.
- `schema/rago-profile.schema.json` : schéma JSON du format. `schema/exemple-complet.toml` : modèle avec tous les champs commentés.
- `tests/` : `test_schema.py` (schéma et profils d'accord) et `invalides/` (exemples qui doivent être refusés).

Tous les profils actuels sont `verified = false` : ce sont des **valeurs de départ**, aucune n'a encore été mesurée sur du vrai matériel.

## Format

Un fichier par jeu, `<id>.toml` ou `<id>.json` (même contenu, au choix). `rago-profiled validate <fichier ou dossier>` vérifie.

| Champ | Valeurs | Effet |
|---|---|---|
| `schema` | `1` | version du format (obligatoire) |
| `id` | `a-z 0-9 -`, = nom du fichier | identifiant Rago du jeu (obligatoire) |
| `name` | texte | nom affiché (obligatoire) |
| `couche` | `proton` · `switch` | jeu natif Linux, ou micro-Windows via le Fast OS Switch (obligatoire) |
| `match.steam_appid` | entiers | AppID Steam qui désignent ce jeu |
| `match.exe` | noms de fichiers | exécutables qui désignent ce jeu (sans chemin, casse ignorée) |
| `cpu_governor` | `performance`, `powersave`, `schedutil`… | gouverneur cpufreq pendant le jeu ; une politique qui ne le propose pas garde la base |
| `thp` | `madvise` · `always` | transparent hugepages pendant le jeu (base M1 : `madvise`) |
| `cstates` | `deep` · `shallow` · `poll` | même vocabulaire que `--cstates` de M1 (voir plus bas) |
| `sched_hint.enabled` | booléen (défaut `true`) | lancer le jeu via `rago-sched-hint run` (M0) |
| `sched_hint.confine` | `auto` · `on` · `off` | affinité du jeu, comme `rago-sched-hint run --confine` |
| `sched_hint.render_comm` | 8 préfixes max, 15 caractères | threads de rendu propres au jeu, en plus des motifs de scx_rago |
| `gpu_clocks.mode` | `auto` · `max` · `fixed` | horloges GPU (M9) ; `core_mhz` / `mem_mhz` avec `fixed` seulement |
| `mitigations` | `on` · `off` | souhait du profil, **vérifié et signalé, jamais changé** |
| `windows_security` | `compat_max` · `perf` | couche switch : profil de sécurité du micro-Windows (M5) |
| `anticheat`, `notes` | texte | information |
| `verified` | booléen (défaut `false`) | `true` seulement après un vrai test sur matériel |

Un champ inconnu, une valeur hors liste ou un `id` différent du nom du fichier font **refuser** le profil (le jeu reçoit alors le profil sûr par défaut, voir plus bas). Les champs Linux d'un profil `switch` et `windows_security` d'un profil `proton` sont ignorés avec un avertissement.

## Quel profil pour quel jeu

Le launcher donne ce qu'il sait : `--id`, `--steam-appid`, `--exe`. Le démon cherche dans cet ordre : `id`, puis `steam_appid`, puis `exe`. Si rien ne correspond, ou si le profil du jeu est refusé : **profil sûr par défaut**.

Un critère `match` appartient au premier profil qui le revendique (dossier local d'abord, puis ordre alphabétique des `id`) ; `rago-profiled validate` signale les conflits.

## Profil sûr par défaut (fallback)

Intégré au démon (pas un fichier, pour qu'un fichier cassé ne puisse pas le casser) :

- **Linux : rien ne change.** Gouverneur, THP, C-states restent ceux de M1 ; pas de surcharge GPU ; mitigations non demandées.
- **Ordonnanceur : comportement normal de M0** (jeu tagué latency-critical, `confine = auto`).
- **Switch : `compat_max`** (VBS / HVCI / IOMMU activés) : le profil qui marche avec tous les anti-triche, au prix de quelques FPS.

Le jeu se lance aussi si le démon est arrêté ou absent : réglage de base, hint ordonnanceur seulement.

## Cohérence avec M1

M1 pose la base, M14 la surcharge le temps d'un jeu :

- Avant la première surcharge, le démon photographie la base (gouverneur de chaque politique cpufreq, préférence énergie/perf, THP) dans `/run/rago-profiled/applied.json`. À la fin du jeu, il ne remet **que ce qu'il a changé**. S'il est tué en plein jeu, il remet la base au redémarrage suivant ; au reboot, `/run` est vidé et tuned réapplique la base.
- **C-states** : demande PM QoS sur `/dev/cpu_dma_latency`, exactement le mécanisme du `force_latency` de tuned. `shallow` = latence de l'état C1 (repli 3 µs, comme `cstate.id_no_zero:1|3`), `poll` = 0. Le noyau garde la demande la plus stricte : un profil peut **ajouter** une limite, pas relâcher celle de M1 (`deep` sur une base `shallow` est signalé). La demande tombe toute seule quand le démon ferme le fichier, même s'il est tué.
- **Mitigations** : réglage global de la ligne de commande du noyau (`RAGO_MITIGATIONS` dans `/etc/rago/kernel.conf`, M0). Il faut redémarrer pour le changer, et c'est un choix de sécurité du joueur : le démon compare et signale, il ne touche à rien.
- Pendant un jeu, `host/setup_host_tuning.sh verify` (M1) peut signaler le gouverneur ou THP du profil : c'est normal.

Plusieurs jeux à la fois : seul le dernier lancé est appliqué ; à sa fin, celui d'en dessous revient ; quand le dernier se termine, la base revient.

## Hooks : modules pas encore codés

Les horloges GPU (M9) et le profil de sécurité Windows (M5 / M6) passent par des **hooks** : des exécutables que ces modules poseront dans `/usr/lib/rago/hooks/`. Tant qu'un hook n'existe pas, le démon le signale « en attente » et ne fait rien d'autre (`rago-profiled status` liste les hooks présents).

Règles communes : le hook tourne en root ; lui et son dossier doivent appartenir à root et ne pas être modifiables par le groupe ou les autres (sinon refusé) ; environnement vidé (`PATH`, `LANG` et les variables ci-dessous) ; profil effectif en JSON sur l'entrée standard ; 15 s max (`--hook-timeout`), tout le groupe de processus est tué au-delà ; code 0 = appliqué, sinon erreur (la dernière ligne de sortie est reprise dans le rapport).

### `gpu-clocks` (à fournir par M9)

- `gpu-clocks apply` au début d'un jeu dont le profil a `gpu_clocks.mode` = `max` ou `fixed` (et à chaque changement du jeu actif). Variables : `RAGO_PROFILE_ID`, `RAGO_GPU_CLOCKS_MODE` (`max` | `fixed`), `RAGO_GPU_CORE_MHZ`, `RAGO_GPU_MEM_MHZ` (si fixés).
- `gpu-clocks restore` quand plus aucun jeu ne demande de surcharge (et à la reprise après un arrêt brutal). Pas de variable : remettre les horloges de base de M9.

### `windows-security` (à fournir par M5 / M6)

- `windows-security set`, appelé par `rago-profiled prepare-switch --id <jeu>` juste avant le switch. Variables : `RAGO_PROFILE_ID`, `RAGO_WINDOWS_SECURITY` (`compat_max` | `perf`). Le hook écrit ce profil dans RAGO-COMM pour que le micro-Windows règle VBS / HVCI au démarrage.
- Code de sortie de `prepare-switch` : 0 transmis, 4 hook absent (M5/M6 pas installés), 1 erreur, 3 démon injoignable.

## Contribuer à la base communautaire

1. Copier `schema/exemple-complet.toml` en `community/<id>.toml`, ne garder que ce qui change pour ce jeu.
2. `rago-profiled validate profiles/community` et `python3 profiles/tests/test_schema.py`.
3. Mesurer (1 % low MangoHud, même scène, avant / après) avant de passer `verified = true`.
