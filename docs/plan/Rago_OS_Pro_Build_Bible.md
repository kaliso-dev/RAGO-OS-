# RAGO OS PRO — BIBLE DE BUILD (v7 — 2 couches, optimisation maximale)
### Plan d'ingénierie complet, optimisé pour pilotage par assistant IA (Claude)

> **v7 = v6 + toutes les innovations validées** des études (switch, micro-Windows, R&D avancée) intégrées dans les modules : canal launcher→ordonnanceur, routage auto X3D/P-E, modes de switch Rapide/Préservé, auto-tuning du POST (MCR/DTRR), hibernation LZ4/zstd multi-thread, continuité visuelle (splash UEFI + gel de frame), alignement Vanguard On-Demand, et profils par jeu (perf + sécurité). La roadmap premium (console coreboot, coordinateur UEFI) est en Partie 5.
>
> **Architecture : 2 couches, zéro VM, zéro masquage.** (1) Jeu natif Proton ; (2) Fast OS Switch bare-metal vers un micro-Windows pour les jeux anti-triche. Tout est légitime.

---

# PARTIE 0 — MODE D'EMPLOI

## 0.1 Règle d'or
**Un module à la fois**, dans l'ordre, **testé avant le suivant**. Une session par phase, bloc contexte (0.3) en tête de chaque session.

## 0.2 Subagents
Déléguer seulement les modules sans dépendance critique (M5 image Windows, M10/M14 démons/données, M2, recherche). **Jamais** M0/M3/M4/M6/M12/M13 (GRUB, LUKS, A/B, switch, installateur, partition).

## 0.3 Bloc contexte permanent (coller en tête de CHAQUE session)
```
Tu es Ingénieur Principal Systèmes sur Rago OS Pro : un OS Linux gaming à DEUX couches — (1) jeu natif via Proton (élite, base type CachyOS), et (2) un Fast OS Switch bare-metal (hibernation Linux + micro-Windows natif démarré direct sur le jeu) pour les jeux à anti-triche strict. PAS de VM. Pile : noyau Linux custom (≥6.12 + patchset CachyOS, sched_ext/scx_lavd, ordonnanceur scx_rago informé par le launcher) · Proton/Steam/gamescope · Rust (démons + backend UI) · Tauri v2 · systemd-boot. Optimisations clés : canal launcher→ordonnanceur, routage auto X3D/P-E cores, auto-tuning du POST (MCR/DTRR), hibernation LZ4/zstd multi-thread, profils par jeu (perf+sécurité), alignement Vanguard On-Demand (micro-Windows 25H2 avec Secure Boot/TPM/VBS/HVCI/IOMMU activés). Tout est bare-metal et légitime : aucune dissimulation. Tu produis du code de production complet, sans ellipses, avec un critère de test par module. Référence : Rago_OS_Pro_Build_Bible.md.
```

## 0.4 Phases
| Phase | Modules |
|---|---|
| **A — Socle & hôte optimisé** | M0 Noyau+scx_rago · M1 Tuning · M2 Proton · M3 LUKS/TPM · M4 A/B |
| **B — Moteur Windows & Switch** | M5 Micro-Windows · M6 Fast Switch · M7 Bibliothèque · M8 Optimisation switch |
| **C — Produit** | M9 GPU · M10 Télémétrie · M11 UI · M12 Installateur · M13 ISO · M14 Profils par jeu |
| **(Premier/R&D — Partie 5)** | Console coreboot, coordinateur UEFI, hibernation incrémentale, DirectStorage… |

## 0.5 Arborescence
```
rago-os/
├── kernel/           # M0 : noyau + scx_rago (+ canal launcher→sched)
├── host/             # tuning, proton, luks, a/b, gpu, switch, bin, systemd, profiles
├── windows/          # M5 micro-Windows + M6 rago-shell + M7 rago-agent
├── daemons/          # Rust : rago-telemetry, rago-profiled
├── rago-ui/          # Tauri v2
├── installer/        # M12
├── profiles/         # M14 : base de profils par jeu (perf + sécurité)
└── iso/Rago_ISO_Builder/
```

---

# PARTIE 1 — ARCHITECTURE (2 couches + couche d'optimisation)

```
            RAGO OS (Linux immuable, noyau custom scx_rago)
     ┌──────────────────────────────┬──────────────────────────────┐
  COUCHE 1 : JEU NATIF (Proton)     COUCHE 2 : FAST OS SWITCH
  Steam/Heroic/gamescope            hibernate Linux → micro-Windows
  la majorité des jeux              bare-metal → jeu plein écran → retour
     └──────────────┬───────────────┴───────────────┬──────────────┘
                    │                                │
         COUCHE D'OPTIMISATION (transversale) : scx_rago informé par le launcher,
         routage X3D/P-E, profils par jeu (perf+sécurité), auto-tuning POST, splash continu
```

L'utilisateur vit sur Rago. La plupart des jeux se lancent via Proton (couche 1). Les jeux anti-triche déclenchent le Fast OS Switch (couche 2). Une **couche d'optimisation transversale** (le launcher qui connaît le jeu) pilote l'ordonnanceur, le routage CPU, et les profils par jeu sur les deux couches.

