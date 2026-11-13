---
type: pilotage
tags: [pilotage, questions]
maj: 2026-11-13
---
# Questions ouvertes

Retour à [[Projet]]. Règle : en cas de doute, ne jamais deviner — écrire la question ici en **À VÉRIFIER** / **À DÉCIDER** et prévenir Sofiene.

| Question | Statut |
|---|---|
| Machine de test : portable seul, ou SSD externe / petit PC dédié ? | À DÉCIDER ([[Prérequis matériel]]) |
| Modèle de prix exact et moment du passage au payant | À DÉCIDER ([[Monétisation]]) |
| Garder Windows Defender dans le micro-Windows (certains anti-triche l'aiment) | À DÉCIDER ([[Micro-Windows]]) |
| Nom public / marque / charte graphique de Rago OS | À DÉCIDER |
| Un ou deux NVMe sur la machine cible (change le partitionnement) | À VÉRIFIER ([[M12 Installateur]]) |
| Épingler les sources du noyau : version 6.18.x exacte + commits CachyOS (`kernel/patches/sources.lock` est en `PENDING`, `build_rago_kernel.sh lock`) — impossible depuis l'environnement de Claude (kernel.org et GitHub bloqués) | À VÉRIFIER ([[M0 Noyau scx_rago]]) |
| Le patchset CachyOS 6.18 fournit-il `CONFIG_X86_64_VERSION` ? (sinon le script passe par `-march=x86-64-vN`) | À VÉRIFIER ([[M0 Noyau scx_rago]]) |
| `shim-signed` disponible sur la base Rago (Arch : AUR) pour la chaîne shim → systemd-boot ? Sinon inscrire la clé dans la db UEFI | À VÉRIFIER ([[Sécurité et boot]]) |
| Seuils du test matériel M0 (X3D ≥ 95 %, hybride ≥ 80 %, rendu ≥ 95 %, cyclictest ≤ référence) à confirmer sur la vraie machine | À VÉRIFIER ([[M0 Noyau scx_rago]]) |
| C-states par défaut de M1 : `deep` (choix de Claude) ou `shallow` (latency-performance) ? À trancher avec `m1_frametime_compare.sh` sur la vraie machine | À DÉCIDER ([[M1 Tuning hôte]]) |
| Base Rago (Arch) : tuned ≥ 2.23 (profils dans `/etc/tuned/profiles`), paquets `tuned`, `irqbalance`, `zram-generator` présents ? Testé seulement sur Ubuntu 24.04 (tuned 2.21) en VM | À VÉRIFIER ([[M1 Tuning hôte]]) |
| Gouverneur `performance` réellement appliqué par tuned avec amd-pstate / intel_pstate actif (pas de cpufreq en VM) | À VÉRIFIER ([[M1 Tuning hôte]]) |
| Processeur de la machine de test (X3D, Intel hybride ou symétrique) : décide quel routage M0 peut être vérifié | À VÉRIFIER ([[Prérequis matériel]]) |
| Valeurs des 5 profils communautaires (THP always pour Cyberpunk, C-states shallow pour CS2, perf pour Fortnite…) : à mesurer (1 % low) avant `verified = true` | À VÉRIFIER ([[M14 Profils par jeu]]) |
| gamemode (M2) change aussi le gouverneur au lancement : choix de Claude (13/11) = gamemode n'y touche plus (règle polkit + `gamemode.ini`), rago-profiled reste seul maître ; à valider | À DÉCIDER ([[M2 Couche Proton]], [[M14 Profils par jeu]]) |
| Épingler Proton-GE et Heroic (`host/proton/sources.lock` est en `PENDING`, `host/setup_proton_layer.sh lock`) — impossible depuis l'environnement de Claude (GitHub bloqué) | À VÉRIFIER ([[M2 Couche Proton]]) |
| Formats réels de Steam (`localconfig.vdf`, `config.vdf`, `libraryfolders.vdf`), d'Heroic (`config.json`, enveloppes) et de Lutris : écrits d'après la doc et des exemples, jamais testés sur un vrai Steam connecté | À VÉRIFIER ([[M2 Couche Proton]]) |
| Pré-chauffage : `fossilize-replay` de Steam (`ubuntu12_64/`) utilisable hors Steam ? Arch fournit le paquet `fossilize` ; Ubuntu ne l'empaquette pas. Gain réel sur les saccades à mesurer | À VÉRIFIER ([[M2 Couche Proton]]) |
| Session gamescope : variables `STEAM_GAMESCOPE_*` (menus VRR / HDR / tearing de Steam) et option `-steamos3` à confirmer avec un vrai Steam ; `--rt` avec `cap_sys_nice` casse-t-il l'overlay en mode imbriqué (`--nested`) ? | À VÉRIFIER ([[M2 Couche Proton]]) |
| Base Rago (Arch) : `steam`, `gamescope`, `gamemode`, `mangohud`, `fossilize` et le hook pacman de `cap_sys_nice` — testé seulement sur Ubuntu 25.10 (chroot) | À VÉRIFIER ([[M2 Couche Proton]]) |
| gamemode 1.8 saute la priorité d'E/S quand le noyau rapporte la classe « none » (vu en chroot sur le noyau 6.18 : « ioprio was (0) but we expected (4) ») : gamemode n'apporterait alors plus que l'écran de veille bloqué et le signal « GameMode actif ». À regarder sur la vraie machine ; sinon M0 / M14 pourraient régler la priorité d'E/S eux-mêmes | À VÉRIFIER ([[M2 Couche Proton]]) |
| mangoapp (HUD de la session) absent du paquet mangohud d'Ubuntu 25.10 : la session part alors sans HUD (MangoHud par jeu à la place). Présent sur Arch ? | À VÉRIFIER ([[M2 Couche Proton]]) |
| Base communautaire en ligne (partage façon ProtonDB, mise à jour hors ISO) : format, serveur, modération | À DÉCIDER ([[M14 Profils par jeu]]) |
| Droits du service rago-profiled pour les hooks à venir : capacités pour M9 (nvidia-smi / sysfs AMD), `ReadWritePaths=` vers RAGO-COMM pour M6 | À VÉRIFIER ([[M9 GPU]], [[M6 Fast OS Switch]]) |
| Gouverneur appliqué par rago-profiled avec amd-pstate / intel_pstate actif (pas de cpufreq en VM) | À VÉRIFIER ([[M14 Profils par jeu]]) |
