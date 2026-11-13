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
