/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Rago OS — scx_rago : ordonnanceur informé par le launcher.
 *
 * Ajouts Rago au fork de scx_lavd :
 *
 *  1. Canal launcher -> ordonnanceur. Le launcher tague, AVANT le lancement,
 *     le processus du jeu (son PID devient celui du jeu après execve()). Les
 *     tags vivent dans deux maps BPF écrites par l'espace utilisateur de
 *     scx_rago (qui reçoit les demandes de rago-sched-hint sur un socket) :
 *       - rago_tgids : tgid -> rago_hint  (processus entiers, classe GAME)
 *       - rago_tids  : tid  -> rago_hint  (threads explicites, ex. rendu)
 *     plus rago_comms, des préfixes de nom de thread de rendu connus
 *     (DXVK, vkd3d, Unreal, Unity...) appliqués aux seuls processus tagués.
 *     Les processus enfants d'un processus tagué héritent du tag au fork :
 *     tout l'arbre du jeu est couvert, sans délai.
 *
 *  2. Criticité connue. La classe Rago s'ajoute au poids de criticité de
 *     latence de lavd (lat_cri.bpf.c) : lavd n'a plus à deviner.
 *
 *  3. Routage topologique. L'espace utilisateur détecte la topologie et
 *     fournit deux masques : jeu et fond.
 *       - Ryzen X3D : jeu sur le CCD à cache 3D, fond sur l'autre CCD.
 *       - Intel hybride : jeu sur les P-cores, fond sur les E-cores.
 *     rago_pick_cpu() place les tâches du jeu sur un CPU libre du masque jeu,
 *     et (tant qu'un jeu tourne) les tâches de fond sur le masque fond.
 *     rago_steal() empêche l'équilibreur lavd de voler un thread de
 *     rendu (ou un thread de jeu sur X3D) depuis un CPU hors masque jeu.
 *
 * Filet de sécurité : si scx_rago plante ou bloque une tâche, le watchdog
 * sched_ext l'éjecte et le noyau revient à EEVDF (+ BORE avec le patchset
 * CachyOS). Les tags restent dans l'espace utilisateur et sont réappliqués
 * au redémarrage du service.
 */
#include <scx/common.bpf.h>
#include <bpf_arena_common.bpf.h>
#include "intf.h"
#include "lavd.bpf.h"
#include "util.bpf.h"
#include "rago.bpf.h"
#include <errno.h>
#include <stdbool.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>

/*
 * Configuration (rodata), écrite par main.rs avant le chargement.
 */
const volatile u32	rago_topo_kind = RAGO_TOPO_SYMMETRIC;
const volatile u8	rago_routing = 1;
const volatile u8	rago_bg_steer = 1;
const volatile u64	rago_game_cpus[LAVD_CPU_ID_MAX / 64];
const volatile u64	rago_bg_cpus[LAVD_CPU_ID_MAX / 64];

struct rago_stats	rago_stats;

private(RAGO) struct bpf_cpumask __kptr *rago_game_cpumask;
private(RAGO) struct bpf_cpumask __kptr *rago_bg_cpumask;

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, RAGO_MAX_TRACKED);
	__type(key, u32);
	__type(value, struct rago_hint);
} rago_tgids SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, RAGO_MAX_TRACKED);
	__type(key, u32);
	__type(value, struct rago_hint);
} rago_tids SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, RAGO_MAX_COMM_PATTERNS);
	__type(key, u32);
	__type(value, struct rago_comm_pat);
} rago_comms SEC(".maps");

/*
 * Masques jeu / fond
 */
static int rago_fill_cpumask(struct bpf_cpumask __kptr **slot, bool game)
{
	struct bpf_cpumask *mask, *old;
	u32 cpu;

	mask = bpf_cpumask_create();
	if (!mask)
		return -ENOMEM;

	bpf_for(cpu, 0, nr_cpu_ids) {
		u64 word;

		if (cpu >= LAVD_CPU_ID_MAX)
			break;
		word = game ? rago_game_cpus[cpu / 64] : rago_bg_cpus[cpu / 64];
		if (word & (1ULL << (cpu % 64)))
			bpf_cpumask_set_cpu(cpu, mask);
	}

	old = bpf_kptr_xchg(slot, mask);
	if (old)
		bpf_cpumask_release(old);
	return 0;
}

