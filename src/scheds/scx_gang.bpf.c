/* SPDX-License-Identifier: GPL-2.0 */
/*
 * scx_gang: true multi-group gang scheduler for litmus testing.
 *
 * Each "gang" is identified by (tgid, group_id). Every gang member thread is
 * assigned its own dedicated CPU, claimed exclusively from a global per-CPU
 * ownership table and kept within a single NUMA node. Because each member owns
 * its CPU exclusively:
 *
 *   - all members of a gang run simultaneously on distinct CPUs (intra-gang
 *     simultaneity), and
 *   - different gangs get disjoint CPU sets, so they never interfere with each
 *     other (cross-gang non-interference).
 *
 * Non-gang ("background") tasks are scheduled with a simple global weighted
 * vtime policy and are kept off CPUs owned by gangs. This is strictly more than
 * SCHED_FIFO + taskset can do: CPU reservation is dynamic, automatic, NUMA
 * aware, evicts interlopers, and cleans up when gang threads exit.
 *
 * See DESIGN_gang.md for the full rationale.
 *
 * Based on scx_simple / scx_group.
 * Copyright (c) 2022 Meta Platforms, Inc. and affiliates.
 * Copyright (c) 2022 Tejun Heo <tj@kernel.org>
 * Copyright (c) 2022 David Vernet <dvernet@meta.com>
 */
#include <scx/common.bpf.h>

char _license[] SEC("license") = "GPL";

#define SHARED_DSQ	0
#define MAX_CPUS	512

const volatile bool fifo_sched;

static u64 vtime_now;
UEI_DEFINE(uei);

/* stats: [0]=background queueing, [1]=gang queueing, [2]=oversubscribed */
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(key_size, sizeof(u32));
	__uint(value_size, sizeof(u64));
	__uint(max_entries, 3);
} stats SEC(".maps");

/* Userspace opt-in (unchanged from scx_group): tgid -> (tid -> group_id). */
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

/* Global per-CPU ownership: cpu -> gang_key (0 = free). */
struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__type(key, u32);
	__type(value, u64);
	__uint(max_entries, MAX_CPUS);
} cpu_owner SEC(".maps");

/* Stable per-thread assignment: tid -> {gang_key, cpu}. */
struct member {
	u64 gang_key;
	s32 cpu;
};

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, u32);
	__type(value, struct member);
	__uint(max_entries, 4096);
} members SEC(".maps");

static void stat_inc(u32 idx)
{
	u64 *cnt_p = bpf_map_lookup_elem(&stats, &idx);
	if (cnt_p)
		(*cnt_p)++;
}

/* Resolve a task's gang_key, or 0 if it is not a gang member. */
static u64 gang_key_of(struct task_struct *p)
{
	u32 tgid = p->tgid;
	u32 tid = p->pid;

	void *group_map = bpf_map_lookup_elem(&groups, &tgid);
	if (!group_map)
		return 0;

	u32 *gidp = bpf_map_lookup_elem(group_map, &tid);
	if (!gidp)
		return 0;

	return ((u64)tgid << 32) | (u64)*gidp;
}

/* Try to claim a free CPU on @node for @gang_key; return cpu or -1. */
static s32 claim_cpu_on_node(u64 gang_key, int node, bool any_node)
{
	u32 nr = scx_bpf_nr_cpu_ids();

	for (u32 c = 0; c < MAX_CPUS; c++) {
		if (c >= nr)
			break;
		if (!any_node && scx_bpf_cpu_node(c) != node)
			continue;

		u64 *owner = bpf_map_lookup_elem(&cpu_owner, &c);
		if (!owner)
			continue;

		/* Atomic claim to avoid two gangs grabbing the same CPU. */
		if (__sync_val_compare_and_swap(owner, 0ULL, gang_key) == 0)
			return (s32)c;
	}
	return -1;
}

/*
 * Return the dedicated CPU for gang member @p, assigning one on first sight.
 * Returns -1 if the task is not a gang member or no CPU is available.
 */
