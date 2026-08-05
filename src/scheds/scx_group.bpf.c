/* SPDX-License-Identifier: GPL-2.0 */
/*
 * A group scheduler.
 *
 * By default, it operates as a simple global weighted vtime scheduler and can
 * be switched to FIFO scheduling. It also demonstrates the following niceties.
 *
 * - Statistics tracking how many tasks are queued to local and global dsq's.
 * - Termination notification for userspace.
 *
 * While very simple, this scheduler should work reasonably well on CPUs with a
 * uniform L3 cache topology. While preemption is not implemented, the fact that
 * the scheduling queue is shared across all CPUs means that whatever is at the
 * front of the queue is likely to be executed fairly quickly given enough
 * number of CPUs. The FIFO scheduling mode may be beneficial to some workloads
 * but comes with the usual problems with FIFO scheduling where saturating
 * threads can easily drown out interactive ones.
 *
 * Copyright (c) 2022 Meta Platforms, Inc. and affiliates.
 * Copyright (c) 2022 Tejun Heo <tj@kernel.org>
 * Copyright (c) 2022 David Vernet <dvernet@meta.com>
 */
#include <scx/common.bpf.h>

char _license[] SEC("license") = "GPL";

const volatile bool fifo_sched;

static u64 vtime_now;
UEI_DEFINE(uei);

/*
 * Built-in DSQs such as SCX_DSQ_GLOBAL cannot be used as priority queues
 * (meaning, cannot be dispatched to with scx_bpf_dsq_insert_vtime()). We
 * therefore create a separate DSQ with ID 0 that we dispatch to and consume
 * from. If scx_group only supported global FIFO scheduling, then we could just
 * use SCX_DSQ_GLOBAL.
 */
#define SHARED_DSQ 0
#define GROUP_DSQ 1

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(key_size, sizeof(u32));
	__uint(value_size, sizeof(u64));
	__uint(max_entries, 3);			/* [local, global, group] */
} stats SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__type(key, u32);
	__type(value, struct bpf_cpumask);
	__uint(max_entries, 1);
} masks SEC(".maps");

struct group_value {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, u32);
	__type(value, u32);
	__uint(max_entries, 16);
} __gv SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH_OF_MAPS);
	__type(key, u32);
	__uint(max_entries, 16);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
	__array(values, struct group_value);
} groups SEC(".maps");

static void stat_inc(u32 idx)
{
	u64 *cnt_p = bpf_map_lookup_elem(&stats, &idx);
	if (cnt_p)
		(*cnt_p)++;
}

s32 BPF_STRUCT_OPS(group_select_cpu, struct task_struct *p, s32 prev_cpu, u64 wake_flags)
{
	bool is_idle = false;
	s32 cpu;

	cpu = scx_bpf_select_cpu_dfl(p, prev_cpu, wake_flags, &is_idle);

	return cpu;
}

void BPF_STRUCT_OPS(group_enqueue, struct task_struct *p, u64 enq_flags)
{
	u32 tgid = p->tgid;
	u32 tid = p->pid;
	u32 *group_map = bpf_map_lookup_elem(&groups, &tgid);

	if (group_map && bpf_map_lookup_elem(group_map, &tid)) {
		stat_inc(2);	/* count group queueing */
		scx_bpf_dsq_insert(p, GROUP_DSQ, SCX_SLICE_DFL, enq_flags);
		return;
	}

	stat_inc(1);	/* count global queueing */

	if (fifo_sched) {
		scx_bpf_dsq_insert(p, SHARED_DSQ, SCX_SLICE_DFL, enq_flags);
	} else {
		u64 vtime = p->scx.dsq_vtime;

		/*
		 * Limit the amount of budget that an idling task can accumulate
		 * to one slice.
		 */
		if (time_before(vtime, vtime_now - SCX_SLICE_DFL))
			vtime = vtime_now - SCX_SLICE_DFL;

		scx_bpf_dsq_insert_vtime(p, SHARED_DSQ, SCX_SLICE_DFL, vtime,
					 enq_flags);
	}
}

struct dispatch_context {
	u32 current_tid;
	u32 current_gid;
};

