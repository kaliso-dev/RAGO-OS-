# ÉTUDE & CONCEPTION — Le Fast OS Switch le plus rapide possible (Rago OS)

> Étude technique approfondie du cœur du produit : la bascule Linux ⇄ micro-Windows bare-metal. Objectif : concevoir le système de dual-boot le plus rapide et le plus fluide possible, en innovant là où c'est possible, et en nommant honnêtement les limites physiques.
> Sources : documentation noyau Linux (hibernation), mesures communautaires AM5/DDR5 (POST), travaux kexec/LinuxBoot, docs Windows Fast Startup. Vérifié nov. 2026.

---

## 1. La contrainte fondamentale (à graver)

Changer d'OS sur du **bare-metal** (obligatoire pour l'anti-triche) impose un **reboot**, donc un **POST firmware** (ré-initialisation de la carte mère). **Aucun logiciel ne supprime le POST.** La seule façon d'avoir une bascule *réellement* instantanée serait la virtualisation — incompatible avec l'anti-triche. **Tout l'art consiste à optimiser autour du POST, pas à l'éliminer.**

> **J'ai vérifié la seule voie théorique pour sauter le firmware — `kexec` vers Windows — et elle est fermée pour nous :**
> - `kexec` ne charge nativement qu'un noyau Linux. Booter Windows via kexec exige d'émuler une grande partie d'UEFI (projets u-root/LinuxBoot) : **expérimental, fragile, non fiable**.
> - Surtout : `kexec` **contourne Secure Boot** — c'est pourquoi les distributions le désactivent quand Secure Boot est actif. Or **l'anti-triche EXIGE Secure Boot activé**. Donc kexec briserait précisément la chaîne de confiance dont on a besoin.
>
> **Conclusion : le POST reste. On le réduit au minimum, on le masque, mais il est là.**

---

## 2. Décomposition de la latence (les 3 postes)