__hidden int rago_init_cpumasks(void)
{
	int err;

	err = rago_fill_cpumask(&rago_game_cpumask, true);
	if (err)
		return err;
	return rago_fill_cpumask(&rago_bg_cpumask, false);
}

/*
 * Classement
 */

/* Vrai si task->comm commence par l'un des motifs de rago_comms. */
static bool rago_comm_is_render(struct task_struct *p)
{
	char comm[RAGO_COMM_LEN];
	u32 i, j;

	if (bpf_probe_read_kernel_str(comm, sizeof(comm), p->comm) <= 0)
		return false;

	bpf_for(i, 0, RAGO_MAX_COMM_PATTERNS) {
		struct rago_comm_pat *cp;
		bool match = true;
		u32 k = i;

		cp = bpf_map_lookup_elem(&rago_comms, &k);
		if (!cp || cp->pat[0] == '\0')
			continue;

		bpf_for(j, 0, RAGO_COMM_LEN) {
			char c;

			if (j >= RAGO_COMM_LEN)
				break;
			c = cp->pat[j];
			if (c == '\0')
				break;
			if (comm[j] != c) {
				match = false;
				break;
			}
		}
		if (match)
			return true;
	}
	return false;
}

/* Classe d'une tâche d'après les maps (sans cache). */
static u8 rago_classify(struct task_struct *p)
{
	struct rago_hint *h;
	u32 tid = p->pid, tgid = p->tgid;
	u8 cls = RAGO_CLASS_NONE;

	h = bpf_map_lookup_elem(&rago_tids, &tid);
	if (h && h->klass <= RAGO_CLASS_RENDER)
		cls = h->klass;
	if (cls == RAGO_CLASS_RENDER)
		return cls;

	h = bpf_map_lookup_elem(&rago_tgids, &tgid);
	if (!h || h->klass == RAGO_CLASS_NONE)
		return cls;

	/* Un processus tagué est au moins GAME ; ses threads de rendu connus sont RENDER. */
	if (rago_comm_is_render(p))
		return RAGO_CLASS_RENDER;
	return RAGO_CLASS_GAME;
}

/* Met à jour la classe d'une tâche et les compteurs globaux. */
static void rago_set_class(task_ctx *taskc, u8 cls)
{
	u8 old = taskc->rago_counted;

	taskc->rago_class = cls;
	if (old == cls)
		return;

	if (old >= RAGO_CLASS_GAME)
		__sync_fetch_and_sub(&rago_stats.nr_game_tasks, 1);
	if (old == RAGO_CLASS_RENDER)
		__sync_fetch_and_sub(&rago_stats.nr_render_tasks, 1);
	if (cls >= RAGO_CLASS_GAME)
		__sync_fetch_and_add(&rago_stats.nr_game_tasks, 1);
	if (cls == RAGO_CLASS_RENDER)
		__sync_fetch_and_add(&rago_stats.nr_render_tasks, 1);
	taskc->rago_counted = cls;
}

__hidden u8 rago_refresh_task(struct task_struct *p, task_ctx *taskc)
{
	u64 now;
	u8 cls;

	if (!p || !taskc)
		return RAGO_CLASS_NONE;

	now = bpf_ktime_get_ns() | 1;
	if (taskc->rago_refresh_clk &&
	    time_delta(now, taskc->rago_refresh_clk) < RAGO_REFRESH_NS)
		return taskc->rago_class;

	taskc->rago_refresh_clk = now;
	cls = rago_classify(p);
	if (cls >= RAGO_CLASS_GAME)
		__sync_fetch_and_add(&rago_stats.nr_tagged_lookups, 1);
	rago_set_class(taskc, cls);
	return cls;
}

