---
type: carte
tags: [architecture]
maj: 2026-11-12
---
# Fast OS Switch

Retour à [[Architecture]]. Le cœur du produit. Module : [[M6 Fast OS Switch]], optimisation : [[M8 Optimisation switch]].

**But.** Clic sur un jeu anti-triche → Linux hiberne (session préservée, zéro conso) → le [[Micro-Windows]] démarre **bare-metal direct sur le jeu plein écran** → fermeture → retour auto dans la session Rago. **L'utilisateur ne voit jamais Windows ni d'écran noir** (splash Rago continu + gel de la dernière frame).

**Design asymétrique (notre force) :** seul Linux hiberne ; Windows est sans état, `shutdown /r`, n'écrit **rien** dans l'ordre de boot (one-shot auto-consommé via `bootctl set-oneshot` ou `efibootmgr --bootnext`, défaut = Linux). Robuste : un reboot inattendu retombe sur Linux.

**Deux modes** : *Rapide* (session légère → pas d'hibernation, micro-session qui cold-boote ~2 s) et *Session préservée* (hibernation LZ4/zstd).

**Limite honnête** : le POST firmware reste ([[Loi physique du POST]]). Porte-à-porte ~6-13 s, masqué par le splash. Pas d'instantané (sauf [[Rago Console coreboot]]).

Relié à : [[Micro-Windows]], [[M8 Optimisation switch]], [[Sécurité et boot]].
