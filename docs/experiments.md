# Experiments

All scripts live in `scripts/` and expect `bin/` to be populated
([docs/build.md](build.md)). They need root to load a scheduler and to run the
tests, so cache credentials first:

```bash
sudo -v
```

Each script unloads its scheduler when it finishes; if one is interrupted, see
the cleanup snippet in [docs/build.md](build.md).

## The harness

`src/tests/litmus.cpp` is the general harness. A main thread resets the shared
locations, releases *n* worker threads through a barrier, waits for them on a
second barrier, and classifies the recorded outcome:

```bash
bin/litmus -t SB|MP|LB|2+2W|IRIW [-n ITERATIONS] [-g]
```

It prints one number: the count of **weak** outcomes. `-g` opts the process into
gang scheduling (requires `scx_gang`, `scx_tgang` or `scx_group` loaded). On
x86-TSO only SB can produce weak outcomes; MP, LB, 2+2W and IRIW are
TSO-forbidden and read ~0 there — they come alive on weakly ordered hardware,
which is what `scripts/24_arm_suite.sh` demonstrates.

The `sb*` binaries are the fixed SB variants used by the experiment scripts,
and they exist to separate two variables:

| binary | synchronization | gang opt-in |
|---|---|---|
| `sb` | `std::barrier` (blocking) | no |
| `sb_sense` | `sense_barrier` (spinning) | no |
| `sb_group` | `std::barrier` | yes |
| `sb_group_plus` | `sense_barrier` | yes |

**Why this matters — the confound.** Comparing `sb` under the default scheduler
against `sb_group_plus` under a gang scheduler changes *two* things at once, and
the synchronization primitive dominates: on the same machine and scheduler,
switching `std::barrier` → `sense_barrier` moves the median from 39 to 76,676
weak per 10⁶ iterations (`results/desktop_confound.txt`). A blocking barrier
descheduls the threads it is supposed to align. Every experiment below
therefore holds synchronization constant at `sense_barrier` — the default
scheduler runs `sb_sense`, the gang schedulers run `sb_group_plus` — so any
difference is attributable to scheduling alone.

## Metrics

- **weak / 10⁶ iterations** — the coherence of one test instance. Reported as
  median, mean and `[min..max]`; the *minimum* matters as much as the median,
  because a scheduler that is usually good and occasionally catastrophic is
  useless for a measurement campaign.
- **weak / second** — throughput of a whole campaign, used when comparing tools
  whose per-iteration semantics differ (e.g. `litmus7`).
- **per-gang floor** — the worst instance in a concurrent campaign; the headline
  metric under oversubscription.
- **completions / attempted** — how many gangs finished their 10⁶-iteration
  campaign inside the wall-clock guard. This is how static pinning's livelock
  shows up.

## The scripts

### `00_probe.sh` — check the machine
Read-only. Prints host, CPU/NUMA topology, `sched_ext` availability, BTF, and
toolchain versions, plus an apt line for anything missing. Run it first on any
new machine.

### `20_single_gang.sh` — placement comparison (paper Table 1, Fig. 1)
```bash
N=30 bash scripts/20_single_gang.sh
```
One gang of 3 threads, synchronization held constant, `N` runs per configuration:

| config | scheduler | placement |
|---|---|---|
| `D-unpinned` | default | OS chooses (may scatter across sockets) |
| `D-1socket` | default | hand-pinned within one NUMA node |
| `D-crossnode` | default | forced across two nodes |
| `scx_gang` | gang | automatic, NUMA-local |
| `scx_group` | single-group | — |

Reading it: if `scx_gang ≈ D-1socket ≫ D-unpinned ≈ D-crossnode`, the scheduler
delivers same-socket co-scheduling automatically that otherwise needs manual
pinning, and the default's scattering genuinely costs. If `D-unpinned ≈
scx_gang`, this machine has no placement problem to fix (which is exactly what a
single-socket box shows — see [docs/results.md](results.md)).

The script then runs a small multi-gang throughput section (one gang per node,
gang vs default, wall-clock normalised).

### `21_throughput.sh` — throughput scaling (paper Fig. 2)
```bash
TRIALS=20 bash scripts/21_throughput.sh
```
For K ∈ {1, 2, 4, 6, 8} concurrent gangs and each scheduler, runs `TRIALS`
independent campaigns and reports aggregate weak/second as
`mean ± sd [min..max]` plus the median gain. The story is in the spread, not the
mean: the default's floor collapses to single digits on unlucky placements while
the gang scheduler holds a floor in the thousands.

### `22_oversub.sh` — spatial vs temporal under load (paper Fig. 3, Table 3)
```bash
TRIALS=8 bash scripts/22_oversub.sh
```
K ∈ {4, 8, 16, 24, 32} gangs of 3 threads (oversubscribed once 3K > cores),
three policies: default, `scx_gang` (spatial), `scx_tgang` (temporal). Reports
per-gang weak/10⁶ pooled over trials. This is where spatial reservation runs out
of CPUs and temporal multiplexing takes over.

To add the static-pinning baseline (the `taskset-pin` row of the paper's table)
and completion counts, use `scripts/litmus7/oversub_clean.sh`, which follows the
same methodology with a generous 60 s hang guard —
see [docs/litmus7.md](litmus7.md).

### `23_partial.sh` — how atomic is gang activation?
```bash
TRIALS=5 bash scripts/23_partial.sh
```
Reads `scx_tgang`'s `partial` and `activations` counters around campaigns of K
gangs and reports the fraction of activation passes that placed at least one
member but ran out of idle CPUs before the whole front gang fit. Quantifies the
one design compromise in `scx_tgang` ([docs/design.md](design.md)).

### `24_arm_suite.sh` — weak-memory breadth on ARM
```bash
NO_BPF=1 bash scripts/10_build.sh
N=10 bash scripts/24_arm_suite.sh
```
No scheduler involved (the ARM boards we had access to have no `sched_ext`).
Runs the whole test catalog and compares same-cluster against cross-cluster
placement, showing that the tests do expose weak behaviour on weakly ordered
hardware and that placement modulates the rate there too. `CLUSTER0`,
`CLUSTER1` and `CROSS` default to the Jetson Orin Nano layout (two clusters of
three cores); override them for other topologies.

## Reproduction notes

- **Frequency scaling adds variance.** The paper's runs used
  `governor=performance` and `no_turbo=1`. Set them before a campaign and
  restore afterwards.
- **Trial counts.** `N`/`TRIALS` default low so a smoke run is quick; the
  published numbers used N=30 for `20_single_gang.sh`, TRIALS=20 for
  `21_throughput.sh`, TRIALS=8 for `22_oversub.sh`.
- **Absolute rates are not portable** across machines, kernels or microcode.
  The comparisons within one table are what reproduce.
- **Leave the machine clean.** Confirm `/sys/kernel/sched_ext/state` reads
  `disabled` when you are done.
