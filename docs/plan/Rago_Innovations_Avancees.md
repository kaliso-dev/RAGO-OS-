# INNOVATIONS AVANCÉES — Repousser le dual-boot et les performances (Rago OS)

> Conception d'optimisations **au-delà de l'état de l'art**. Chaque idée est notée honnêtement :
> ✅ Faisable maintenant · 🔧 Difficile mais réel · 🧪 R&D / spéculatif · 🏭 Nécessite du matériel certifié Rago.
> Je distingue l'**innovation nette** (mécanisme neuf) de l'**innovation d'intégration** (briques existantes orchestrées comme personne ne le fait). Aucune dissimulation : pure ingénierie système.

---

# PARTIE A — CASSER LES LIMITES DU SWITCH

## A1. 🏭 La vraie rupture : une « Rago Console » à firmware ouvert (coreboot)

**Le constat dur :** le plancher du POST (~1-5 s) est fixé par le **firmware UEFI du fabricant**. Tant qu'on subit le firmware vendeur, on ne descend pas sous ~1 s. `kexec` est fermé (fragile + casse Secure Boot). **Il reste UNE couche qu'on n'a pas attaquée : le firmware lui-même.**

**L'idée :** sur une configuration matérielle **certifiée** (carte compatible **coreboot** / open firmware, comme le font System76, Framework, Google Chromebooks), remplacer le firmware vendeur par un **firmware Rago minimal** (coreboot + payload edk2 réduit). Les machines coreboot bootent en **< 1 seconde** parce qu'elles sautent tout le code vendeur superflu et gèrent l'init mémoire de façon déterministe.

**Pourquoi c'est LA rupture :** c'est la **seule** façon légitime de faire tomber le POST vers le quasi-zéro. Sur une Rago Console certifiée, la bascule porte-à-porte pourrait viser **~3-5 s au lieu de ~10-13 s** — parce que le plus gros poste (le POST) s'effondre.

**Honnêteté :**
- Ne marche **pas** sur n'importe quelle carte (reflasher un firmware vendeur arbitraire est risqué/impossible). → Réservé à du **matériel Rago-certifié** (une gamme de PC/console préflashés).
- C'est une **stratégie produit** autant qu'une techno : la version « install sur ton PC » garde le POST vendeur optimisé (MCR/DTRR) ; la version « Rago Console » a le switch quasi-instantané. **C'est ton haut de gamme, et c'est défendable.**

**Verdict :** l'innovation la plus puissante, mais elle définit une **SKU matérielle**. À garder en vision produit.

---

## A2. 🔧 Un « coordinateur de switch » en application UEFI (framebuffer continu)

**L'idée :** au lieu de confier la bascule au bootloader de l'OS, écrire une **petite application UEFI Rago** qui s'exécute très tôt, lit `RAGO-COMM`, décide quel OS lancer, **et surtout possède le framebuffer (GOP) pendant toute la transition**. Elle affiche le splash Rago **au niveau firmware**, avant même que l'OS démarre.

**Pourquoi c'est mieux qu'un splash OS :** un splash posé par l'OS laisse toujours une fenêtre noire pendant le POST (l'OS n'est pas encore là). Une **app UEFI** peut peindre l'écran **dès le POST terminé**, sans discontinuité → **zéro écran noir**, transition visuellement ininterrompue de bout en bout.

**Honnêteté :** écrire une app UEFI est faisable (edk2), mais c'est du bas niveau et à tester par carte. Le gain est surtout **perceptuel** (la fluidité visuelle que tu exiges), pas chronométrique.

**Verdict :** la bonne couche pour « ne jamais voir Windows ni d'écran noir ». Innovation d'intégration forte.

---

## A3. ✅ Deux modes de bascule : « Rapide » vs « Session préservée »

**Le constat :** le coût de l'hibernation vient de la **taille de la session** (navigateur, travail). Mais souvent, l'utilisateur lance un jeu **depuis le launcher**, pas en plein milieu de son travail.

**L'idée — offrir deux chemins :**
- **Mode « Rapide » (défaut depuis le launcher)** : on **n'hiberne pas** la session lourde. On quitte vers une **micro-session launcher** jetable (empreinte minime) → au retour, elle **cold-boote en ~2 s** au lieu de resumer une image. On **supprime entièrement le poste hibernation** (gain de 2-4 s).
- **Mode « Session préservée »** : si l'utilisateur était en plein travail, on hiberne normalement pour tout retrouver.

Le launcher choisit automatiquement (ou propose) selon l'état : session légère → Rapide ; session chargée → Préservée.

