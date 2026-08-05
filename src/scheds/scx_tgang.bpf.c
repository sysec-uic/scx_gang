/* SPDX-License-Identifier: GPL-2.0 */
/*
 * scx_tgang: temporal-multiplexing gang scheduler for litmus testing.
 *
 * scx_gang (spatial) reserves a dedicated CPU per gang member; it works while
 * gangs fit on the machine but degrades under oversubscription (more gang
 * threads than CPUs). scx_tgang adds TEMPORAL multiplexing: gangs are scheduled
 * as atomic units that take turns.
 *
 * Mechanism. All runnable gang members sit in one FIFO (GANG_DSQ). When a CPU
 * runs out of work it tries to "activate" the gang at the front: under a global
 * try-lock it places ALL of that gang's queued members onto distinct idle CPUs
 * simultaneously (preempting background work), but ONLY if enough CPUs are idle
 * -- otherwise the gang stays queued and the CPU serves background work. When a
 * gang's slice expires its members re-enqueue at the tail, so gangs rotate
 * round-robin. This packs as many gangs as fit and time-slices the remainder,
 * with every gang always co-scheduled. SCHED_FIFO / taskset cannot express it.
 *
 * Based on scx_simple / scx_group / scx_gang.
 */
#include <scx/common.bpf.h>

char _license[] SEC("license") = "GPL";

#define SHARED_DSQ	0
#define GANG_DSQ	1
#define GANG_SLICE	(20ULL * 1000 * 1000)	/* 20ms per gang turn */

const volatile bool fifo_sched;

static u64 vtime_now;
UEI_DEFINE(uei);

/* stats: [0]=background [1]=gang activations [2]=members placed [3]=oversub waits
 * [4]=partial activations (a pass that placed >=1 member but ran out of idle
 * CPUs before the whole queued front-gang fit). */
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(key_size, sizeof(u32));
	__uint(value_size, sizeof(u64));
	__uint(max_entries, 5);
} stats SEC(".maps");

/* Userspace opt-in: tgid -> (tid -> group_id). */
struct group_value {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, u32);
	__type(value, u32);
	__uint(max_entries, 64);
} __gv SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH_OF_MAPS);
	__type(key, u32);
	__uint(max_entries, 64);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
	__array(values, struct group_value);
} groups SEC(".maps");

/* Single-slot try-lock serializing gang activation. */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__type(key, u32);
	__type(value, u32);
	__uint(max_entries, 1);
} actlock SEC(".maps");

static __always_inline void stat_inc(u32 idx)
{
	u64 *p = bpf_map_lookup_elem(&stats, &idx);
	if (p)
		(*p)++;
}

static __always_inline u64 gang_key_of(struct task_struct *p)
{
	u32 tgid = p->tgid, tid = p->pid;
	void *gm = bpf_map_lookup_elem(&groups, &tgid);
	if (!gm)
		return 0;
	u32 *gid = bpf_map_lookup_elem(gm, &tid);
	if (!gid)
		return 0;
	return ((u64)tgid << 32) | (u64)*gid;
}

s32 BPF_STRUCT_OPS(tgang_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
{
	if (gang_key_of(p))
		return prev_cpu;	/* placement decided at activation time */

	bool is_idle = false;
	s32 cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);
	if (is_idle)
		scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL, SCX_SLICE_DFL, 0);
	return cpu;
}

void BPF_STRUCT_OPS(tgang_enqueue, struct task_struct *p, u64 enq_flags)
{
	if (gang_key_of(p)) {
		/* All gang members queue here; activation pulls whole gangs out. */
		scx_bpf_dsq_insert(p, GANG_DSQ, GANG_SLICE, enq_flags);
		return;
	}

	stat_inc(0);
	if (fifo_sched) {
		scx_bpf_dsq_insert(p, SHARED_DSQ, SCX_SLICE_DFL, enq_flags);
	} else {
		u64 vtime = p->scx.dsq_vtime;
		if (time_before(vtime, vtime_now - SCX_SLICE_DFL))
			vtime = vtime_now - SCX_SLICE_DFL;
		scx_bpf_dsq_insert_vtime(p, SHARED_DSQ, SCX_SLICE_DFL, vtime, enq_flags);
	}
}