La bascule porte-à-porte (clic → jeu à l'écran) se décompose en trois postes mesurables. Chiffres **réels** issus de la recherche :

| Poste | Non optimisé | Optimisé (cible) | Levier |
|---|---|---|---|
| **1. Hibernation Linux** (écriture RAM→disque) | 6-10 s | **2-4 s** | compression LZ4/zstd multi-thread, session lean, NVMe |
| **2. POST firmware** | 20-90 s (!) sur AM5/DDR5 | **1-5 s** | Memory Context Restore + DTRR + Ultra Fast Boot |
| **3. Boot micro-Windows → jeu** | 10-20 s | **2-4 s** | image minimale, shell = jeu direct |
| **TOTAL vers le jeu** | 40-120 s | **~6-13 s** | |
| **Retour** (POST + resume Linux) | — | **~4-8 s** | |

Le poste qui surprend tout le monde : sur une carte AM5/DDR5 mal réglée, **le POST seul peut prendre 45-90 secondes** à cause du ré-entraînement mémoire. C'est le plus gros gisement, et c'est **gratuit** à récupérer (un réglage UEFI).

---

## 3. Poste 1 — Hibernation Linux : la mécanique et ses optimisations

**Comment ça marche.** Le noyau fige les tâches, crée un instantané de la RAM, **le compresse**, et l'écrit sur le swap. Au resume, il lit l'image, décompresse, et restaure atomiquement la mémoire. L'image est au plus ~½ de la RAM (contrainte de copie atomique).

**Optimisations (toutes vérifiées) :**
1. **Algorithme de compression.** Le défaut historique est **LZO**. Depuis le noyau **6.9**, on peut choisir **LZ4** (`hib_compression=lz4`) : resume mesuré **~3,8 s vs ~4,4 s** pour LZO. **zstd** est aussi disponible (meilleur ratio). → Choisir LZ4/zstd selon le compromis vitesse/taille.
2. **Compression multi-thread** (patch 2026, `hibernate_compression_threads=`) : avec **5-6 threads**, le resume s'améliore d'**~12 %** vs le défaut à 3 threads. Rago a des CPU multi-cœurs → à activer.
3. **Réduire le working set.** Moins de RAM utilisée = image plus petite = hibernation et resume plus rapides. → Rago hiberne depuis une **session "mode launcher" légère** (pas 40 Go d'applications ouvertes). `/sys/power/image_size` peut plafonner l'image.
4. **NVMe rapide + swap dédié.** La vitesse d'écriture/lecture est directement la vitesse d'hibernation/resume.
5. **Patches 2026** (LG, Youngjun Park) améliorant l'allocation de slots et l'I/O d'hibernation — à suivre, gain gratuit via noyau récent.

**Cible réaliste : 2-4 s** dans chaque sens pour une session lean sur NVMe.

---

## 4. Poste 2 — POST firmware : le plus gros levier (et le plancher)

Le POST est incompressible *dans son principe*, mais sa **durée** est très réductible. Chiffres communautaires AM5/DDR5 **mesurés** :

- **Memory Context Restore (MCR)** — sauvegarde l'entraînement DDR5 au lieu de le refaire à chaque boot :
  - 44 s → **20 s** · 4 min → **17 s** · 43 s → **22 s** (plusieurs sources concordantes).
- **DDR Training Runtime Reduction (DTRR)** — option plus récente, plus agressive : un cas **70-90 s → ~5 s**. À combiner avec MCR.
- **Ultra Fast Boot** (UEFI) — saute l'init des périphériques non essentiels, les logos, le test mémoire complet.
- **Désactiver le self-check des disques SATA** au POST → quelques secondes de plus.
- Combiné (MCR + Fast Boot + tuning) : des utilisateurs atteignent **4-9,5 s du bouton au login**, dont **1-3 s de POST**.

**Innovation produit :** Rago doit **auto-configurer ce profil** quand c'est possible (ou le documenter précisément par chipset), parce que 90 % des utilisateurs ignorent que leur POST de 45 s est un simple réglage. **C'est le plus gros gain, et personne ne le fait par défaut.**

**Plancher honnête : ~1-3 s de POST** sur une plateforme bien réglée (plus de RAM = POST un peu plus long ; l'entraînement mémoire scale avec la capacité). On ne descend pas sous ~1 s sur du matériel grand public.

---

## 5. Poste 3 — Boot du micro-Windows

Détaillé dans l'étude Micro-Windows. En résumé : image sans services superflus, **shell remplacé par le lanceur de jeu** (pas de bureau à initialiser), pilotes réduits au matériel réellement présent → **2-4 s** du handoff firmware au processus du jeu. Le chargement **du jeu lui-même** (assets) s'ajoute et ne dépend pas de nous.

---

## 6. Innovations de conception Rago

### 6.1 Le design asymétrique (notre force structurelle)
Contrairement au dual-boot symétrique classique (les deux OS hibernent, chacun doit reprogrammer le bootloader via `bcdedit`/`efibootmgr`), Rago est **asymétrique** :
- **Seul Linux hiberne** (il porte la session de l'utilisateur).
- **Windows est sans état** : il boote frais, lance le jeu, et à la fermeture se contente de `shutdown /r`.
- Le bootloader a **Linux par défaut** ; Linux pose un **one-shot vers Windows** avant d'hiberner (`bootctl set-oneshot` ou `efibootmgr --bootnext`). Le one-shot **s'auto-consomme** → au reboot, retour automatique sur Linux.
- **Windows n'écrit JAMAIS dans l'ordre de boot.** Plus simple, plus robuste : un reboot inattendu retombe sur Linux ; une image d'hibernation invalide → cold-boot Linux (session perdue mais système sain).

C'est plus rapide et plus sûr que tous les tutoriels de dual-boot existants, qui font l'aller-retour symétrique.

### 6.2 Splash UEFI continu (perception de fluidité)
Pendant le POST, l'écran est contrôlé par le firmware (logo carte mère). En posant un **logo OEM / image BGRT custom Rago**, l'utilisateur voit un **écran Rago continu** du clic jusqu'au jeu. Il ne voit jamais « Windows démarrer » ni l'écran de la carte mère. **La transition *paraît* être une seule animation Rago.** C'est la clé de l'exigence « ne jamais avoir l'impression de quitter Rago ».

### 6.3 NVMe dédié par OS (si le matériel le permet)
Chaque OS sur son propre NVMe : pas de conflit de chargeurs, bande passante maximale à la sortie d'hibernation. Idéal sur tour. Sur portable mono-NVMe, le schéma de partitions unique reste le fallback (l'installateur détecte les deux cas).

### 6.4 (R&D) Resume d'image Windows pré-cuite par jeu — le gain maximal, mais risqué
**L'idée :** au lieu de cold-boot + chargement du jeu à chaque fois, **reprendre une image d'hibernation Windows figée au menu du jeu**. Arrivée directe en jeu → on économise le boot ET le chargement.

**Les obstacles, vérifiés et honnêtes :**
- **Fast Startup / hibernation Windows verrouille le NTFS.** Si Windows hiberne avec la partition partagée **RAGO-LIB** montée, Linux ne peut plus y écrire sans corruption. → Il faudrait **démonter/isoler RAGO-LIB avant d'hiberner Windows** (la marquer offline), ce qui complique.
- **Les anti-triche réagissent mal au resume** (saut temporel, ré-attestation runtime). À **valider titre par titre**.
- **L'image périme à chaque patch du jeu** → mécanisme d'**invalidation + rebuild automatique**.

→ **Statut : module optionnel, désactivé par défaut, activable par jeu après validation.** Potentiel énorme (bascule quasi-instantanée vers le jeu déjà chargé), mais ne doit **jamais** être présenté comme acquis. C'est le vrai terrain d'innovation à explorer une fois le socle stable.

### 6.5 Préchauffage
Pendant que l'utilisateur navigue dans l'UI Rago, pré-écrire ce qui peut l'être (requête de jeu dans RAGO-COMM, image d'hibernation de base) pour raccourcir le poste 1.

---

## 7. Budget cible consolidé & ce qui est honnêtement impossible

**Cible porte-à-porte optimisée : ~6-13 s** vers le jeu (hors chargement des assets du jeu), **~4-8 s** au retour, le tout **masqué par le splash Rago** → perçu comme fluide.

**Honnêtement impossible :**
- **L'instantané vrai** (< 1 s) en bare-metal : non, à cause du POST. Qui le promet ment.
- **Garder les deux OS "vivants" simultanément** : non (un seul OS par machine sans virtualisation).

**Ce qui est vrai et défendable :** une bascule de l'ordre de **10 secondes, visuellement continue (splash Rago), sans jamais voir Windows, session Linux préservée, zéro ban** — ce que personne n'a rendu clé-en-main.

---

## 8. Plan de banc d'essai (bench_switch)

Le script `bench_switch.sh` doit chronométrer **séparément** les 3 postes et consigner :
1. `t_hibernate` : de l'appel `systemctl hibernate` à l'extinction (horodatage journald + mesure externe).
2. `t_post` : extinction → premier signe de vie de l'OS suivant (nécessite une mesure externe/vidéo, ou un compteur firmware si exposé).
3. `t_boot_game` : handoff firmware → processus du jeu actif (log `rago-shell`).
4. `t_total` et `t_return`.

**Mesurer, jamais promettre.** Les cibles ci-dessus sont des objectifs à valider sur le matériel de référence, pas des garanties.

---

## 9. Récapitulatif des décisions de conception

| Décision | Choix Rago |
|---|---|
| Sauter le POST (kexec) | ❌ Impossible (fragile + casse Secure Boot) |
| Hibernation | ✅ Linux seul, LZ4/zstd multi-thread, session lean, NVMe |
| POST | ✅ Auto-profil MCR + DTRR + Ultra Fast Boot (le gros gain) |
| Bascule | ✅ Asymétrique, one-shot auto-consommé, Windows n'écrit rien |
| Perception | ✅ Splash UEFI Rago continu |
| Stockage | ✅ NVMe dédié par OS si possible ; cloisonnement strict (jamais de partage monté pendant l'hibernation) |
| Resume Windows pré-cuit | 🧪 R&D optionnel par jeu (gain max, risques réels) |

*Cette étude affine les modules M6 (switch) et M8 (optimisation) de la bible.*
