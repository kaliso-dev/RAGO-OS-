---
type: carte
tags: [architecture]
maj: 2026-11-12
---
# Loi physique du POST

Retour à [[Architecture]], [[Fast OS Switch]]. **La contrainte à ne jamais oublier.**

Changer d'OS en bare-metal = **reboot** = **POST firmware** (init de la carte mère). **Aucun logiciel ne le supprime.** `kexec` vers Windows est expérimental ET contourne Secure Boot (que l'anti-triche exige) → fermé. La seule façon d'avoir l'instantané serait la virtualisation, incompatible avec l'anti-triche.

**Donc : le switch n'est jamais instantané en chiffres.** On optimise *autour* du POST :
- **Memory Context Restore + DDR Training Runtime Reduction + Ultra Fast Boot** : POST de 45-90 s → ~1-5 s (mesures réelles AM5/DDR5). Voir [[M8 Optimisation switch]].
- Hibernation LZ4/zstd multi-thread → resume ~2-4 s.
- Splash UEFI continu + gel de frame → **zéro écran noir** (fluide à l'œil).

Porte-à-porte réaliste : **~6-13 s**, perçu comme fluide, **pas instantané**. Seule [[Rago Console coreboot]] (firmware ouvert) s'approche du quasi-instantané, et seulement sur matériel certifié.

**Communication** : promettre « sans couture, sans jamais voir Windows », jamais « instantané ».