static s32 gang_cpu(struct task_struct *p)
{
	u32 tid = p->pid;
	u64 gang_key = gang_key_of(p);
	if (!gang_key)
		return -1;

	struct member *m = bpf_map_lookup_elem(&members, &tid);
	if (m)
		return m->cpu;

	int node = scx_bpf_cpu_node(scx_bpf_task_cpu(p));

	s32 cpu = claim_cpu_on_node(gang_key, node, false);
	if (cpu < 0)
		cpu = claim_cpu_on_node(gang_key, node, true);
	if (cpu < 0)
		return -1;	/* oversubscribed */

	struct member nm = { .gang_key = gang_key, .cpu = cpu };
	bpf_map_update_elem(&members, &tid, &nm, BPF_ANY);
	return cpu;
}

s32 BPF_STRUCT_OPS(gang_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
{
	s32 cpu = gang_cpu(p);
	if (cpu >= 0)
		return cpu;

	bool is_idle = false;
	cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);
	return cpu;
}

void BPF_STRUCT_OPS(gang_enqueue, struct task_struct *p, u64 enq_flags)
{
	s32 cpu = gang_cpu(p);

	if (cpu >= 0) {
		/* Gang member: pin to its dedicated CPU and preempt whatever is
		 * there so the whole gang lands simultaneously. */
		stat_inc(1);
		scx_bpf_dsq_insert(p, SCX_DSQ_LOCAL_ON | cpu, SCX_SLICE_DFL,
				   enq_flags | SCX_ENQ_PREEMPT);
		scx_bpf_kick_cpu(cpu, SCX_KICK_PREEMPT);
		return;
	}

	if (gang_key_of(p))
		stat_inc(2);	/* gang member we could not place */
	else
		stat_inc(0);	/* background */

	if (fifo_sched) {
		scx_bpf_dsq_insert(p, SHARED_DSQ, SCX_SLICE_DFL, enq_flags);
	} else {
		u64 vtime = p->scx.dsq_vtime;

		if (time_before(vtime, vtime_now - SCX_SLICE_DFL))
			vtime = vtime_now - SCX_SLICE_DFL;

		scx_bpf_dsq_insert_vtime(p, SHARED_DSQ, SCX_SLICE_DFL, vtime,
					 enq_flags);
	}
}

void BPF_STRUCT_OPS(gang_dispatch, s32 cpu, struct task_struct *prev)
{
	u32 c = (u32)cpu;
	u64 *owner = bpf_map_lookup_elem(&cpu_owner, &c);

	/* Owned CPUs only ever run their gang member (placed via LOCAL_ON).
	 * Do not pull background work onto them. */
	if (owner && *owner != 0)
		return;

	scx_bpf_dsq_move_to_local(SHARED_DSQ);
}

void BPF_STRUCT_OPS(gang_running, struct task_struct *p)
{
	if (fifo_sched)
		return;
	if (time_before(vtime_now, p->scx.dsq_vtime))
		vtime_now = p->scx.dsq_vtime;
}

void BPF_STRUCT_OPS(gang_stopping, struct task_struct *p, bool runnable)
{
	if (fifo_sched)
		return;
	p->scx.dsq_vtime += (SCX_SLICE_DFL - p->scx.slice) * 100 / p->scx.weight;
}

void BPF_STRUCT_OPS(gang_exit_task, struct task_struct *p)
{
	u32 tid = p->pid;
	struct member *m = bpf_map_lookup_elem(&members, &tid);
	if (!m)
		return;

	u32 c = (u32)m->cpu;
	u64 *owner = bpf_map_lookup_elem(&cpu_owner, &c);
	if (owner)
		__sync_val_compare_and_swap(owner, m->gang_key, 0ULL);

	bpf_map_delete_elem(&members, &tid);
}

void BPF_STRUCT_OPS(gang_enable, struct task_struct *p)
{
	p->scx.dsq_vtime = vtime_now;
}

s32 BPF_STRUCT_OPS_SLEEPABLE(gang_init)
{
	return scx_bpf_create_dsq(SHARED_DSQ, -1);
}

void BPF_STRUCT_OPS(gang_exit, struct scx_exit_info *ei)
{
	UEI_RECORD(uei, ei);
}

SCX_OPS_DEFINE(gang_ops,
	       .select_cpu	= (void *)gang_select_cpu,
	       .enqueue		= (void *)gang_enqueue,
	       .dispatch	= (void *)gang_dispatch,
	       .running		= (void *)gang_running,
	       .stopping	= (void *)gang_stopping,
	       .exit_task	= (void *)gang_exit_task,
	       .enable		= (void *)gang_enable,
	       .init		= (void *)gang_init,
	       .exit		= (void *)gang_exit,
	       .name		= "gang");
