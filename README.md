# Rago OS

Système d'exploitation Linux pour joueurs, à **deux couches** :
1. **Jeu natif** via Proton (la majorité des jeux Windows tournent directement).
2. **Fast OS Switch** : bascule bare-metal vers un micro-Windows invisible pour les jeux à anti-triche strict (Valorant, Fortnite, CoD…), sans jamais voir Windows. Pas de VM, pas de masquage.

## Le cerveau du projet
- **`docs/vault/`** — vault Obsidian : la mémoire vivante du projet (architecture, modules, décisions, état). **Tenue à jour en permanence.** Commence par `docs/vault/Projet.md`.
- **`docs/plan/`** — la bible technique (v7) + 4 études (switch, micro-Windows, innovations, marché). Le détail complet.

## Le code (à venir, dans l'ordre de build)
`kernel/` · `host/` · `windows/` · `daemons/` · `rago-ui/` · `installer/` · `profiles/` · `iso/`