static long dispatch_callback(struct bpf_map *map, const void *key, void *value, void *ctx) {
	struct dispatch_context *d_ctx = ctx;
	u32 zero = 0;

	struct bpf_cpumask *free_cpus = bpf_map_lookup_elem(&masks, &zero);
	if (!free_cpus)
		return 1;

	struct task_struct *p = bpf_task_from_pid(*(u32 *)key);
	if (!p)
		return 1;

	s32 used_cpu = scx_bpf_task_cpu(p);
	bool running = scx_bpf_task_running(p);

	if (*(u32 *)key != d_ctx->current_tid && *(u32 *)value == d_ctx->current_gid) {
		if (bpf_cpumask_test_cpu(used_cpu, (struct cpumask *)free_cpus)) {
			bpf_cpumask_clear_cpu(used_cpu, free_cpus);

			if (!running) {
				struct bpf_iter_scx_dsq it;

				if (bpf_iter_scx_dsq_new(&it, GROUP_DSQ, 0)) {
					bpf_iter_scx_dsq_destroy(&it);
					bpf_task_release(p);
					return 1;
				}

				struct task_struct *ip;
				do {
					ip = bpf_iter_scx_dsq_next(&it);
				} while (ip && ip != p);

				scx_bpf_dsq_move(&it, p, SCX_DSQ_LOCAL_ON | used_cpu, SCX_ENQ_WAKEUP | SCX_ENQ_PREEMPT);
				bpf_iter_scx_dsq_destroy(&it);
			}

			bpf_printk("kicked task %d on used cpu %d", *(u32 *)key, used_cpu);
		} else {
			s32 free_cpu = scx_bpf_pick_any_cpu((struct cpumask *)free_cpus, 0);
			if (free_cpu < 0) {
				bpf_task_release(p);
				return 1;
			}

			bpf_cpumask_clear_cpu(free_cpu, free_cpus);

			struct bpf_iter_scx_dsq it;
			if (bpf_iter_scx_dsq_new(&it, SCX_DSQ_LOCAL_ON | used_cpu, 0)) {
				bpf_iter_scx_dsq_destroy(&it);
				bpf_task_release(p);
				return 1;
			}

			struct task_struct *ip;
			do {
				ip = bpf_iter_scx_dsq_next(&it);
			} while (ip && ip != p);

			scx_bpf_dsq_move(&it, p, SCX_DSQ_LOCAL_ON | free_cpu, SCX_ENQ_WAKEUP | SCX_ENQ_PREEMPT);
			bpf_iter_scx_dsq_destroy(&it);

			bpf_printk("kicked task %d to free cpu %d", *(u32 *)key, free_cpu);
		}
	}

	bpf_task_release(p);
	return 0;
}

void BPF_STRUCT_OPS(group_dispatch, s32 cpu, struct task_struct *prev)
{
	if (scx_bpf_dsq_nr_queued(GROUP_DSQ) > 0) {
		struct bpf_iter_scx_dsq it;
		if (bpf_iter_scx_dsq_new(&it, GROUP_DSQ, 0)) {
			bpf_iter_scx_dsq_destroy(&it);
			goto dispatch_default;
		}

		struct task_struct *p = bpf_iter_scx_dsq_next(&it);
		if (!p) {
			bpf_iter_scx_dsq_destroy(&it);
			goto dispatch_default;
		}

		scx_bpf_dsq_move(&it, p, SCX_DSQ_LOCAL, SCX_ENQ_WAKEUP | SCX_ENQ_PREEMPT);
		bpf_iter_scx_dsq_destroy(&it);

		u32 tgid = p->tgid;
		u32 tid = p->pid;
		u32 zero = 0;

		u32 *group_map = bpf_map_lookup_elem(&groups, &tgid);
		if (!group_map)
			goto dispatch_default;

		u32 *gid = bpf_map_lookup_elem(group_map, &tid);
		if (!gid)
			goto dispatch_default;

		struct dispatch_context d_ctx = { .current_tid = tid,
						  .current_gid = *gid };

		struct bpf_cpumask *free_cpus = bpf_map_lookup_elem(&masks, &zero);
		if (!free_cpus)
			goto dispatch_default;

		bpf_cpumask_setall(free_cpus);
		bpf_cpumask_clear_cpu(cpu, free_cpus);

		bpf_for_each_map_elem(group_map, dispatch_callback, &d_ctx, 0);
	}

dispatch_default:
	scx_bpf_dsq_move_to_local(SHARED_DSQ);
}

void BPF_STRUCT_OPS(group_running, struct task_struct *p)
{
	if (fifo_sched)
		return;

	/*
	 * Global vtime always progresses forward as tasks start executing. The
	 * test and update can be performed concurrently from multiple CPUs and
	 * thus racy. Any error should be contained and temporary. Let's just
	 * live with it.
	 */
	if (time_before(vtime_now, p->scx.dsq_vtime))
		vtime_now = p->scx.dsq_vtime;
}

void BPF_STRUCT_OPS(group_stopping, struct task_struct *p, bool runnable)
{
	if (fifo_sched)
		return;

	/*
	 * Scale the execution time by the inverse of the weight and charge.
	 *
	 * Note that the default yield implementation yields by setting
	 * @p->scx.slice to zero and the following would treat the yielding task
	 * as if it has consumed all its slice. If this penalizes yielding tasks
	 * too much, determine the execution time by taking explicit timestamps
	 * instead of depending on @p->scx.slice.
	 */
	p->scx.dsq_vtime += (SCX_SLICE_DFL - p->scx.slice) * 100 / p->scx.weight;
}

void BPF_STRUCT_OPS(group_enable, struct task_struct *p)
{
	p->scx.dsq_vtime = vtime_now;
}

s32 BPF_STRUCT_OPS_SLEEPABLE(group_init)
{
	int err = scx_bpf_create_dsq(SHARED_DSQ, -1);
	if (err < 0)
		return err;

	return scx_bpf_create_dsq(GROUP_DSQ, -1);
}

void BPF_STRUCT_OPS(group_exit, struct scx_exit_info *ei)
{
	UEI_RECORD(uei, ei);
}

SCX_OPS_DEFINE(group_ops,
	       .select_cpu		= (void *)group_select_cpu,
	       .enqueue			= (void *)group_enqueue,
	       .dispatch		= (void *)group_dispatch,
	       .running			= (void *)group_running,
	       .stopping		= (void *)group_stopping,
	       .enable			= (void *)group_enable,
	       .init			= (void *)group_init,
	       .exit			= (void *)group_exit,
	       .name			= "group");
