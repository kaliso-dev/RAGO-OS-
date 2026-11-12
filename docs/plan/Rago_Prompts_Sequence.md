# RAGO OS PRO — Séquence de prompts (v3 — 2 couches, optimisation maximale)

> Donne la **bible** (`Rago_OS_Pro_Build_Bible.md` v7) au projet Claude comme référence. Puis **un module à la fois**, dans l'ordre, testé avant le suivant. Bloc contexte en tête de chaque session.
> Ordre : **M0 → M1 → M14 → M2 → M3 → M4 → M5 → M6 → M7 → M8 → M9 → M10 → M11 → M12 → M13.**
> (M14 avance tôt car M2 et M5 l'utilisent.)

## 🔑 BLOC CONTEXTE PERMANENT (coller en tête de CHAQUE session)
```
Tu es Ingénieur Principal Systèmes sur Rago OS Pro : un OS Linux gaming à DEUX couches — (1) jeu natif via Proton (élite, base type CachyOS), et (2) un Fast OS Switch bare-metal (hibernation Linux + micro-Windows natif démarré direct sur le jeu) pour les jeux à anti-triche strict. PAS de VM. Pile : noyau Linux custom (≥6.12 + patchset CachyOS, sched_ext/scx_lavd, ordonnanceur scx_rago informé par le launcher) · Proton/Steam/gamescope · Rust · Tauri v2 · systemd-boot. Optimisations : canal launcher→ordonnanceur, routage auto X3D/P-E, auto-tuning POST (MCR/DTRR), hibernation LZ4/zstd multi-thread, profils par jeu (perf+sécurité), alignement Vanguard On-Demand (micro-Windows 25H2 avec Secure Boot/TPM/VBS/HVCI/IOMMU activés). Tout est bare-metal et légitime : aucune dissimulation. Code de production complet, sans ellipses, avec critère de test par module. Référence : Rago_OS_Pro_Build_Bible.md.
```

## ▶️ PREMIER PROMPT
Colle le BLOC CONTEXTE, puis :
```
Avant de coder : lis Rago_OS_Pro_Build_Bible.md v7 en entier (architecture 2 couches, modules M0-M14, Partie 5 R&D), confirme en 5 lignes max que tu as l'ensemble en tête et qu'on avance un module à la fois, testé avant le suivant. Puis on commence par M0. [colle le PROMPT M0]
```

---

# PHASE A

## M0 — Noyau + scx_rago informé
```
Module M0 — Noyau + scx_rago informé. Génère kernel/build_rago_kernel.sh, kernel/config/rago-gaming.config, kernel/patches/ (descriptif), kernel/scx/ (fork scx_lavd→scx_rago), host/systemd/rago-scx.service, host/bin/rago-sched-hint.
- Base ≥6.12 + patchset CachyOS. Config : PREEMPT, HZ=1000, MGLRU, LTO_CLANG_THIN, x86-64-v3 (détecte v4), ZRAM, pstate performance, SCHED_CLASS_EXT=y, localmodconfig sans retirer GPU/USB/réseau/hibernation. Option mitigations=off exposée.
- SIGNATURE SECURE BOOT (openssl/sbsign/mokutil) — obligatoire.
- scx_rago : expose une BPF map + l'outil rago-sched-hint pour que le launcher tague l'arbre de processus du jeu (thread de rendu) comme latency-critical AVANT lancement. Détecte la topologie : Ryzen X3D → route le jeu sur le CCD à cache 3D ; Intel hybride → jeu sur P-cores, fond sur E-cores. Filet EEVDF+BORE.
- build : source+patch+config, Clang/ThinLTO, paquet, install, signe, maj bootloader. Reproductible.
Code complet + tests (SCHED_CLASS_EXT, scx chargé, cyclictest, Secure Boot ON, routage X3D/P-E). Aucun anti-triche.
```

## M1 — Tuning hôte
```
Module M1 — Tuning hôte. Génère host/setup_host_tuning.sh, host/tuned/rago-gaming/tuned.conf, host/sysctl.d/99-rago.conf, host/udev/60-rago-iosched.rules.
tuned latency-performance (gouverneur performance, watchdog=0) ; sysctl (max_map_count élevé, swappiness=10, rmem/wmem, fq_codel, split_lock_mitigate=0) ; NVMe none/mq-deadline ; zram ; THP madvise (surchargeable par jeu via M14) ; threadirqs + affinité IRQ raisonnable, PAS d'isolation stricte (scx_rago route le jeu). Code complet + test (tuned-adm, 1% low).
```

## M14 — Profils par jeu (perf + sécurité)
```
Module M14 — Profils par jeu (perf + sécurité). Génère profiles/ (schéma + exemples JSON/TOML) et daemons/rago-profiled/{Cargo.toml,src/main.rs}.
Profil = { id, couche proton|switch, cpu_governor, thp madvise|always, sched_hint, gpu_clocks, mitigations on|off, windows_security compat_max|perf }.
rago-profiled : au lancement (appelé par M11/M2), applique côté Linux (gouverneur, THP, hint scheduler M0, horloges M9) ; côté switch, écrit le profil de sécurité dans RAGO-COMM pour que M5 applique VBS/HVCI on/off. Base communautaire + fallback sûr. Cargo.toml + main.rs + test (profil appliqué sur les deux couches, fallback).
```

## M2 — Couche Proton
```
Module M2 — Couche Proton. Génère host/setup_proton_layer.sh, host/gamescope/rago-session.sh, configs gamemode/MangoHud.
Steam (+Proton-GE épinglé), Heroic, Lutris optionnel, runtimes Proton EAC/BattlEye. Session gamescope plein écran (VRR/HDR, --rt, tearing). gamemode + MangoHud. Hook : au lancement d'un jeu, applique son profil via M14 et appelle le hint scheduler M0. Pré-chauffage du cache shaders (Fossilize, cache par GPU sur RAGO-LIB). Code complet + test (jeu plein écran, profil appliqué, shaders pré-chauffés).
```

## M3 — LUKS2/TPM
```
Module M3 — LUKS2/TPM. Génère host/setup_secure_encryption.sh. AES-NI/AVX2 ; luksFormat luks2 aes-xts 512 sha512 argon2id ; enrôle TPM --tpm2-pcrs=0+7 ET passphrase de secours ; crypttab + initramfs ; swap d'hibernation chiffré déverrouillé avant resume (M6). Avertit PCR7. Code complet + test (auto-unlock, fallback).
```

## M4 — Updates A/B
```
Module M4 — Updates A/B. Génère host/manage_atomic_updates.sh. Slot actif (findmnt), image signée sur le passif (vérif), bascule systemd-boot (set-oneshot→set-default), watchdog/rollback si multi-user.target non atteint, jamais le slot actif, deux slots chiffrés (M3). Code complet + test (update→passif, échec→rollback).
```

---

# PHASE B

## M5 — Micro-Windows (aligné Vanguard On-Demand)
```
Module M5 — Micro-Windows (aligné Vanguard On-Demand). Génère windows/compile_micro_engine.ps1 (DISM offline) et windows/autounattend.xml.
Cible RAM idle ~300-500 Mo, ~2-3,5 Go disque. Base Windows 11 IoT Enterprise LTSC 25H2, BYOL.
- DISM : retire appx/capabilities/features superflus, PURGE AGRESSIVE du WinSxS (non-serviçabilité assumée), désactive services non critiques (ruche SYSTEM offline), FORCE les services anti-triche (vgc/vgk, EAC, BattlEye) en automatique, shell Winlogon = rago-shell (pas de bureau), pagefile dynamique off.
- GARDE ACTIVÉS : Secure Boot, TPM 2.0, VBS, HVCI, IOMMU (requis par Vanguard On-Demand) + noyau NT, WDDM/DirectX, pilote GPU, .NET, VC++, réseau.
- Deux profils de sécurité appliqués par M14 : « compat max » (VBS/HVCI/IOMMU on → Vanguard/Ricochet) vs « perf » (VBS off → EAC/BattlEye).
- autounattend.xml : OOBE sauté, compte local RagoPlayer AutoLogon silencieux, aucun compte Microsoft, aucun écran de connexion/verrouillage, pas de BitLocker.
Teste un JEU RÉEL + anti-triche + Vanguard On-Demand. Code complet. Aucune dissimulation.
```

## M6 — Fast OS Switch (modes + continuité visuelle)
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

## M7 — Bibliothèque partagée & install
```
Module M7 — Bibliothèque partagée & install. Génère host/bin/rago-library.sh (ntfs3) et windows/rago-agent/ + schéma RAGO-LIB (NTFS). Linux écrit ntfs3, Windows lit natif, jamais simultané. Clients Steam/Epic/Riot côté Windows. Flux : UI écrit dans RAGO-COMM ; l'agent Windows installe via le client store, prérequis+registre, cache, renvoie la progression. Métadonnées RAGO-LIB/.rago/. Honnête : l'install Windows réelle se fait côté Windows une fois. Code complet + test (install UI → lancement direct).
```

## M8 — Optimisation du switch
```
Module M8 — Optimisation du switch. Génère host/bin/rago-fastboot-profile.sh (auto-tuning POST), la config hibernation (LZ4/zstd multi-thread, image_size, swap NVMe dédié), le splash UEFI Rago (BGRT), le trimming de boot du micro-Windows, le cadre (désactivé par défaut) du resume d'image Windows pré-cuite par jeu (R&D), et tests/bench_switch.sh.
- Auto-POST (gros levier) : détecte le chipset, active/documente Memory Context Restore + DDR Training Runtime Reduction + Ultra Fast Boot (ré-entraînement DDR5 : POST 45-90s → ~1-5s). Pilote via variables UEFI si exposé, sinon guide par carte.
- Hibernation : hib_compression=lz4 (≥6.9) ou zstd, hibernate_compression_threads=5-6, session lean, swap NVMe dédié, image_size plafonné.
- Splash UEFI (BGRT) couvrant tout le POST (complète le gel de frame M6).
Respecte la loi physique (POST incompressible, pas d'instantané). bench_switch.sh chronomètre les 3 postes. Cibles 2-4/1-5/2-4s — à VALIDER. Code/configs complets + benchmark.
```

---

# PHASE C

## M9 — Énergie/thermique GPU
```
Module M9 — Énergie/thermique GPU. Génère host/bin/rago_gpu_lock_pstates.sh et host/bin/rago_gpu_thermal_monitor.py. nvidia-smi -pm 1/-ac ou AMD pp_* ; monitor T° (NVML/hwmon) seuil ~83°C, courbe ventilateurs. Horloges surchargées par le profil jeu (M14). OC in-game côté Windows (note). Code complet + test lecture T°.
```

## M10 — Télémétrie Rust
```
Module M10 — Télémétrie Rust. Génère daemons/rago-telemetry/{Cargo.toml,src/main.rs} et host/systemd/rago-telemetry.service. Lit journald + erreurs session/switch ; JSON sur anomalie ; anonymise par regex (/home, IP, UUID, jetons) AVANT écriture ; HTTPS reqwest (endpoint configurable) ; cache /var/log hors-ligne. Opt-in RGPD (off). Cargo.toml (reqwest, serde_json, regex) + main.rs + test (crash simulé → JSON sans donnée perso).
```

## M11 — Rago UI (Tauri v2)
```
Module M11 — Rago UI (Tauri v2). Génère rago-ui/src-tauri/{main.rs,Cargo.toml,tauri.conf.json} et rago-ui/src/App.tsx (+ vite/package.json).
Tauri v2 (capabilities v2). Commandes : launch_native_game (Proton + applique profil M14 + hint scheduler M0), launch_switch_game (switch M6 + profil sécurité), install_game (M7), get_system_stats. Écrans : Dashboard, Bibliothèque unifiée (Proton+switch, badge de couche), Réglages (matériel, mitigations, mode de switch Rapide/Préservé, profils par jeu). Thème sombre/néon, confirmation avant switch. Code complet buildable + test (build, lancement Proton+switch, profils).
```

## M12 — Installateur & migration
```
Module M12 — Installateur & migration. Génère installer/rago-installer (Calamares ou custom), installer/partition.sh, installer/migrate.sh, installer/build_micro_windows.sh.
Partitionnement GPT (dry-run+confirmations) : ESP 1Go, Rago A ~80-100Go (LUKS), B, partition Windows native, RAGO-LIB (NTFS), RAGO-COMM (FAT32), partition données (home). Détecte 1 ou 2 NVMe (option OS dédié par disque).
Modes clean / migration (sauvegarde fichiers utilisateur depuis ancien Windows/Linux, install, réimport dans la home).
BYOL : demande l'ISO Windows, construit le micro-Windows localement via compile_micro_engine.ps1 (M5). Aucune redistribution Windows.
Intègre LUKS (M3), A/B (M4), noyau signé (M0), systemd-boot (M6). Code complet + tests (clean, migration, build micro-Windows).
```

## M13 — Build ISO
```
Module M13 — Build ISO. Génère iso/Rago_ISO_Builder/build_rago_iso.sh, profile/packages.x86_64, airootfs/etc/rago/hardware_check.sh, airootfs/.../rago-init.service.
Base archiso. packages : noyau Rago, steam, gamescope, gamemode, mangohud, proton-ge, heroic, rust, pipewire, cryptsetup, tpm2-tools, sbsigntools, dkms, linux-headers, systemd-boot, ntfs3, installateur (M12), profils (M14). airootfs reçoit host/* + démons compilés + unités + profils. hardware_check.sh : TPM 2.0 + UEFI/Secure Boot. L'ISO ne contient PAS Windows (BYOL). Compile les démons Rust avant airootfs. Code complet + test (boot ISO en VM).
```

---

*Un module à la fois, testé avant le suivant. 2 couches, zéro VM, zéro masquage. La roadmap premium (console coreboot, coordinateur UEFI) est en Partie 5 de la bible.*