---

# PARTIE 2 — MODULES

> Gabarit : Objectif · Fichiers · Spécification (avec les features intégrées) · Dépendances · Critères · **Prompt**.

---

## M0 — Noyau gaming custom + scx_rago informé

**Objectif.** Le meilleur noyau possible, **signé Secure Boot**, avec un ordonnanceur qui ne *devine* pas la criticité des tâches mais que **le launcher informe**.

**Fichiers.** `kernel/build_rago_kernel.sh` · `kernel/config/rago-gaming.config` · `kernel/patches/` · `kernel/scx/` (scx_rago) · `host/systemd/rago-scx.service` · `host/bin/rago-sched-hint` (API hint launcher→BPF)

**Spécification.**
- **Base** ≥6.12 + patchset CachyOS/linux-tkg. Config : PREEMPT, HZ=1000, MGLRU, LTO_CLANG_THIN, x86-64-v3 (détecte v4), ZRAM, pstate performance, `SCHED_CLASS_EXT=y`. `localmodconfig` sans retirer GPU/USB/réseau/hibernation. Option `mitigations=off` exposée.
- **Signature Secure Boot (MOK)** : `openssl` (clé), `sbsign` (signer), `mokutil` (enrôler). Obligatoire (couche 2).
- **🆕 scx_rago (fork scx_lavd) informé par le launcher** : une **BPF map** reçoit du launcher les PID de l'arbre du jeu + le thread de rendu, taggés **latency-critical avant le lancement**. `scx_rago` n'infère plus : il *sait*. `rago-sched-hint` est l'API (le launcher M11 l'appelle).
- **🆕 Routage topologie auto** : détecter **Ryzen X3D** (double CCD) → router le jeu sur le **CCD à cache 3D** ; sur **Intel hybride** → jeu sur **P-cores**, fond sur **E-cores**. Automatique, piloté par le hint du launcher.
- Filet : EEVDF+BORE (watchdog sched_ext).

**Dépendances.** Aucune (premier). Fournit le hint API consommé par M11.

**Critères.** `uname -r` = Rago ; `SCHED_CLASS_EXT=y` ; scx chargé ; **cyclictest** meilleur ; boot Secure Boot ON ; un jeu taggé → ses threads sur les bons cœurs (vérif `taskset`/X3D CCD).

**Prompt.**
```
Module M0 — Noyau + scx_rago informé. Génère kernel/build_rago_kernel.sh, kernel/config/rago-gaming.config, kernel/patches/ (descriptif), kernel/scx/ (fork scx_lavd→scx_rago), host/systemd/rago-scx.service, host/bin/rago-sched-hint.
- Base ≥6.12 + patchset CachyOS. Config : PREEMPT, HZ=1000, MGLRU, LTO_CLANG_THIN, x86-64-v3 (détecte v4), ZRAM, pstate performance, SCHED_CLASS_EXT=y, localmodconfig sans retirer GPU/USB/réseau/hibernation. Option mitigations=off exposée.
- SIGNATURE SECURE BOOT (openssl/sbsign/mokutil) — obligatoire.
- scx_rago : expose une BPF map + l'outil rago-sched-hint pour que le launcher tague l'arbre de processus du jeu (thread de rendu) comme latency-critical AVANT lancement. Détecte la topologie : Ryzen X3D → route le jeu sur le CCD à cache 3D ; Intel hybride → jeu sur P-cores, fond sur E-cores. Filet EEVDF+BORE.
- build : source+patch+config, Clang/ThinLTO, paquet, install, signe, maj bootloader. Reproductible.
Code complet + tests (SCHED_CLASS_EXT, scx chargé, cyclictest, Secure Boot ON, routage X3D/P-E vérifié). Aucun anti-triche.
```

---

## M1 — Tuning hôte & latence

**Objectif.** Régler l'hôte pour le jeu natif (sans isolation VM).

**Fichiers.** `host/setup_host_tuning.sh` · `host/tuned/rago-gaming/tuned.conf` · `host/sysctl.d/99-rago.conf` · `host/udev/60-rago-iosched.rules`