__hidden void rago_init_task(struct task_struct *p, task_ctx *taskc, bool fork)
{
	struct rago_hint *ph, nh;
	u32 tgid, ptgid;

	if (!p || !taskc)
		return;

	/*
	 * Le contexte a pu être copié depuis le parent par lavd_init_task() :
	 * repartir d'un état non compté et forcer la relecture des maps.
	 */
	taskc->rago_class = RAGO_CLASS_NONE;
	taskc->rago_counted = RAGO_CLASS_NONE;
	taskc->rago_refresh_clk = 0;

	/*
	 * Héritage : un nouveau processus (leader de son groupe) créé par un
	 * processus tagué est tagué à son tour, avant sa première exécution.
	 *
	 * ops.init_task() est appelé depuis sched_cgroup_fork(), AVANT que
	 * copy_process() ne pose p->real_parent (qui vaut encore celui du
	 * parent, donc le grand-parent). Au fork, le créateur est la tâche
	 * courante : c'est son tgid qu'on cherche.
	 */
	tgid = p->tgid;
	if (fork && p->pid == tgid) {
		ptgid = bpf_get_current_pid_tgid() >> 32;
		ph = bpf_map_lookup_elem(&rago_tgids, &ptgid);
		if (ph && ph->klass != RAGO_CLASS_NONE) {
			nh.klass = RAGO_CLASS_GAME;
			nh.flags = (ph->flags & ~RAGO_HINT_F_LAUNCHER) |
				   RAGO_HINT_F_INHERITED;
			nh.root_tgid = ph->root_tgid;
			nh.owner_uid = ph->owner_uid;
			nh.tagged_ns = bpf_ktime_get_ns();
			if (!bpf_map_update_elem(&rago_tgids, &tgid, &nh, BPF_NOEXIST))
				__sync_fetch_and_add(&rago_stats.nr_inherited, 1);
		}
	}

	rago_refresh_task(p, taskc);
}

__hidden void rago_exit_task(struct task_struct *p, task_ctx *taskc)
{
	u32 tid, tgid;

	if (!p)
		return;

	if (taskc)
		rago_set_class(taskc, RAGO_CLASS_NONE);

	/*
	 * exit_task() est aussi appelé pour toutes les tâches quand
	 * l'ordonnanceur se décharge : ne nettoyer les maps que pour une
	 * tâche qui meurt vraiment.
	 */
	if (!(p->flags & PF_EXITING))
		return;

	tid = p->pid;
	tgid = p->tgid;
	bpf_map_delete_elem(&rago_tids, &tid);
	if (tid == tgid)
		bpf_map_delete_elem(&rago_tgids, &tgid);
}

/*
 * Placement
 */

/* CPU libre dans @mask : le CPU précédent s'il est libre, puis un cœur
 * entièrement libre, puis n'importe quel CPU libre. */
static s32 rago_pick_idle_in(const struct cpumask *mask, s32 prev_cpu,
			     bool *is_idle)
{
	s32 cpu;

	if (prev_cpu >= 0 && bpf_cpumask_test_cpu(prev_cpu, mask) &&
	    scx_bpf_test_and_clear_cpu_idle(prev_cpu)) {
		*is_idle = true;
		return prev_cpu;
	}

	cpu = scx_bpf_pick_idle_cpu(mask, SCX_PICK_IDLE_CORE);
	if (cpu < 0)
		cpu = scx_bpf_pick_idle_cpu(mask, 0);
	if (cpu >= 0)
		*is_idle = true;
	return cpu;
}

