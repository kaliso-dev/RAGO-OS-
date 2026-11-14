---
type: carte
tags: [architecture]
maj: 2026-11-14
---
# Fast OS Switch

Retour à [[Architecture]]. Le cœur du produit. Module : [[M6 Fast OS Switch]], optimisation : [[M8 Optimisation switch]].

**But.** Clic sur un jeu anti-triche → Linux hiberne (session préservée, zéro conso) → le [[Micro-Windows]] démarre **bare-metal direct sur le jeu plein écran** → fermeture → retour auto dans la session Rago. **L'utilisateur ne voit jamais Windows ni d'écran noir** (splash Rago continu + gel de la dernière frame).

**Design asymétrique (notre force) :** seul Linux hiberne ; Windows est sans état, `shutdown /r`, n'écrit **rien** dans l'ordre de boot (one-shot auto-consommé via `bootctl set-oneshot` ou `efibootmgr --bootnext`, défaut = Linux). Robuste : un reboot inattendu retombe sur Linux.

**Avec [[M5 Micro-Windows]] (14/11)** : Windows n'écrit dans les variables de démarrage que pour un **changement de profil de sécurité** (un BootNext vers lui-même, à usage unique, pour redémarrer une fois avec le bon hyperviseur) ; un redémarrage ou un écran bleu de Windows retombe sur Linux. L'hibernation de Windows est **coupée par défaut** (décision du 14/11) : le micro-Windows ne s'hiberne jamais lui-même, l'hibernation du switch est celle de Linux ; reprendre Windows depuis l'hibernation est un arbitrage disque / vitesse à étudier en [[M8 Optimisation switch]]. Pas de mise à jour en ligne dans Windows (décision du 14/11) : pas d'écran « mise à jour en cours » pendant une bascule.

**Deux modes** : *Rapide* (session légère → pas d'hibernation, micro-session qui cold-boote ~2 s) et *Session préservée* (hibernation LZ4/zstd).

**Limite honnête** : le POST firmware reste ([[Loi physique du POST]]). Porte-à-porte ~6-13 s, masqué par le splash. Pas d'instantané (sauf [[Rago Console coreboot]]).

Relié à : [[Micro-Windows]], [[M8 Optimisation switch]], [[Sécurité et boot]].