**Spécification.** tuned (latency-performance, gouverneur performance, `kernel.watchdog=0`) ; sysctl (`vm.max_map_count` élevé, `swappiness=10`, rmem/wmem, fq_codel, `split_lock_mitigate=0`) ; scheduler NVMe none/mq-deadline ; zram ; **🆕 politique THP par défaut `madvise` (surchargée par jeu via M14)** ; threadirqs + affinité IRQ raisonnable (PAS d'isolation stricte de cœurs — scx_rago route déjà le jeu).

**Dépendances.** M0.

**Critères.** `tuned-adm active` = rago-gaming ; gouverneur performance ; 1% low MangoHud.

**Prompt.**
```
Module M1 — Tuning hôte. Génère host/setup_host_tuning.sh, host/tuned/rago-gaming/tuned.conf, host/sysctl.d/99-rago.conf, host/udev/60-rago-iosched.rules.
tuned latency-performance (gouverneur performance, watchdog=0) ; sysctl (max_map_count élevé, swappiness=10, rmem/wmem, fq_codel, split_lock_mitigate=0) ; NVMe none/mq-deadline ; zram ; THP madvise (surchargeable par jeu via M14) ; threadirqs + affinité IRQ raisonnable, PAS d'isolation stricte (scx_rago route le jeu). Code complet + test (tuned-adm, 1% low).
```

---

## M2 — Couche native Proton (+ hooks profils & shaders)

**Objectif.** Jeu natif d'élite, avec les points d'accroche pour les profils par jeu et l'anti-stutter.

**Fichiers.** `host/setup_proton_layer.sh` · `host/gamescope/rago-session.sh` · configs gamemode/MangoHud

**Spécification.** Steam (+ Proton-GE épinglé), Heroic (Epic/GOG), Lutris optionnel ; runtimes Proton EAC/BattlEye activés. Session **gamescope** plein écran (VRR/HDR, `--rt`, tearing en jeu). gamemode + MangoHud. **🆕 Hook de profil** : au lancement d'un jeu, appeler M14 pour appliquer son profil (gouverneur, THP, hint scheduler, horloges GPU). **🆕 Pré-chauffage du cache shaders** (Fossilize/cache partagé par GPU sur RAGO-LIB) pour réduire le stutter de compilation.

**Dépendances.** M0, M1, M14 (profils).

**Critères.** Jeu Proton plein écran ; MangoHud ; profil appliqué au lancement ; shaders pré-chauffés.

**Prompt.**
```
Module M2 — Couche Proton. Génère host/setup_proton_layer.sh, host/gamescope/rago-session.sh, configs gamemode/MangoHud.
Steam (+Proton-GE épinglé), Heroic, Lutris optionnel, runtimes Proton EAC/BattlEye. Session gamescope plein écran (VRR/HDR, --rt, tearing). gamemode + MangoHud. Hook : au lancement d'un jeu, applique son profil via M14 (gouverneur/THP/hint scheduler/horloges GPU) et appelle le hint scheduler M0. Pré-chauffage du cache shaders (Fossilize, cache par GPU sur RAGO-LIB). Code complet + test (jeu plein écran, profil appliqué, shaders pré-chauffés).
```

---

## M3 — Chiffrement LUKS2 + TPM 2.0

**Objectif.** Disque hôte chiffré, déverrouillage TPM, compatible hibernation du switch.

**Fichiers.** `host/setup_secure_encryption.sh`

**Spécification.** AES-NI/AVX2 ; LUKS2 (aes-xts, argon2id) ; `systemd-cryptenroll --tpm2-pcrs=0+7` **+ passphrase de secours** ; `/etc/crypttab` + initramfs. **Swap d'hibernation chiffré déverrouillé avant resume** (cohérent M6).

**Dépendances.** TPM ; intégré M12.

**Critères.** Auto-unlock si intègre ; fallback passphrase ; FPS inchangé.

**Prompt.**
```
Module M3 — LUKS2/TPM. Génère host/setup_secure_encryption.sh. AES-NI/AVX2 ; luksFormat luks2 aes-xts 512 sha512 argon2id ; enrôle TPM --tpm2-pcrs=0+7 ET passphrase de secours ; crypttab + initramfs ; swap d'hibernation chiffré déverrouillé avant resume (M6). Avertit PCR7. Code complet + test (auto-unlock, fallback).
```

---

## M4 — Mises à jour atomiques A/B

**Fichiers.** `host/manage_atomic_updates.sh`

**Spécification.** Slot actif (`findmnt`), image signée sur slot passif, bascule systemd-boot, watchdog/rollback si `multi-user.target` non atteint. Jamais le slot actif. Deux slots chiffrés.

**Dépendances.** Partitions A/B (M13).

**Critères.** Update→passif ; échec→rollback.

**Prompt.**
```
Module M4 — Updates A/B. Génère host/manage_atomic_updates.sh. Slot actif (findmnt), image signée sur le passif (vérif), bascule systemd-boot (set-oneshot→set-default), watchdog/rollback si multi-user.target non atteint, jamais le slot actif, deux slots chiffrés (M3). Code complet + test (update→passif, échec→rollback).
```

---

## M5 — Micro-Windows (moteur de jeu bare-metal, aligné Vanguard On-Demand)

**Objectif.** Windows réduit à un moteur de jeu invisible, mais **avec la pile de sécurité moderne activée** pour satisfaire l'anti-triche le plus strict.

> **Cibles : RAM idle ~300-500 Mo, disque ~2-3,5 Go, boot ~2-4 s.** Pas de « quelques Mo » (impossible).

**Fichiers.** `windows/compile_micro_engine.ps1` · `windows/autounattend.xml`

**Spécification.**
- Base **Windows 11 IoT Enterprise LTSC 25H2** (BYOL : ISO fournie par l'utilisateur, construite localement).
- DISM offline : retirer appx/capabilities/features superflus, **purge agressive du WinSxS** (non-serviçabilité **assumée** — pas de Windows Update, on reconstruit l'image → gain disque > tiny11). Désactiver services non critiques (SysMain, DiagTrack, WSearch, Spooler, wuauserv, indexation). **Forcer les services anti-triche (vgc/vgk, EAC, BattlEye) en automatique.** Shell Winlogon = `rago-shell` (pas de bureau). Pagefile dynamique off.
- **🆕 GARDER ACTIVÉS (ne pas stripper !)** : Secure Boot, TPM 2.0, **VBS, HVCI, IOMMU** — c'est ce qu'exige **Vanguard On-Demand** (l'anti-triche se charge au lancement du jeu et se décharge à la fermeture = exactement le modèle Rago). Plus noyau NT, WDDM/DirectX, pilote GPU, .NET, VC++, pile réseau.
- **🆕 Deux profils de sécurité (pilotés par M14)** : **« compat max »** (VBS/HVCI/IOMMU on → Vanguard/Ricochet) vs **« perf »** (VBS off → EAC/BattlEye, FPS max). Rago applique le bon profil selon le jeu.
- `autounattend.xml` : OOBE sauté, **compte local RagoPlayer AutoLogon silencieux — aucun compte Microsoft, aucun écran de connexion/verrouillage, aucun mot de passe**. L'utilisateur ne voit jamais Windows s'authentifier. Pas de BitLocker.

**Dépendances.** Image Windows LTSC/IoT fournie ; M14 (profils de sécurité).

**Critères.** RAM idle ~300-500 Mo ; pas d'`explorer.exe`/`SearchIndexer` ; **un jeu cible + son anti-triche tournent** ; Vanguard On-Demand validé (Secure Boot/TPM/VBS/HVCI/IOMMU on).

**Prompt.**
```
Module M5 — Micro-Windows (aligné Vanguard On-Demand). Génère windows/compile_micro_engine.ps1 (DISM offline) et windows/autounattend.xml.
Cible RAM idle ~300-500 Mo, ~2-3,5 Go disque. Base Windows 11 IoT Enterprise LTSC 25H2, BYOL.
- DISM : retire appx/capabilities/features superflus, PURGE AGRESSIVE du WinSxS (non-serviçabilité assumée), désactive services non critiques (ruche SYSTEM offline), FORCE les services anti-triche (vgc/vgk, EAC, BattlEye) en automatique, shell Winlogon = rago-shell (pas de bureau), pagefile dynamique off.
- GARDE ACTIVÉS : Secure Boot, TPM 2.0, VBS, HVCI, IOMMU (requis par Vanguard On-Demand) + noyau NT, WDDM/DirectX, pilote GPU, .NET, VC++, réseau.
- Deux profils de sécurité appliqués par M14 : « compat max » (VBS/HVCI/IOMMU on → Vanguard/Ricochet) vs « perf » (VBS off → EAC/BattlEye).
- autounattend.xml : OOBE sauté, compte local RagoPlayer AutoLogon silencieux, aucun compte Microsoft, aucun écran de connexion/verrouillage, pas de BitLocker.
Teste un JEU RÉEL + anti-triche + Vanguard On-Demand. Code complet. Aucune dissimulation.
```

---

## M6 — Fast OS Switch (modes Rapide/Préservé, continuité visuelle)

**Objectif.** Bascule vers le micro-Windows **la plus rapide ET la plus fluide** ; l'utilisateur ne doit jamais avoir l'impression de quitter Rago ni de booter sur Windows.

**Fichiers.** `host/bin/rago-switch-to-windows.sh` · config hibernation/resume · entrées systemd-boot · partition `RAGO-COMM` (FAT32) · `windows/rago-shell/`

**Spécification.**
- **systemd-boot timeout=0**, défaut=Linux (avec `resume=`), one-shot vers Windows via `bootctl set-oneshot` ou `efibootmgr --bootnext`. **Design asymétrique** : Windows sans état, `shutdown /r`, n'écrit jamais dans l'ordre de boot (one-shot auto-consommé → retour Linux).
- **🆕 Deux modes de bascule** :
  - **« Rapide » (défaut depuis le launcher)** : session légère → **on n'hiberne pas** ; on quitte vers une micro-session launcher jetable qui **cold-boote en ~2 s** au retour (saute le poste hibernation).
  - **« Session préservée »** : session chargée (travail en cours) → hibernation complète (LZ4/zstd, cf. M8). Le launcher choisit automatiquement selon l'état.
- **🆕 Continuité visuelle** : au clic, **geler la dernière frame Rago** et l'afficher comme splash ; combiné au splash UEFI (M8), **zéro écran noir**, le jeu « se matérialise » par-dessus Rago.
- **🆕 Pré-conditionnement GPU + warm reset** : décharger proprement le pilote GPU (état connu) avant la bascule pour fiabiliser la ré-init côté Windows (anti « écran noir au resume ») ; privilégier un **warm reset** déterministe.
- Hibernation sur swap LUKS (déverrouillé avant resume, M3). **Fast Startup Windows désactivé** (verrouille le NTFS). Linux ne monte pas le NTFS Windows (comm FAT32).
- **Loi physique** : POST incompressible → ~6-13 s porte-à-porte (optimisé M8), masqué par le splash. Pas d'instantané.

**Dépendances.** M0 (noyau signé), M3 (LUKS/resume), M5 (rago-shell), M8 (optimisation), M11 (le launcher appelle le switch), M13 (partitions).

**Critères.** Clic → (mode auto) → micro-Windows direct sur le jeu plein écran, **aucun écran noir, aucun login Windows** → jeu+anti-triche OK → fermeture → session Rago restaurée ; reboot inattendu → Linux.

**Prompt.**
```
Module M6 — Fast OS Switch (modes + continuité visuelle). Génère host/bin/rago-switch-to-windows.sh, config hibernation/resume (swap LUKS, hook initramfs), entrées systemd-boot (timeout=0, défaut=Linux avec resume, + Windows), partition FAT32 RAGO-COMM, windows/rago-shell/.
OBJECTIF UX : jamais l'impression de quitter Rago ni de booter sur Windows ; pas de login Windows, pas de bureau, juste le jeu, splash Rago continu.
- Design asymétrique : Windows sans état, shutdown /r, n'écrit RIEN dans l'ordre de boot (one-shot auto-consommé via bootctl set-oneshot ou efibootmgr --bootnext).
- Deux modes : « Rapide » (session légère → PAS d'hibernation, micro-session launcher qui cold-boote ~2s au retour) et « Session préservée » (session chargée → hibernation LZ4/zstd). Le launcher choisit auto selon l'état.
- Continuité visuelle : geler la dernière frame Rago comme splash (avec le splash UEFI de M8) → zéro écran noir.
- Pré-conditionnement GPU (décharge propre, état connu) + warm reset déterministe (anti écran-noir au resume).
- Fast Startup Windows désactivé ; Linux ne monte pas le NTFS (comm FAT32) ; Secure Boot des deux côtés (M0 signé).
Timing honnête ~6-13s (POST masqué par le splash). Code complet + tests (clic→jeu plein écran sans écran noir ni login, fermeture→session restaurée, reboot inattendu→Linux). Bare-metal, aucune dissimulation.
```

---

## M7 — Bibliothèque partagée & installation

**Objectif.** Gérer/installer ses jeux Windows depuis l'UI Rago ; le micro-Windows les lance au native speed.

**Fichiers.** `host/bin/rago-library.sh` · `windows/rago-agent/` · partition `RAGO-LIB` (NTFS)

**Spécification.** NTFS `RAGO-LIB` partagée (Linux écrit `ntfs3`, Windows lit natif, jamais simultané). Clients Steam/Epic/Riot côté Windows. Flux : UI écrit la requête dans RAGO-COMM → l'agent Windows installe via le client store, applique prérequis/registre, met en cache, renvoie la progression. Métadonnées unifiées `RAGO-LIB/.rago/`.

**Dépendances.** M6, M5, M11.

**Critères.** Install depuis l'UI → finalisé → lancement direct au switch.

**Prompt.**
```
Module M7 — Bibliothèque partagée & install. Génère host/bin/rago-library.sh (ntfs3) et windows/rago-agent/ + schéma RAGO-LIB (NTFS). Linux écrit ntfs3, Windows lit natif, jamais simultané. Clients Steam/Epic/Riot côté Windows. Flux : UI écrit dans RAGO-COMM ; l'agent Windows installe via le client store, prérequis+registre, cache, renvoie la progression. Métadonnées RAGO-LIB/.rago/. Honnête : l'install Windows réelle se fait côté Windows une fois. Code complet + test (install UI → lancement direct).
```

---

## M8 — Optimisation du switch (auto-POST, hibernation rapide, splash UEFI)

**Objectif.** Rendre la bascule la plus rapide physiquement possible et la *paraître* instantanée.

**Fichiers.** `host/bin/rago-fastboot-profile.sh` (auto-tuning POST) · config hibernation (LZ4/zstd, threads) · splash UEFI (BGRT) · trimming micro-Windows · `tests/bench_switch.sh`

**Spécification.**
- **🆕 Auto-tuning du POST (le plus gros levier)** : détecter le chipset et **activer/documenter Memory Context Restore + DDR Training Runtime Reduction + Ultra Fast Boot** (le ré-entraînement DDR5 fait passer le POST de 45-90 s à ~1-5 s — mesures réelles). Piloter via les variables UEFI quand l'OEM l'expose, sinon guide précis par carte.
- **🆕 Hibernation rapide** : compression **LZ4** (noyau ≥6.9, `hib_compression=lz4`) ou **zstd**, **multi-thread** (`hibernate_compression_threads=5-6`, +~12 % resume), session lean, swap NVMe dédié. `/sys/power/image_size` plafonné.
- **Splash UEFI Rago** (BGRT/OEM logo) couvrant tout le POST → zéro écran noir (complète le gel de frame de M6).
- **Trimming micro-Windows** (cohérent M5) : init pilotes du seul matériel présent.
- **🆕 (R&D, désactivé par défaut)** resume d'image Windows pré-cuite par jeu (arrivée directe en jeu) — caveats : verrou NTFS (démonter RAGO-LIB avant d'hiberner Windows), anti-triche au resume, invalidation au patch. Par jeu, après validation.
- `bench_switch.sh` : chronomètre hibernate/POST/boot, consigne le total. **Mesurer, pas promettre.** Cibles : 2-4 / 1-5 / 2-4 s, total ~6-13 s.

**Dépendances.** M6, M5, M0/M13.

**Critères.** POST réduit mesuré ; resume rapide ; splash visible ; total consigné.

**Prompt.**
```
Module M8 — Optimisation du switch. Génère host/bin/rago-fastboot-profile.sh (auto-tuning POST), la config hibernation (LZ4/zstd multi-thread, image_size, swap NVMe dédié), le splash UEFI Rago (BGRT), le trimming de boot du micro-Windows, le cadre (désactivé par défaut) du resume d'image Windows pré-cuite par jeu (R&D), et tests/bench_switch.sh.
- Auto-POST (gros levier) : détecte le chipset, active/documente Memory Context Restore + DDR Training Runtime Reduction + Ultra Fast Boot (ré-entraînement DDR5 : POST 45-90s → ~1-5s). Pilote via variables UEFI si exposé, sinon guide par carte.
- Hibernation : hib_compression=lz4 (≥6.9) ou zstd, hibernate_compression_threads=5-6, session lean, swap NVMe dédié, image_size plafonné.
- Splash UEFI (BGRT) couvrant tout le POST (complète le gel de frame M6).
Respecte la loi physique (POST incompressible, pas d'instantané). bench_switch.sh chronomètre les 3 postes. Cibles 2-4/1-5/2-4s — à VALIDER. Code/configs complets + benchmark.
```

---

## M9 — Énergie & thermique GPU

**Fichiers.** `host/bin/rago_gpu_lock_pstates.sh` · `host/bin/rago_gpu_thermal_monitor.py`

**Spécification.** `nvidia-smi -pm 1`/`-ac` (Nvidia) ou `pp_*` (AMD) ; monitor T° (NVML/hwmon), seuil ~83 °C, courbe ventilateurs. (OC in-game côté Windows — note.) **🆕 Horloges GPU surchargées par le profil du jeu (M14).**

**Dépendances.** M1/M2/M14.

**Critères.** Lecture T° OK ; P-states verrouillés ; profil horloges appliqué.

**Prompt.**
```
Module M9 — Énergie/thermique GPU. Génère host/bin/rago_gpu_lock_pstates.sh et host/bin/rago_gpu_thermal_monitor.py. nvidia-smi -pm 1/-ac ou AMD pp_* ; monitor T° (NVML/hwmon) seuil ~83°C, courbe ventilateurs. Horloges surchargées par le profil jeu (M14). OC in-game côté Windows (note). Code complet + test lecture T°.
```

---

## M10 — Télémétrie & crash (Rust)

**Fichiers.** `daemons/rago-telemetry/{Cargo.toml,src/main.rs}` · `host/systemd/rago-telemetry.service`

**Spécification.** Lit journald + erreurs session/switch ; JSON sur anomalie ; **anonymisation regex avant écriture** ; HTTPS reqwest (endpoint configurable) ; cache hors-ligne. **Opt-in RGPD** (off par défaut).

**Critères.** Build OK ; crash simulé → JSON anonymisé.

**Prompt.**
```
Module M10 — Télémétrie Rust. Génère daemons/rago-telemetry/{Cargo.toml,src/main.rs} et host/systemd/rago-telemetry.service. Lit journald + erreurs session/switch ; JSON sur anomalie ; anonymise par regex (/home, IP, UUID, jetons) AVANT écriture ; HTTPS reqwest (endpoint configurable) ; cache /var/log hors-ligne. Opt-in RGPD (off). Cargo.toml (reqwest, serde_json, regex) + main.rs + test (crash simulé → JSON sans donnée perso).
```

---

## M11 — Rago UI (Tauri v2)

**Objectif.** Launcher unique : bibliothèque, lancement, profils, switch.

**Fichiers.** `rago-ui/src-tauri/{main.rs,Cargo.toml,tauri.conf.json}` · `rago-ui/src/App.tsx`

**Spécification.** **Tauri v2.** Commandes : `launch_native_game(id)` (Proton + applique profil M14 + hint scheduler M0), `launch_switch_game(id)` (switch M6 + profil de sécurité M5/M14), `install_game(id)` (M7), `get_system_stats()`. Écrans : Dashboard, **Bibliothèque unifiée** (Proton + switch, badge de couche), **Réglages** (matériel, mitigations, **mode de switch Rapide/Préservé**, **profils par jeu**). Thème sombre/néon. Confirmation avant switch.

**Dépendances.** M2, M6, M7, M14, M0 (hint).

**Critères.** `cargo tauri build` OK ; lance Proton + switch ; profils visibles ; bibliothèque unifiée.

**Prompt.**
```
Module M11 — Rago UI (Tauri v2). Génère rago-ui/src-tauri/{main.rs,Cargo.toml,tauri.conf.json} et rago-ui/src/App.tsx (+ vite/package.json).
Tauri v2 (capabilities v2). Commandes : launch_native_game (Proton + applique profil M14 + hint scheduler M0), launch_switch_game (switch M6 + profil sécurité), install_game (M7), get_system_stats. Écrans : Dashboard, Bibliothèque unifiée (Proton+switch, badge de couche), Réglages (matériel, mitigations, mode de switch Rapide/Préservé, profils par jeu). Thème sombre/néon, confirmation avant switch. Code complet buildable + test (build, lancement Proton+switch, profils).
```

---

## M12 — Installateur & migration

**Objectif.** Installer Rago (depuis Windows ou Linux), **clean** ou **migration** (sauvegarde + réimport), BYOL (ISO Windows fournie, micro-Windows construit localement).

**Fichiers.** `installer/rago-installer` · `installer/partition.sh` · `installer/migrate.sh` · `installer/build_micro_windows.sh`

**Spécification.** GPT (dry-run + confirmations) : ESP 1Go · Rago A ~80-100Go (LUKS) · B · partition Windows native · RAGO-LIB (NTFS) · RAGO-COMM (FAT32) · partition données (home). Modes `clean` / `migration` (sauvegarde fichiers utilisateur en lecture, install, réimport). BYOL : demande l'ISO, construit via `compile_micro_engine.ps1` (M5). Intègre LUKS (M3), A/B (M4), noyau signé (M0), systemd-boot (M6). **🆕 Option NVMe dédié par OS** (détecte 1 ou 2 disques).

**Dépendances.** M0, M3, M4, M5, M6, M13.

**Critères.** Clean OK ; migration → données réimportées ; micro-Windows construit depuis l'ISO ; boot Rago.

**Prompt.**
```
Module M12 — Installateur & migration. Génère installer/rago-installer (Calamares ou custom), installer/partition.sh, installer/migrate.sh, installer/build_micro_windows.sh.
Partitionnement GPT (dry-run+confirmations) : ESP 1Go, Rago A ~80-100Go (LUKS), B, partition Windows native, RAGO-LIB (NTFS), RAGO-COMM (FAT32), partition données (home). Détecte 1 ou 2 NVMe (option OS dédié par disque).
Modes clean / migration (sauvegarde fichiers utilisateur depuis ancien Windows/Linux, install, réimport dans la home).
BYOL : demande l'ISO Windows, construit le micro-Windows localement via compile_micro_engine.ps1 (M5). Aucune redistribution Windows.
Intègre LUKS (M3), A/B (M4), noyau signé (M0), systemd-boot (M6). Code complet + tests (clean, migration, build micro-Windows).
```

---

## M13 — Build & packaging ISO

**Fichiers.** `iso/Rago_ISO_Builder/build_rago_iso.sh` · `profile/packages.x86_64` · `airootfs/etc/rago/hardware_check.sh` · `airootfs/.../rago-init.service`

**Spécification.** Base archiso. packages : noyau Rago, steam, gamescope, gamemode, mangohud, proton-ge, heroic, rust, pipewire, cryptsetup, tpm2-tools, sbsigntools, dkms, linux-headers, systemd-boot, ntfs3, installateur. airootfs reçoit host/* + démons + unités + profils (M14). `hardware_check.sh` : **TPM 2.0 + UEFI/Secure Boot** (plus d'IOMMU requis côté hôte — plus de passthrough). L'ISO ne contient **pas** Windows (BYOL).

**Dépendances.** Tous.

**Critères.** ISO boote, check OK, installateur se lance.

**Prompt.**
```
Module M13 — Build ISO. Génère iso/Rago_ISO_Builder/build_rago_iso.sh, profile/packages.x86_64, airootfs/etc/rago/hardware_check.sh, airootfs/.../rago-init.service.
Base archiso. packages : noyau Rago, steam, gamescope, gamemode, mangohud, proton-ge, heroic, rust, pipewire, cryptsetup, tpm2-tools, sbsigntools, dkms, linux-headers, systemd-boot, ntfs3, installateur (M12), profils (M14). airootfs reçoit host/* + démons compilés + unités + profils. hardware_check.sh : TPM 2.0 + UEFI/Secure Boot. L'ISO ne contient PAS Windows (BYOL). Compile les démons Rust avant airootfs. Code complet + test (boot ISO en VM).
```

---

## M14 — Profils par jeu (perf + sécurité) 🆕

**Objectif.** Pour chaque jeu, appliquer automatiquement **le profil optimal** sur les deux couches : perf (gouverneur, THP, hint scheduler, horloges GPU, mitigations) **et** sécurité Windows (VBS/HVCI on/off selon l'anti-triche). Base crowd-sourcée.

**Fichiers.** `profiles/` (base de profils, format JSON/TOML) · `daemons/rago-profiled/{Cargo.toml,src/main.rs}` (applique le profil au lancement)

**Spécification.**
- Un **profil par jeu** : `{ id, couche (proton|switch), cpu_governor, thp (madvise|always), sched_hint, gpu_clocks, mitigations (on|off), windows_security (compat_max|perf) }`.
- **`rago-profiled`** : au lancement (appelé par M11/M2), lit le profil et l'applique — côté Linux (gouverneur, THP, hint scheduler M0, horloges M9) ; côté switch, écrit le profil de sécurité dans RAGO-COMM pour que le micro-Windows (M5) l'applique (VBS/HVCI on/off).
- **Base communautaire** : profils partagés (comme ProtonDB, mais au niveau noyau/sécurité). Fallback profil par défaut sûr.

**Dépendances.** M0 (hint), M2 (hook), M5 (profils sécurité), M9 (horloges), M11 (UI).

**Critères.** Un jeu avec profil → gouverneur/THP/hint/horloges appliqués ; côté switch, VBS on/off selon le profil ; fallback sûr si pas de profil.

**Prompt.**
```
Module M14 — Profils par jeu (perf + sécurité). Génère profiles/ (schéma + exemples JSON/TOML) et daemons/rago-profiled/{Cargo.toml,src/main.rs}.
Profil = { id, couche proton|switch, cpu_governor, thp madvise|always, sched_hint, gpu_clocks, mitigations on|off, windows_security compat_max|perf }.
rago-profiled : au lancement (appelé par M11/M2), applique côté Linux (gouverneur, THP, hint scheduler M0, horloges M9) ; côté switch, écrit le profil de sécurité dans RAGO-COMM pour que M5 applique VBS/HVCI on/off. Base communautaire + fallback sûr. Cargo.toml + main.rs + test (profil appliqué sur les deux couches, fallback).
```

---

# PARTIE 3 — INJECTION & ORCHESTRATION

**Ordre :**
```
A : M0 → M1 → M14 (profils, tôt car M2/M5 en dépendent) → M2 → M3 → M4
B : M5 → M6 → M7 → M8
C : M9, M10 (parallélisables) → M11 → M12 → M13 (dernier)
```
*(M14 avance en phase A car M2 et M5 l'utilisent ; son `rago-profiled` peut démarrer minimal puis s'enrichir.)*

**Délégable à un subagent :** M5, M9, M10, M14, M2, recherche. **Non :** M0, M3, M4, M6, M12, M13.

---

# PARTIE 4 — PRÉREQUIS & RESSOURCES

- **Qui fait quoi** : Claude écrit tout le code ; toi tu fournis l'ISO Windows + la machine, compiles le noyau, **testes sur vrai matériel** (le hardware-in-the-loop est humain). Aucune machine louée ne teste tout (un cloud est une VM).
- **Matériel** : UEFI + Secure Boot activable, TPM 2.0, NVMe, RAM ≥16 Go (32+ pour compiler). **1 GPU suffit** (plus de passthrough). **Portable OK.** SSD externe (~50-60 €) pour tester sans toucher ton disque interne ; non-matériel en VM jetable.
- **À fournir** : ISO Windows (Win 11 conso gratuite pour tester, ou IoT LTSC eval ; licence par appareil ~90-295 $ pour la prod). **BYOL** : le client fournit SON ISO/licence → tu ne paies rien par client.
- **Auto-récupéré (open source)** : noyau+patchset, scx, Steam/Proton-GE/gamescope/gamemode/MangoHud, Heroic, Rust+crates, Tauri, systemd-boot, cryptsetup, tpm2-tools, sbsigntools.
- **Secure Boot/MOK** : gratuit (`openssl`/`sbsign`/`mokutil`). Noyau custom signé obligatoire (couche 2).

---

# PARTIE 5 — AVANCÉ / R&D / PREMIUM (au-delà de la v1)

> Capturé pour la roadmap, clairement hors v1. Notation : ✅ faisable · 🔧 difficile · 🧪 spéculatif · 🏭 matériel certifié.

- **🏭 Rago Console (firmware coreboot)** — remplacer le firmware vendeur par coreboot sur du **matériel certifié** → POST < 1 s → switch **~3-5 s**. La seule façon de s'approcher du quasi-instantané. **SKU premium** (métier de hardware). Vision 2-3 ans.
- **🔧 Coordinateur de switch en app UEFI** — une app UEFI Rago possède le framebuffer (GOP) pendant tout le POST → splash au niveau firmware, **zéro écran noir** même avant l'OS. La couche idéale pour la continuité visuelle.
- **🧪 Hibernation incrémentale** — pré-écrire la partie invariante de l'image, flusher seulement les dirty pages au switch. Chemin réaliste = micro-session launcher (déjà dans M6 « Rapide »).
- **🔧 Cache shaders unifié pré-chauffé** — étendre Fossilize à tout le système, par GPU, sur RAGO-LIB (anti-stutter).
- **🧪 Chemin d'assets accéléré (DirectStorage-like sur Linux)** — immature, à surveiller.

---

*Fin de la bible v7. Deux couches, zéro VM, zéro masquage. Optimisations intégrées : scx_rago informé, routage X3D/P-E, modes de switch, auto-POST, hibernation rapide, continuité visuelle, profils par jeu, alignement Vanguard On-Demand. Tout est légitime et bare-metal.*