__hidden s32 rago_pick_cpu(struct pick_ctx *ctx, bool *is_idle)
{
	const struct task_struct *p;
	struct bpf_cpumask *tmp, *game, *bg;
	task_ctx *taskc;
	s32 cpu;
	u8 cls;

	if (!rago_routing || rago_topo_kind == RAGO_TOPO_SYMMETRIC)
		return -ENOENT;
	if (!ctx || !ctx->cpuc_cur || !ctx->taskc)
		return -ENOENT;

	p = ctx->p;
	taskc = ctx->taskc;
	tmp = ctx->cpuc_cur->temp_mask;
	if (!p || !tmp)
		return -ENOENT;

	cls = taskc->rago_class;
	if (cls >= RAGO_CLASS_GAME) {
		game = rago_game_cpumask;
		if (!game)
			return -ENOENT;

		/* Respecter l'affinité imposée par l'utilisateur. */
		bpf_cpumask_and(tmp, cast_mask(game), p->cpus_ptr);
		if (bpf_cpumask_empty(cast_mask(tmp)))
			return -ENOENT;

		cpu = rago_pick_idle_in(cast_mask(tmp), ctx->prev_cpu, is_idle);
		if (cpu >= 0)
			return cpu;

		/*
		 * Aucun CPU jeu libre. Le thread de rendu attend toujours un
		 * cœur du masque jeu (la préemption lavd lui en libère un). Sur
		 * X3D, tout le jeu reste sur le CCD à cache 3D : la localité du
		 * cache vaut plus qu'un cœur libre de l'autre CCD. Sur Intel
		 * hybride, les autres threads du jeu peuvent déborder sur les
		 * E-cores (logique lavd d'origine).
		 */
		if (cls == RAGO_CLASS_RENDER || rago_topo_kind == RAGO_TOPO_X3D) {
			if (ctx->prev_cpu >= 0 &&
			    bpf_cpumask_test_cpu(ctx->prev_cpu, cast_mask(tmp)))
				return ctx->prev_cpu;
			cpu = bpf_cpumask_any_distribute(cast_mask(tmp));
			if (cpu < nr_cpu_ids)
				return cpu;
		}
		return -ENOENT;
	}

	/*
	 * Tâche de fond pendant qu'un jeu tourne : préférer le masque fond
	 * s'il y a un CPU libre, sans jamais forcer (sinon logique lavd).
	 * Les threads noyau sont laissés à lavd.
	 */
	if (!rago_bg_steer || !READ_ONCE(rago_stats.nr_game_tasks))
		return -ENOENT;
	if (p->flags & PF_KTHREAD)
		return -ENOENT;
	bg = rago_bg_cpumask;
	if (!bg)
		return -ENOENT;

	bpf_cpumask_and(tmp, cast_mask(bg), p->cpus_ptr);
	if (bpf_cpumask_empty(cast_mask(tmp)))
		return -ENOENT;
	return rago_pick_idle_in(cast_mask(tmp), ctx->prev_cpu, is_idle);
}

/*
 * Vrai si le thread doit rester dans le masque jeu : rendu toujours,
 * tout thread de jeu sur X3D.
 */
static bool rago_confined_class(u8 klass)
{
	return klass == RAGO_CLASS_RENDER ||
	       (klass == RAGO_CLASS_GAME && rago_topo_kind == RAGO_TOPO_X3D);
}

/*
 * Vol de tâche par l'équilibreur lavd (try_to_steal_task / force_to_steal_task).
 *
 * Hors jeu, ou sur un CPU du masque jeu : RAGO_STEAL_DEFAULT, lavd fait son
 * scx_bpf_dsq_move_to_local() habituel. Sur un CPU hors masque pendant un
 * jeu, on parcourt la DSQ et on déplace la première tâche non confinée :
 * contrairement à « regarder la tête puis déplacer la tête », aucune course
 * ne peut faire partir un thread de rendu qui serait passé en tête entre-temps.
 *
 * __weak : fonction globale, vérifiée une seule fois par le vérifieur BPF
 * (une fonction « static » serait revérifiée à chaque appel dans les boucles
 * de l'équilibreur, ce qui dépasse la limite de complexité : -E2BIG).
 */
__weak int rago_steal(u64 dsq_id)
{
	struct bpf_cpumask *game;
	struct task_struct *p, *ref;
	task_ctx *taskc;
	bool confined;
	s32 cpu;

	if (!rago_routing || rago_topo_kind == RAGO_TOPO_SYMMETRIC)
		return RAGO_STEAL_DEFAULT;
	if (!READ_ONCE(rago_stats.nr_game_tasks))
		return RAGO_STEAL_DEFAULT;

	game = rago_game_cpumask;
	if (!game)
		return RAGO_STEAL_DEFAULT;

	cpu = bpf_get_smp_processor_id();
	if (bpf_cpumask_test_cpu(cpu, cast_mask(game)))
		return RAGO_STEAL_DEFAULT;

	bpf_for_each(scx_dsq, p, dsq_id, 0) {
		/* Même contournement que lavd : pointeur de confiance via le PID. */
		ref = bpf_task_from_pid(p->pid);
		if (!ref)
			continue;
		taskc = find_task_ctx(ref);
		confined = taskc && rago_confined_class(taskc->rago_class);
		bpf_task_release(ref);

		if (confined) {
			__sync_fetch_and_add(&rago_stats.nr_steal_blocked, 1);
			continue;
		}
		if (scx_bpf_dsq_move(BPF_FOR_EACH_ITER, p, SCX_DSQ_LOCAL, 0))
			return RAGO_STEAL_MOVED;
	}
	return RAGO_STEAL_NONE;
}
