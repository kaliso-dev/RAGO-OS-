# Patches du noyau Rago (module M0)

Le noyau Rago = **Linux 6.18 LTS** + **patchset CachyOS** + config Rago.
Aucun patch Rago maison pour l'instant : tout le travail Rago côté
ordonnanceur est en BPF (`kernel/scx/scx_rago/`), chargé via sched_ext,
donc sans toucher au code du noyau.

## Ce qui est appliqué, dans l'ordre

Liste et empreintes : `sources.lock` (une ligne `nom url sha256` par fichier).

| Fichier | Origine | Rôle |
|---|---|---|
| `linux-6.18.44.tar.xz` | kernel.org | Sources du noyau (branche LTS 6.18). |
| `config-cachyos` | dépôt `CachyOS/linux-cachyos`, fichier `linux-cachyos/config` | Config de base (celle du noyau CachyOS), avant localmodconfig et le fragment Rago. |
| `0001-cachyos-base-all.patch` | dépôt `CachyOS/kernel-patches`, `6.18/all/` | Patchset CachyOS (contenu exact : voir le patch). Rago y attend `CONFIG_X86_64_VERSION` (v3 / v4) ; s'il manque, le script compile avec `-march=x86-64-vN` (À VÉRIFIER à l'épinglage). |
| `0002-bore-cachy.patch` | dépôt `CachyOS/kernel-patches`, `6.18/sched/` | BORE (Burst-Oriented Response Enhancer) au-dessus d'EEVDF : le **filet de sécurité** quand scx_rago n'est pas chargé (`CONFIG_SCHED_BORE`). |
| `local/*.patch` | ce dépôt | Patchs Rago éventuels (vide aujourd'hui), appliqués après, par ordre alphabétique. |

## Épinglage (reproductibilité)

Tant qu'une ligne de `sources.lock` porte `PENDING`, `build_rago_kernel.sh fetch`
refuse de construire. Pour épingler (une fois, par un mainteneur) :

```sh
./kernel/build_rago_kernel.sh lock \
    --patches-ref <commit de CachyOS/kernel-patches> \
    --config-ref  <commit de CachyOS/linux-cachyos>
git diff kernel/patches/sources.lock   # relire
git commit -m "Épingle le noyau 6.18.x et le patchset CachyOS"
```

Choisir des commits CachyOS dont le patchset vise **exactement** la version
du tarball (`KERNEL_VERSION`), sinon `prepare` échoue sur un patch qui ne
s'applique pas. Pour monter de version : changer `KERNEL_VERSION` et le nom /
l'URL du tarball, remettre `PENDING`, relancer `lock`.

Après épinglage, tous les builds partent des mêmes octets ; le reste de la
reproductibilité est assuré par le script : `SOURCE_DATE_EPOCH` (date du
commit Rago), `KBUILD_BUILD_USER=rago`, `KBUILD_BUILD_HOST=rago-build`,
`LOCALVERSION=-rago`, pas de version git, `LC_ALL=C`, `TZ=UTC`. Le manifeste
`kernel/out/manifest.txt` donne le sha256 des entrées, de la config finale et
des sorties.

## Signature

- Noyau (`/boot/vmlinuz-linux-rago`) et systemd-boot : signés par `sbsign`
  avec la clé **MOK** de la machine (`/etc/rago/secureboot/`, créée par
  `mok-gen`, inscrite par `mok-enroll` + MokManager au redémarrage).
- Modules du noyau : signés pendant le build par une clé de build
  persistante (`kernel/build/keys/`, hors dépôt), dont le certificat est
  intégré au noyau.
- Modules DKMS (pilote NVIDIA…) : signés avec la clé MOK
  (`/etc/dkms/framework.conf.d/rago.conf`, écrit par `install`).

## Ce qui n'est PAS fait

Aucun patch de dissimulation, de contournement ou de masquage vis-à-vis
d'un anti-triche : hors périmètre de Rago OS.