**Pourquoi c'est novateur :** aucun OS de dual-boot ne propose ce choix automatique. On transforme « toujours hiberner » (coûteux) en « hiberner seulement si ça vaut le coup ».

**Verdict :** faisable immédiatement, gain réel, zéro risque. **À intégrer.**

---

## A4. 🧪 Hibernation incrémentale / pré-écrite (speculative pre-hibernation)

**L'idée :** pendant que l'utilisateur navigue dans l'UI, **pré-écrire la partie invariante** de l'image d'hibernation (le cœur stable du launcher). Au clic, on ne flushe que les **pages modifiées (dirty)** depuis → l'écriture au moment du switch devient quasi-nulle.

**Honnêteté :** le noyau Linux **ne supporte pas nativement** l'hibernation incrémentale. Il faudrait soit un launcher conçu pour avoir un working set minuscule et quasi-statique (faisable), soit un patch noyau de snapshot incrémental (lourd). → **R&D.** La variante « launcher à empreinte minimale » (sans patch) est le chemin réaliste et rejoint A3.

**Verdict :** potentiel réel, mais le chemin propre passe par A3 (micro-session) plutôt que par un patch de snapshot.

---

## A5. ✅ Continuité du framebuffer : gel de la dernière frame

**L'idée :** au moment du clic, capturer la **dernière frame rendue de l'UI Rago** et l'utiliser comme image du splash (A2). L'écran ne devient jamais noir : le jeu « se matérialise » par-dessus une frame Rago figée. Combiné à A2, la transition paraît être **une seule animation continue**.

**Verdict :** pur UX, faisable, et personne ne le fait en dual-boot. **À intégrer.**

---

## A6. 🔧 Reset « à chaud » déterministe + pré-conditionnement GPU

**Deux micro-leviers réels :**
- **Warm reset discipliné** : toujours déclencher un *warm reset* (pas cold) pour la bascule, avec le firmware configuré pour sauter l'entraînement mémoire sur warm reset (ce que MCR fait en partie). Rendre ça **déterministe** plutôt que « à la discrétion du firmware ».
- **Pré-conditionnement GPU** : décharger proprement le pilote GPU et laisser le GPU dans un **état connu** avant la bascule, pour que la ré-initialisation de l'OS cible soit **déterministe** (c'est le point fragile « écran noir au resume »). Un petit service Rago qui garantit l'état GPU avant chaque switch.

**Verdict :** incrémental mais attaque le vrai point de fragilité (resume GPU). À implémenter dans M6.

---

# PARTIE B — PERFORMANCES DE L'OS (au-delà de CachyOS)

## B1. ✅ Canal launcher → ordonnanceur (scx_rago informé) — innovation nette

**Le constat :** `scx_lavd` *infère* quelles tâches sont critiques pour la latence. **Mais Rago SAIT** quel jeu se lance — c'est lui qui le lance.

**L'idée :** un **canal de communication launcher → scheduler** (via une **BPF map**). Au lancement, Rago **tague explicitement l'arbre de processus du jeu** (thread de rendu, threads de compilation de shaders) comme latency-critical **avant même** que le jeu démarre. `scx_rago` n'a plus à deviner : il **sait**.

**Pourquoi c'est novateur :** aucun ordonnanceur ne reçoit de hints applicatifs du launcher. C'est faisable (sched_ext expose des BPF maps), et c'est un **mécanisme neuf** : l'OS gaming qui connaît ses jeux les ordonnance mieux que celui qui les devine.

**Verdict :** innovation nette, faisable, haute valeur. **Pilier de la couche native.**

## B2. ✅ Routage automatique X3D / P-cores (le gain gratuit que tout le monde fait à la main)

**Le constat :** sur Ryzen **X3D** (double CCD), pinner le jeu sur le **CCD avec le cache 3D V-cache** donne un gain FPS **majeur et connu** — mais les gens le font **manuellement** (Process Lasso, Game Bar). Sur Intel hybride, router le jeu sur les **P-cores** et le fond sur les **E-cores**.

**L'idée :** `scx_rago` **détecte automatiquement** la topologie (X3D CCD / P-E cores) et **route le jeu sur les bons cœurs sans intervention**. Couplé à B1 (le launcher sait quel process est le jeu), c'est automatique et fiable.

**Verdict :** faisable, gain réel et mesurable, et **l'automatisation est l'innovation** (personne ne le fait proprement au niveau scheduler). **À intégrer.**

## B3. ✅ Profils de performance par jeu (base de données communautaire)

