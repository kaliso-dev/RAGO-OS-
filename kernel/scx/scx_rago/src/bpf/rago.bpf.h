/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Rago OS — déclarations des ajouts Rago au fork scx_lavd (scx_rago).
 *
 * Point d'entrée unique pour les fichiers lavd modifiés : chaque appel Rago
 * dans le code lavd est marqué « RAGO: » pour faciliter les rebases sur une
 * nouvelle version de scx_lavd (voir kernel/scx/scx_rago/RAGO_FORK.md).
 */
#ifndef __RAGO_BPF_H
#define __RAGO_BPF_H

#include "rago_intf.h"

struct pick_ctx;

/* Configuration écrite par l'espace utilisateur avant le chargement. */
extern const volatile u32	rago_topo_kind;	/* enum rago_topo_kind */
extern const volatile u8	rago_routing;	/* 0 = boost de criticité seul, sans routage CPU */
extern const volatile u8	rago_bg_steer;	/* pousser le fond vers le masque fond pendant un jeu */

extern struct rago_stats	rago_stats;

/* Masques construits dans rago_init_cpumasks() à partir de rago_{game,bg}_cpus. */
extern struct bpf_cpumask __kptr *rago_game_cpumask;
extern struct bpf_cpumask __kptr *rago_bg_cpumask;

/* ops.init() : alloue et remplit les masques jeu / fond. */
int rago_init_cpumasks(void);

/* ops.init_task() : héritage du tag au fork + classement initial. */
void rago_init_task(struct task_struct *p, task_ctx *taskc, bool fork);

/* ops.exit_task() : décompte et nettoyage des maps pour une tâche morte. */
void rago_exit_task(struct task_struct *p, task_ctx *taskc);

/*
 * Relit (au plus toutes les RAGO_REFRESH_NS) le tag de @p dans les maps et
 * met à jour taskc->rago_class. Renvoie la classe courante.
 */
u8 rago_refresh_task(struct task_struct *p, task_ctx *taskc);

/*
 * Placement Rago, appelé au début de pick_idle_cpu() pour une tâche non
 * épinglée. Renvoie un CPU (>= 0) si Rago décide du placement, sinon -ENOENT
 * et la logique lavd d'origine s'applique.
 */
s32 rago_pick_cpu(struct pick_ctx *ctx, bool *is_idle);

/*
 * Vrai si le CPU courant ne doit PAS voler la tâche en tête de @dsq_id
 * (thread de rendu, ou thread de jeu sur X3D, hors du masque jeu).
 */
/* Résultat de rago_steal(). */
enum rago_steal_result {
	RAGO_STEAL_DEFAULT	= 0,	/* laisser lavd consommer la DSQ */
	RAGO_STEAL_MOVED	= 1,	/* une tâche non confinée a été déplacée */
	RAGO_STEAL_NONE		= 2,	/* que des tâches confinées : ne rien voler */
};

int rago_steal(u64 dsq_id);

/* Bonus de poids de criticité de latence pour la classe Rago de la tâche. */
static __always_inline u64 rago_lat_weight_boost(task_ctx *taskc)
{
	switch (taskc->rago_class) {
	case RAGO_CLASS_RENDER:
		/* Plus fort que tout boost lavd (HIGHEST = 1024) : le launcher SAIT. */
		return 2 * LAVD_LC_WEIGHT_BOOST_HIGHEST;
	case RAGO_CLASS_GAME:
		return LAVD_LC_WEIGHT_BOOST_HIGH;
	default:
		return 0;
	}
}

#endif /* __RAGO_BPF_H */
