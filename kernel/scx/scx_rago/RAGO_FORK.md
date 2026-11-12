# scx_rago : fork de scx_lavd pour Rago OS

`scx_rago` = **scx_lavd 1.1.4** (dépôt sched-ext/scx, GPL-2.0) + un
canal **launcher → ordonnanceur**. lavd *devine* la criticité de latence des
tâches ; scx_rago la **reçoit** du launcher, qui tague l'arbre de processus
du jeu **avant** son lancement, et route le jeu sur les bons cœurs.

Le premier commit du fork importe lavd tel quel ; `git diff` depuis ce
commit montre exactement les ajouts Rago. Dans le code lavd, chaque ajout est
marqué `RAGO:` et reste court ; la logique est dans des fichiers à part.

## Fichiers ajoutés

| Fichier | Rôle |
|---|---|
| `src/bpf/rago_intf.h` | ABI partagée BPF / espace utilisateur (`struct rago_hint`, classes, constantes). Version : `RAGO_ABI_VERSION`. |
| `src/bpf/rago.bpf.h` | Prototypes et boost de criticité (`rago_lat_weight_boost`). |
| `src/bpf/rago.bpf.c` | Maps de tags, classification, héritage au fork, choix de CPU, garde de vol. |
| `src/rago.rs` | Options `--rago-*`, topologie, rodata, écriture des maps, serveur du socket. |
| `../rago-common/` | Brique commune (protocole, topologie, serveur, client), testée seule. |
| `/host/bin/rago-sched-hint/` | Outil appelé par le launcher (`rago-sched-hint run -- <jeu>`). |

## Points d'accroche dans lavd

| Fichier lavd | Ajout |
|---|---|
| `lavd.bpf.h` | 3 champs à la fin de `task_ctx` : `rago_class`, `rago_counted`, `rago_refresh_clk`. |
| `main.bpf.c` | `rago_refresh_task()` dans `select_cpu` et `enqueue` ; `rago_init_task()` dans `init_task` ; `rago_exit_task()` dans `exit_task` ; `rago_init_cpumasks()` dans `init` ; nom `rago`. |
| `idle.bpf.c` | `pick_idle_cpu()` demande d'abord `rago_pick_cpu()`. |
| `lat_cri.bpf.c` | Boost de poids de latence pour les tâches de jeu / rendu ; sur CPU hybride, criticité de performance maximale pour le jeu (préférence P-cores). |
| `balance.bpf.c` | `rago_steal()` avant chaque vol de tâche entre domaines. |
| `main.rs` | Options Rago, rodata, maps branchées avant l'attachement, statistiques. |

## Fonctionnement

1. **Tag.** `rago-sched-hint run -- jeu` se connecte à
   `/run/rago/sched-hint.sock` (root:rago, 0660), tague **son propre PID**,
   puis fait `exec` du jeu : le tag existe avant la première instruction du
   jeu. Le serveur vérifie l'appelant (`SO_PEERCRED`) et qu'il possède le
   processus visé (uid de `/proc/<pid>`). Pas de binaire à capacités : un
   binaire setcap passerait le jeu en mode `AT_SECURE`, qui retire
   `LD_PRELOAD` / `LD_LIBRARY_PATH` (MangoHud, Steam Runtime cassés).
2. **Héritage.** À la création d'un processus (`init_task` avec fork), si le
   processus parent est tagué, l'enfant l'est aussi (`RAGO_HINT_INHERITED`).
   Le parent est lu via `bpf_get_current_pid_tgid()`, car `real_parent`
   n'est pas encore fixé à ce moment-là.
3. **Classification** (toutes les 50 ms au plus par tâche) : tag par thread
   (`rago_tids`) > tag par processus (`rago_tgids`) ; dans un processus
   tagué, un thread dont le nom commence par un motif de rendu (`dxvk-cs`,
   `vkd3d_queue`, `RenderThread`, `RHIThread`…) est classé **RENDER**,
   les autres **GAME**.
4. **Criticité.** RENDER : boost de latence double ; GAME : boost simple.
5. **Routage.**
   - **X3D** (Ryzen à cache 3D) : masque jeu = CCD au plus grand L3.
     `rago-sched-hint` pose aussi une **affinité dure** sur ce CCD (héritée
     par les enfants, et qui tient même si scx_rago s'arrête). En BPF, le
     jeu prend un CPU libre du masque, sinon reste dans le masque.
   - **Hybride** (Intel P/E) : masque jeu = P-cores. Préférence douce : le
     jeu prend un P-core libre ; le thread de rendu reste toujours sur les
     P-cores ; les tâches de fond préfèrent les E-cores pendant un jeu.
   - **Symétrique** : pas de routage, boost seul.
6. **Garde de vol.** Un CPU hors masque jeu qui vole du travail parcourt la
   file et prend la première tâche **non confinée** (rendu toujours
   confiné ; tout le jeu sur X3D). `rago_steal()` est une fonction globale
   (`__weak`) pour que le vérifieur BPF ne la revérifie pas à chaque appel.
7. **Filet.** Si scx_rago s'arrête, plante ou est éjecté par le watchdog
   sched_ext, le noyau revient à EEVDF + BORE ; les tags sont gardés en
   espace utilisateur et réappliqués au redémarrage du service.

## Limites connues

- Le routage strict suppose que le masque jeu correspond à un domaine de
  calcul lavd (un LLC × un type de cœur). C'est le cas des masques détectés
  (X3D = un L3, hybride = type de cœur). Un masque manuel
  (`--rago-game-cpus`) qui coupe un domaine fonctionne, mais l'équilibreur
  lavd peut le contourner plus souvent.
- Compilation BPF : **Clang >= 20** (`BPF_CLANG=clang-20`). Clang 18 produit
  un code d'arène (`sdt_alloc`) refusé par le vérifieur.
- Le noyau doit exposer sa config (`CONFIG_IKCONFIG_PROC`) et debugfs.

## Tests

- `cargo test` (racine du dépôt) : rago-common + rago-sched-hint.
- `kernel/tests/vm/run_scx_vm_test.sh` : charge vraiment scx_rago dans une
  VM qemu (faux X3D sur 2 sockets) et mesure le routage d'un faux jeu.
- `kernel/tests/m0_hardware_test.sh` : test sur vrai matériel.

## Licence

GPL-2.0, comme scx_lavd (voir `LICENSE`).