void BPF_STRUCT_OPS(tgang_dispatch, s32 cpu, struct task_struct *prev)
{
	u32 ucpu = (u32)cpu;

	if (scx_bpf_dsq_nr_queued(GANG_DSQ) == 0) {
		scx_bpf_dsq_move_to_local(SHARED_DSQ);
		return;
	}

	u32 zero = 0;
	u32 *lock = bpf_map_lookup_elem(&actlock, &zero);
	if (!lock || __sync_val_compare_and_swap(lock, 0, 1) != 0) {
		scx_bpf_dsq_move_to_local(SHARED_DSQ);
		return;
	}

	/*
	 * Single greedy pass: the first gang member seen fixes the gang G to
	 * activate; place each of G's queued members on a distinct idle CPU and
	 * preempt onto it, so the whole gang lands together. Members that don't
	 * fit (no idle CPU) stay queued and are picked up next round. One pass +
	 * one gang lookup per task keeps the verifier state space bounded.
	 */
	const struct cpumask *online = scx_bpf_get_online_cpumask();
	struct bpf_iter_scx_dsq it;
	u64 G = 0;
	bool activated = false;
	bool broke = false;

	if (!bpf_iter_scx_dsq_new(&it, GANG_DSQ, 0)) {
		struct task_struct *p;
		while ((p = bpf_iter_scx_dsq_next(&it))) {
			u64 k = gang_key_of(p);
			if (!k)
				continue;
			if (G == 0)
				G = k;
			if (k != G)
				continue;

			s32 tgt = scx_bpf_pick_idle_cpu(online, 0);
			if (tgt < 0) {
				broke = true;	/* no idle CPU; rest of gang waits */
				break;
			}

			scx_bpf_dsq_move_set_slice(&it, GANG_SLICE);
			scx_bpf_dsq_move(&it, p, SCX_DSQ_LOCAL_ON | (u32)tgt,
					 SCX_ENQ_PREEMPT);
			if ((u32)tgt != ucpu)
				scx_bpf_kick_cpu(tgt, SCX_KICK_PREEMPT);
			activated = true;
			stat_inc(2);
		}
	}
	bpf_iter_scx_dsq_destroy(&it);
	scx_bpf_put_cpumask(online);
	if (activated) {
		stat_inc(1);
		if (broke)
			stat_inc(4);	/* placed some but not the whole gang */
	} else {
		stat_inc(3);
	}
	__sync_val_compare_and_swap(lock, 1, 0);

	/* Keep this CPU busy with background work. */
	scx_bpf_dsq_move_to_local(SHARED_DSQ);
}

void BPF_STRUCT_OPS(tgang_running, struct task_struct *p)
{
	if (fifo_sched)
		return;
	if (time_before(vtime_now, p->scx.dsq_vtime))
		vtime_now = p->scx.dsq_vtime;
}

void BPF_STRUCT_OPS(tgang_stopping, struct task_struct *p, bool runnable)
{
	if (fifo_sched)
		return;
	p->scx.dsq_vtime += (SCX_SLICE_DFL - p->scx.slice) * 100 / p->scx.weight;
}

void BPF_STRUCT_OPS(tgang_enable, struct task_struct *p)
{
	p->scx.dsq_vtime = vtime_now;
}

s32 BPF_STRUCT_OPS_SLEEPABLE(tgang_init)
{
	int err = scx_bpf_create_dsq(SHARED_DSQ, -1);
	if (err)
		return err;
	return scx_bpf_create_dsq(GANG_DSQ, -1);
}

void BPF_STRUCT_OPS(tgang_exit, struct scx_exit_info *ei)
{
	UEI_RECORD(uei, ei);
}

SCX_OPS_DEFINE(tgang_ops,
	       .select_cpu	= (void *)tgang_select_cpu,
	       .enqueue		= (void *)tgang_enqueue,
	       .dispatch	= (void *)tgang_dispatch,
	       .running		= (void *)tgang_running,
	       .stopping	= (void *)tgang_stopping,
	       .enable		= (void *)tgang_enable,
	       .init		= (void *)tgang_init,
	       .exit		= (void *)tgang_exit,
	       .name		= "tgang");
