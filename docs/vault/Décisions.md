---
type: règle
tags: [décisions]
maj: 2026-11-13
---
# Décisions

Chaque décision de Sofiene, datée. Retour à [[Projet]]. La plus récente prime.

## Architecture
- **12/11 — Deux couches, pas de VM.** La couche VM est abandonnée : les jeux qui tolèrent une VM tournent déjà sur Proton, ceux qui la refusent refusent aussi la VM. Le Fast OS Switch (bare-metal) remplace la VM pour l'anti-triche. Voir [[Fast OS Switch]].
- **12/11 — Aucune dissimulation / aucun masquage d'hyperviseur.** Hors périmètre, non développé. Tout est bare-metal légitime.
- **12/11 — BYOL (Bring Your Own License).** Rago ne distribue pas Windows ; l'utilisateur fournit son ISO + sa licence. Voir [[Micro-Windows]].

## Méthode
- **13/11 — Avancer sans machine de test.** « M0 (noyau + scx_rago) est codé […] mais JAMAIS testé sur vrai matériel (pas de machine de test pour l'instant). On avance donc sur les modules qui se testent sans matériel dédié, en commençant par M1. M0 reste « jamais testé sur matériel » dans le vault. » Puis M1, « et lui seul (M2 attend mon feu vert) ». Remplace, en attendant la machine, la règle « testé sur vrai matériel avant le suivant » ([[Règles de travail]]).

- **13/11 — M14 ensuite, et lui seul.** « Prochain module : M14. […] développe le Module M14, et lui seul » ; « les horloges GPU (M9) et le profil de sécurité Windows (M5) ne sont pas encore codés → câble-les comme des hooks/stubs clairs, à activer quand M9/M5 existeront » ; « Cohérent avec M1 (M1 = réglage de base, M14 = surcharge par jeu) ». Voir [[M14 Profils par jeu]].

- **13/11 — M2 ensuite, et lui seul.** « Prochain module : M2 » ; « développe le Module M2, et lui seul » ; « Hook de lancement : au démarrage d'un jeu, applique son profil via rago-profiled (M14) et appelle le hint scheduler via rago-sched-hint (M0). Cohérent avec M1 (base) et M14 (surcharge par jeu) » ; « Teste ce qui est testable sans matériel […] ; marque clairement les parties affichage/VRR/HDR/FPS comme « en attente de matériel » ». Voir [[M2 Couche Proton]].

- **13/11 — M3 ensuite, et lui seul.** « Développe le Module M3, et lui seul » ; « Détecte AES-NI/AVX2 (avertit sinon) ; luksFormat luks2 aes-xts-plain64 key-size 512 sha512 argon2id ; enrôle le TPM via systemd-cryptenroll --tpm2-pcrs=0+7 ET une passphrase de secours obligatoire ; met à jour /etc/crypttab (tpm2-device=auto) et l'initramfs (détecte dracut/mkinitcpio) » ; « Compatible avec le swap d'hibernation chiffré du switch (M6, déverrouillé avant resume) et les deux slots A/B (M4) » ; « Avertit du risque PCR7 après update firmware (d'où la passphrase de secours) ». Sécurité : « Teste UNIQUEMENT sur des disques virtuels (loop devices / VM avec swtpm pour émuler le TPM). JAMAIS sur un vrai disque. La passphrase de secours est OBLIGATOIRE (ne jamais laisser le TPM comme seul moyen de déverrouillage). » ; « Marque le vrai auto-unlock TPM matériel comme « en attente de matériel » ». Voir [[M3 Chiffrement LUKS]].

## Choix techniques de Claude (M0, 12/11) — à valider par Sofiene
Ce ne sont pas des décisions de Sofiene : choix d'implémentation faits pendant M0, modifiables.
- **Noyau 6.18 LTS** comme base (≥ 6.12 demandé ; LTS = correctifs longtemps). Version exacte épinglée dans `kernel/patches/sources.lock`.
- **Canal launcher → ordonnanceur = socket Unix** servi par scx_rago (root:rago, 0660), pas un binaire `setcap` : un binaire à capacités casserait `LD_PRELOAD` (MangoHud, Steam Runtime) dans le jeu.
- **X3D : affinité dure + routage BPF** (le jeu reste sur le CCD à cache même si scx_rago tombe). **Hybride : préférence douce** (le jeu peut déborder sur les E-cores si les P-cores sont pleins), rendu toujours sur P-cores.
- **Lockdown non imposé** : le mode integrity interdit l'hibernation du [[Fast OS Switch]].
- **Clang ≥ 20 pour le BPF** de scx_rago (Clang 18 produit un code refusé par le vérifieur).
- **Modules du noyau signés par une clé de build** (hors dépôt) intégrée au noyau ; la **clé MOK** signe noyau, systemd-boot et modules DKMS. Le build reste non privilégié.
- **Groupe `rago`** : seul un membre peut taguer ses jeux (le joueur y est ajouté par `scx-install --user`).

## Choix techniques de Claude (M1, 13/11) — à valider par Sofiene
- **C-states : `deep` par défaut** (aucune limite) ; `shallow` (= latency-performance, C1 max) et `poll` en option (`--cstates`). Raison : sur portable et sur X3D, bloquer les C-states profonds chauffe et peut baisser le boost des cœurs actifs. À trancher par la mesure 1 % low ([[M1 Tuning hôte]]).
- **swappiness = 10 gardé** (demandé) malgré zram : zram reste un dernier recours.
- **zram = moitié de la RAM, 8 Gio max, zstd, priorité 100** ; **zswap coupé** quand zram est actif (pas de double compression).
- **HDD → bfq**, SSD SATA / eMMC → mq-deadline, NVMe → none (`--nvme-scheduler mq-deadline` possible).
- **threadirqs passe par `RAGO_CMDLINE_EXTRA` de `/etc/rago/kernel.conf`** (mécanisme de M0, code de M0 inchangé) plutôt que par le plugin bootloader de tuned (pensé pour GRUB, pas systemd-boot).
- **IRQ : irqbalance réparti sur tous les CPU par défaut** ; `--irq-ban` optionnel. Pas d'isolation.
- **power-profiles-daemon arrêté** à l'installation (il change le gouverneur derrière tuned), remis à la désinstallation ; `--keep-ppd` pour le garder.
- **`vm.max_map_count = 2147483642`** (valeur SteamOS).

## Choix techniques de Claude (M14, 13/11) — à valider par Sofiene
- **Démon root + socket** `/run/rago-profiled/profiled.sock` (root:rago 0660, même groupe que M0) plutôt qu'un outil à droits : le launcher (joueur) ne fait que **nommer** le jeu, les profils viennent de dossiers root.
- **Session = connexion** : le profil tient tant que le launcher est vivant ; s'il meurt, la base revient. Plusieurs jeux : le dernier lancé gagne.
- **Champ absent = base M1** ; seul ce que M14 a changé est remis à la fin ; photo de la base dans `/run` (reprise après arrêt brutal, vidée au reboot).
- **C-states par PM QoS** (`/dev/cpu_dma_latency`, comme tuned) : un profil ne peut qu'**ajouter** une limite à M1, jamais la relâcher. Champ `cstates` ajouté au profil, même vocabulaire que M1.
- **Mitigations jamais changées par M14** : réglage global du noyau et choix de sécurité du joueur ; le démon compare et signale.
- **Profil sûr par défaut intégré au code** (pas un fichier) : rien ne change côté Linux, hint M0 normal, `compat_max` côté switch.
- **Hooks** `/usr/lib/rago/hooks/gpu-clocks` (M9) et `windows-security` (M5/M6) : exécutables root, environnement vidé, 15 s max ; absent = « en attente ».
- **Base communautaire = fichiers du dépôt** (`profiles/community/`, installés dans `/usr/share/rago/profiles/`), surchargés par `/etc/rago/profiles/`. Pas de synchronisation en ligne pour l'instant. Formats TOML **et** JSON acceptés.
- **Jeu de couche switch lancé par `launch`** : avertissement, aucun réglage Linux, le jeu est lancé quand même.

## Choix techniques de Claude (M2, 13/11) — à valider par Sofiene
- **Hook = `rago-launch %command%`** (et non `rago-profiled launch` directement) : il ajoute caches de shaders, gamemode, MangoHud et runtimes EAC/BattlEye hors Steam, puis passe par `rago-profiled launch` (M14) qui passe par `rago-sched-hint run` (M0). Chaque maillon absent est sauté, le jeu se lance toujours.
- **Steam n'a pas d'option de lancement globale** : `rago-steam-config` écrit le hook dans chaque jeu installé, **seulement Steam fermé** (il réécrit sa config en quittant), en gardant l'option du joueur ; un jeu dont le joueur retire le hook n'est plus touché. La session Rago le refait avant chaque démarrage de Steam.
- **gamemode réduit** : pas de gouverneur (M14/M1), pas d'épinglage / parking des cœurs (M0), pas de renice ni temps réel (M0), pas de split lock (M1), pas de GPU (M9). Règle polkit `40-rago-gamemode.rules` qui refuse ses 4 assistants (passe avant `gamemode.rules` du paquet ; prouvé avec un vrai polkitd). Réponse de Claude à la question « gamemode change aussi le gouverneur ».
- **Proton-GE installé pour tout le système** (`/usr/share/steam/compatibilitytools.d/`), épinglé par empreinte, mis par défaut **seulement si le joueur n'a rien choisi** ; `--default-proton keep` pour ne rien toucher.
- **Cache de shaders par GPU** (`<pilote>-<vendor>-<device>`) **et par jeu**, sous `~/.local/share/rago/shader-cache` ; seules les variables que Steam / Proton n'ont pas posées sont ajoutées (le cache de Steam reste maître pour ses jeux).
- **Pré-chauffage** : `fossilize-replay` en priorité basse, en fond (`background`, défaut), pause pendant les jeux, tampon par base, tout refait si le pilote Vulkan change ; `before` (avant le jeu) et `off` en option.
- **HUD** : dans la session gamescope, mangoapp (réglable depuis Steam) ; hors session, MangoHud par jeu ; jamais les deux. `/etc/MangoHud.conf` compact (FPS, 1 % low, temps d'image), Shift droit + F12 pour cacher.
- **Session** : VRR, HDR, tearing en jeu, `--rt` activés par défaut (gamescope reçoit `cap_sys_nice`), mode natif de l'écran ; tout se coupe dans `/etc/rago/proton-layer.conf`.

## Choix techniques de Claude (M3, 13/11) — à valider par Sofiene
- **Trois volumes LUKS2** : `rago-a` et `rago-b` (racine de chaque slot de [[M4 Updates A-B]]) et `rago-swap` (swap d'hibernation). La racine s'ouvre **toujours sous le nom `rago-root`** : chaque slot a sa crypttab (et donc son initramfs) qui nomme son propre volume, et la ligne de commande du noyau est la même pour les deux slots (`root=/dev/mapper/rago-root resume=/dev/mapper/rago-swap`). Conséquence pour M4 : une initramfs par slot.
- **Dans l'initramfs, seulement les volumes du démarrage** (racine + swap) : `/etc/crypttab.initramfs`, lue telle quelle par le hook sd-encrypt de mkinitcpio, mise dans l'image dracut par le module `91rago-crypttab`. Les autres volumes du joueur s'ouvrent après, depuis `/etc/crypttab`.
- **dracut ou mkinitcpio seulement** : initramfs-tools (Debian / Ubuntu par défaut) est refusé, il ne sait pas déverrouiller par TPM2 ; `deps` installe dracut.
- **PCR jamais mesurés refusés** (tout à zéro : le TPM ne protégerait rien) ; `--allow-zero-pcrs` pour forcer. PCR enregistrés à l'enrôlement pour dire ensuite lequel a changé.
- **Passphrase de secours : 12 caractères au moins**, jamais dans les arguments (fichier en mode 600 ou saisie au terminal), vérifiée avant et après chaque enrôlement ; un volume sans passphrase est refusé, et `verify` affiche « DANGER » si elle a disparu. Pas de PIN TPM : la machine intègre démarre sans rien taper.
- **Un seul enrôlement TPM par volume** : chaque `enroll-tpm` / `reseal` remplace l'ancien (`--wipe-slot=tpm2`).
- **Options des volumes** : `discard` (TRIM du SSD ; révèle seulement quels blocs sont libres), `no-read-workqueue,no-write-workqueue` (latence plus basse sur NVMe), aussi gardées dans l'en-tête LUKS.
- **Ligne de commande par `/etc/rago/kernel.conf` de M0** : `root=` dans `RAGO_CMDLINE`, `resume=` dans `RAGO_CMDLINE_EXTRA` (code de M0 inchangé).
- **Swap chiffré en priorité 10**, sous le zram de [[M1 Tuning hôte]] (priorité 100) : zram d'abord, le disque sert à l'hibernation.
- **Contrôle `rago-tpm-check` une minute après le démarrage** (minuterie, ne retarde pas le démarrage) : écrit `/run/rago/encryption-status` pour [[M11 Rago UI]] et le journal ; ne change rien tout seul (le `reseal` reste une commande du joueur).

## Abandonné
- **VM gaming (passthrough/Looking Glass)** — 12/11, remplacé par le Fast OS Switch. Ne pas relancer.
- **Masquage anti-détection d'hyperviseur** — refusé, inutile sans VM. Ne pas relancer.
