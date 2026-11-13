/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Rago OS — interface partagée BPF <-> espace utilisateur pour scx_rago.
 *
 * scx_rago est un fork de scx_lavd. Ce fichier ajoute le « canal launcher ->
 * ordonnanceur » : le launcher Rago (via rago-sched-hint et le socket de
 * scx_rago) tague l'arbre de processus d'un jeu AVANT son lancement, et le
 * BPF lit ces tags au lieu de deviner la criticité.
 *
 * Toute modification de ces structures doit incrémenter RAGO_ABI_VERSION et
 * être reflétée dans kernel/scx/rago-common/src/proto.rs (encode_hint()).
 */
#ifndef __RAGO_INTF_H
#define __RAGO_INTF_H

enum rago_consts {
	RAGO_ABI_VERSION	= 1,
	RAGO_MAX_TRACKED	= 16384,	/* capacité de rago_tgids et rago_tids */
	RAGO_MAX_COMM_PATTERNS	= 16,		/* motifs de nom de thread de rendu */
	RAGO_COMM_LEN		= 16,		/* = TASK_COMM_LEN */
	RAGO_REFRESH_NS		= 50000000,	/* relecture des tags toutes les 50 ms par tâche */
};

/* Classe d'une tâche, du moins au plus critique. */
enum rago_class {
	RAGO_CLASS_NONE		= 0,	/* tâche ordinaire (fond) */
	RAGO_CLASS_GAME		= 1,	/* tout thread de l'arbre du jeu */
	RAGO_CLASS_RENDER	= 2,	/* thread de rendu / soumission GPU du jeu */
};

/* Drapeaux d'un tag (rago_hint.flags). */
enum rago_hint_flags {
	RAGO_HINT_F_LAUNCHER	= 1 << 0,	/* posé par le launcher (racine de l'arbre) */
	RAGO_HINT_F_INHERITED	= 1 << 1,	/* posé par le BPF au fork d'un processus tagué */
	RAGO_HINT_F_THREAD	= 1 << 2,	/* tag explicite d'un thread (TID) */
};

/* Type de topologie détecté par l'espace utilisateur (rago-common/topology.rs). */
enum rago_topo_kind {
	RAGO_TOPO_SYMMETRIC	= 0,	/* tous les cœurs équivalents : pas de routage */
	RAGO_TOPO_X3D		= 1,	/* Ryzen X3D bi-CCD : jeu sur le CCD à cache 3D */
	RAGO_TOPO_HYBRID	= 2,	/* Intel hybride : jeu sur P-cores, fond sur E-cores */
};

/*
 * Valeur des maps rago_tgids (clé = tgid) et rago_tids (clé = tid).
 * 24 octets, alignement naturel, identique en BPF et en Rust.
 */
struct rago_hint {
	u32	klass;		/* enum rago_class ("class" est réservé en C++/bindgen) */
	u32	flags;		/* enum rago_hint_flags */
	u32	root_tgid;	/* tgid racine tagué par le launcher (pour UNTAG de l'arbre) */
	u32	owner_uid;	/* uid du demandeur, contrôlé par scx_rago (SO_PEERCRED) */
	u64	tagged_ns;	/* bpf_ktime_get_ns() / CLOCK_MONOTONIC au moment du tag */
};

/* Motif de nom de thread de rendu (préfixe de task->comm). Vide = inutilisé. */
struct rago_comm_pat {
	char	pat[RAGO_COMM_LEN];
};

/* Compteurs exposés à l'espace utilisateur (bss). */
struct rago_stats {
	u64	nr_game_tasks;		/* tâches actuellement classées GAME ou RENDER */
	u64	nr_render_tasks;	/* tâches actuellement classées RENDER */
	u64	nr_inherited;		/* processus enfants tagués par héritage (cumul) */
	u64	nr_steal_blocked;	/* vols inter-domaines refusés pour garder un thread de rendu */
	u64	nr_tagged_lookups;	/* relectures de maps ayant trouvé un tag (cumul, diagnostic) */
};

#endif /* __RAGO_INTF_H */
