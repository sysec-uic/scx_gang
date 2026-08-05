# Design

Three `sched_ext` schedulers live in `src/scheds/`. Each is a BPF part
(`*.bpf.c`) implementing the `sched_ext` struct_ops hooks, plus a small
userspace loader (`*.c`) that attaches it and prints statistics.

## The invariant

A litmus test's threads must be **running at the same instant on distinct
cores**. Nothing in the test can enforce that: it is a scheduling property. The
schedulers here encode it directly, in two different ways.

## Userspace opt-in protocol

Membership is explicit, not inferred. Each scheduler pins a map at
`/sys/fs/bpf/groups`, a `HASH_OF_MAPS` keyed by `tgid`, whose inner hash maps
`tid -> group_id`. A test process:

1. opens the pinned outer map, creates an inner `HASH` map and registers it
   under its own `tgid` (see `gang_optin()` / the `-g` path in
   `src/tests/litmus.cpp`);
2. has every worker thread insert its own `tid` with a group id;
3. deletes its `tgid` entry on exit.

The gang key is `(tgid << 32) | group_id`, so one process can run several
independent gangs, and unrelated processes never share a gang. Tasks with no
entry are "background" work and are scheduled by a plain weighted-vtime policy —
gang scheduling applies only to processes that ask for it, which is what makes
these schedulers safe to leave loaded on a shared machine.

## `scx_gang` — spatial gang scheduling

Each gang member is assigned **its own dedicated CPU**, claimed from a global
per-CPU ownership table (`cpu_owner[]`, `0` = free) and kept within a single
NUMA node — the node of the gang's first member. Consequences:

- All members become runnable together (the test's barrier) and each runs
  immediately on its dedicated, otherwise-idle CPU: intra-gang simultaneity with
  no dispatch-time gymnastics.
- Two gangs hold **disjoint** CPU sets, so they cannot disturb each other's
  simultaneity.
- Background tasks are steered onto un-owned CPUs and preempted off any CPU a
  gang claims.

Lifecycle: `select_cpu`/`enqueue` resolve the thread's gang, assign a free
NUMA-local CPU on first sight, and dispatch to `SCX_DSQ_LOCAL_ON | cpu` with a
kick; `exit_task` releases the CPU and drops the member entry, so gangs clean up
automatically. Stats: `background`, `gang`, `oversub` (a gang member that found
no free CPU on its node).

This is strictly more than `SCHED_FIFO` + `taskset`: the reservation is dynamic,
automatic, NUMA-aware, evicts interlopers, and cleans up on exit. Its limit is
capacity — once more gang threads exist than CPUs, spatial reservation has
nothing left to reserve.

## `scx_tgang` — temporal gang scheduling

`scx_tgang` addresses exactly that limit by multiplexing gangs **in time**.

All runnable gang members sit in one FIFO (`GANG_DSQ`). When a CPU runs out of
work it tries to *activate* the gang at the front: under a global try-lock
(`actlock`), a single greedy pass over the DSQ picks the first queued member,
fixes its gang `G`, and moves every queued member of `G` onto a distinct idle
CPU (`scx_bpf_pick_idle_cpu`) with `SCX_ENQ_PREEMPT`, kicking each target. If
idle CPUs run out mid-pass the rest of the gang stays queued (a *partial
activation*, counted in `stats[4]`) and is picked up on a later pass. Members
re-enqueue at the tail when their 20 ms slice expires, so gangs rotate
round-robin. The CPU then serves background work from the shared DSQ.

The result: as many gangs as fit run concurrently, the remainder take turns, and
every gang is co-scheduled whenever it runs. Neither `SCHED_FIFO` nor static
affinity can express this.

**How atomic is activation in practice?** Measured directly
(`scripts/23_partial.sh`, `results/tgang_partial_activation.txt`): ≤ 0.01 %
partial while gangs fit, 1.6 % at 1.25×, 9.4 % at 1.5×, 29.4 % at 2×
oversubscription. Even at 2× the per-gang floor stays the highest of any policy,
because round-robin re-forms the gang within a slice or two — strict
all-or-nothing admission is an option, not a correctness requirement.

## `scx_group` — the baseline

The original single-group co-scheduler: every grouped task goes into one shared
DSQ, and at dispatch the other members of the *currently dispatching* group are
kicked onto whatever CPUs look free. Nothing stops a second group from
preempting the first, so with a single group it is no more powerful than
`SCHED_FIFO`. It is kept here because the paper's earlier results were obtained
with it and it is the honest baseline for the two schedulers above.

## BPF verifier constraints that shaped the code

These cost real time; they are recorded so the next person does not rediscover
them.

1. **`__sync_lock_release` does not compile.** It emits a release-store the BPF
   backend cannot lower. Release the try-lock with
   `__sync_val_compare_and_swap(lock, 1, 0)` instead.
2. **Do not scan a per-CPU array map in a long loop.** Walking 512 CPU slots
   with a map lookup each blows the verifier's state budget (`-E2BIG`, reported
   misleadingly as "global function doesn't return scalar"). Use the O(1)
   cpumask kfuncs (`scx_bpf_pick_idle_cpu`, `bpf_cpumask_weight`).
3. **One DSQ iteration pass, one gang lookup per task.** An early `scx_tgang`
   used two `bpf_iter_scx_dsq` loops, each calling `gang_key_of()` (two map
   lookups); that also exhausted the state budget. The single greedy pass in
   `tgang_dispatch()` is the workaround, and is why activation is greedy rather
   than all-or-nothing.

## Known limitations

- Gang membership is per-thread and per-process; multi-process gangs are not
  expressible today.
- `scx_tgang`'s activation try-lock is global, so activation is serialized
  across the machine — fine at the scale evaluated here, a scalability
  bottleneck at much larger core counts.
- `scx_gang` assigns a gang to the NUMA node of its first member with no
  balancing across nodes; this is why it degrades at K = 8 in
  `results/oversub.txt` (gangs pile onto one node).
- Neither scheduler provides fairness or starvation guarantees for background
  work beyond the vtime policy; they are testing instruments, not
  general-purpose schedulers.