**L'idée :** Rago maintient un **profil par jeu** appliqué au lancement : gouverneur CPU, params scheduler, horloges GPU, **mitigations on/off**, **VBS/HVCI on/off** (profil de sécurité de l'étude Micro-Windows), pré-chauffage du cache shaders. Crowd-sourcé (comme ProtonDB, mais au niveau noyau/matériel).

**Pourquoi c'est novateur :** Bazzite/CachyOS font du tuning **global** ; personne ne fait du tuning **par titre, piloté par le launcher, couvrant les deux couches** (Proton ET le switch Windows). Rago route le bon profil kernel **et** le bon profil de sécurité Windows selon le jeu.

**Verdict :** innovation d'intégration forte, faisable, différenciateur clair. **À intégrer.**

## B4. 🔧 Cache de shaders unifié et pré-chauffé (anti-stutter)

**Le constat :** le stutter de compilation de shaders est le principal défaut ressenti du gaming Linux (Proton compile à la volée).

**L'idée :** Rago pré-chauffe / partage un **cache de shaders par GPU**, téléchargé avec le jeu (étend l'approche Fossilize de Steam à **tout le système** et aux jeux lancés via le switch). Stocké de façon centralisée sur `RAGO-LIB`.

**Honnêteté :** les caches ne se partagent pas entre pile Proton et pile Windows native (drivers différents), mais **par couche**, centralisé et pré-chauffé, c'est un vrai gain. Partiellement existant (Fossilize), l'innovation est l'intégration système.

**Verdict :** difficile mais réel, fort impact sur le ressenti. À viser après le socle.

## B5. 🧪 Chemin de chargement d'assets accéléré (DirectStorage-like)

**L'idée :** exploiter un équivalent **DirectStorage** sur Linux (décompression GPU, I/O NVMe directe) pour réduire les temps de chargement. Des efforts existent côté Proton/Mesa.

**Honnêteté :** immature sur Linux, dépend de l'écosystème. **Spéculatif** — à surveiller, pas à promettre.

## B6. ✅ Mémoire : THP et politique mémoire par jeu

**L'idée :** sans VM, on garde les jeux natifs, mais on peut appliquer une **politique mémoire par titre** (THP `always` vs `madvise` selon que le jeu aime ou déteste les huge pages — certains stuttent avec `always`), pilotée par le profil B3. zram réglé pour ne jamais swapper le jeu.

**Verdict :** faisable, fait partie des profils par jeu. **À intégrer.**

---

# SYNTHÈSE — ce qui est vraiment nouveau et ce que ça vaut

| # | Innovation | Type | Faisabilité | Gain |
|---|---|---|---|---|
| **A1** | Rago Console à firmware coreboot | Rupture produit | 🏭 Matériel certifié | POST → quasi-zéro (switch ~3-5s) |
| **A2** | Coordinateur de switch en app UEFI | Intégration | 🔧 Difficile | Transition visuelle sans couture |
| **A3** | Modes Rapide / Session préservée | Intégration | ✅ Maintenant | −2-4 s (saute l'hibernation) |
| **A5** | Gel de la dernière frame | UX | ✅ Maintenant | Zéro écran noir |
| **A6** | Warm reset + pré-conditionnement GPU | Refinement | 🔧 Difficile | Fiabilité du resume |
| **B1** | Canal launcher → scheduler | **Mécanisme neuf** | ✅ Maintenant | Latence jeu optimale |
| **B2** | Routage auto X3D / P-E cores | Intégration | ✅ Maintenant | +FPS réel (gratuit) |
| **B3** | Profils perf+sécurité par jeu | Intégration | ✅ Maintenant | Optimum par titre |
| **B4** | Cache shaders unifié pré-chauffé | Intégration | 🔧 Difficile | Anti-stutter |

**Les trois paris les plus forts :**
1. **B1 (launcher → scheduler)** — le mécanisme vraiment neuf : l'OS qui *sait* quel jeu tourne l'ordonnance mieux que celui qui *devine*. Faisable, haute valeur, différenciateur net.
2. **A3 + A2 + A5 (switch rapide + continuité visuelle)** — rend la bascule à la fois plus courte **et** visuellement sans couture, sans matériel spécial.
3. **A1 (Rago Console coreboot)** — la vision haut de gamme : la seule façon de rendre le switch quasi-instantané, en contrôlant le firmware. C'est ta SKU premium.

**Ce qui reste honnêtement hors de portée :** la bascule bare-metal **instantanée** sur matériel grand public (le POST vendeur). Seule la Rago Console (A1) s'en approche. Partout ailleurs, on vise ~10 s masqués, pas zéro.

*Ces innovations étendent les modules M0/M6/M8 (switch) et M1/M2 (performance) de la bible.*
