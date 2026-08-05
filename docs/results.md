# Results

The numbers below are the runs the paper reports. Raw output is in `results/`;
each section names its file. Absolute rates depend on machine, kernel and
microcode — the comparisons *within* a table are what should reproduce.

## Platforms

| | machine | cores | NUMA | kernel |
|---|---|---|---|---|
| **A** | 2× Xeon Gold 6240R (Chameleon Cloud) | 48 | 2 nodes | 7.0.0, `sched_ext` |
| **B** | Core i7-9700 desktop | 8 | 1 node | 7.0, `sched_ext` |
| **C** | Jetson Orin Nano, 6× Cortex-A78AE | 6 | 2 clusters | 5.15-tegra, *no* `sched_ext` |

Platform A runs used `governor=performance`, `no_turbo=1`.

## 1. The confound: synchronization, not scheduling, dominates naive comparisons

Platform B, default scheduler, N=30, only the barrier varies
(`results/desktop_confound.txt`):

| synchronization | median weak / 10⁶ | min | max |
|---|---:|---:|---:|
| `std::barrier` (blocking) | 39 | 4 | 1,639 |
| `sense_barrier` (spinning) | 76,676 | 5,845 | 422,674 |

~2000× from the barrier alone. Any comparison that changes the barrier *and*
the scheduler tells you nothing about the scheduler. Everything below holds it
constant.

## 2. Placement (platform A, single gang, N=30)

`results/clean_run.txt`, weak / 10⁶ iterations:

| config | median | min | max |
|---|---:|---:|---:|
| default, unpinned | 1,429 | 7 | 12,284 |
| default, forced cross-node | 62 | 9 | 577 |
| default, hand-pinned to one socket | 10,906 | 6,710 | 27,278 |
| **`scx_gang`** | **11,835** | 4,002 | 27,652 |
| `scx_group` | 11,656 | 2,012 | 26,082 |

`scx_gang` matches hand-tuned same-socket pinning **automatically**, is ~8×
the unpinned default, and ~190× the cross-node case. The `min` column is the
real point: the default is bimodal — sometimes it places well, sometimes it
scatters and the campaign yields almost nothing. Gang scheduling removes that
lottery.

## 3. Throughput scaling (platform A, TRIALS=20)

`results/clean_run.txt` (an earlier 12-trial run is in `results/throughput.txt`),
aggregate weak/second:

| K gangs | default | `scx_gang` | median gain |
|---:|---|---|---:|
| 1 | 670 ± 1,207 [7..5,813] | 5,972 ± 2,021 [2,407..11,543] | 11.1× |
| 2 | 5,955 ± 4,541 [9..13,288] | 10,019 ± 3,068 [4,707..16,604] | 1.3× |
| 4 | 4,754 ± 2,937 [105..11,636] | 19,229 ± 6,433 [7,753..35,176] | 4.8× |
| 6 | 8,916 ± 4,975 [2,982..20,687] | 17,986 ± 13,119 [4,912..61,273] | 2.0× |
| 8 | 13,617 ± 8,151 [392..26,487] | 13,084 ± 7,147 [1,351..28,283] | 1.1× |

Again read the floors, not the means. The default's minimum falls to 7, 9, 105,
392 weak/s — failed campaigns — while `scx_gang` never drops below ~1,300. The
median gain shrinks as K grows because the machine saturates and even random
placement ends up co-scheduling.

## 4. Oversubscription (platform A, 3 threads/gang, TRIALS=8)

`results/oversub.txt`, median per-gang weak / 10⁶:

| K gangs | 4 | 8 | 16 | 24 | 32 |
|---|---:|---:|---:|---:|---:|
| threads (3K) | 12 | 24 | 48 | 72 | 96 |
| subscription | .25× | .5× | 1.0× | 1.5× | 2.0× |
| default | 114 | 1,162 | 7,252 | 14,250 | **15,590** |
| `scx_gang` (spatial) | **11,259** | 370 | 12,033 | 7,263 | 5,105 |
| `scx_tgang` (temporal) | 11,028 | **11,402** | **17,652** | **18,365** | 14,628 |

`scx_tgang` is the only policy that stays high at every load. `scx_gang`
collapses at K=8 — gangs pile onto one node because it assigns a gang to the
node of its first member with no balancing — and degrades once oversubscribed,
as expected for spatial reservation.

**With the static-pinning baseline and completion counts**
(`results/litmus7/clean.log`, same methodology, 60 s hang guard, `taskset`-pinned
gangs added):

| K | policy | completed | median per-gang weak / 10⁶ |
|---:|---|---:|---:|
| 16 (1.0×) | `taskset`-pin | 128/128 | 4,920 |
| | `scx_tgang` | 128/128 | 18,137 |
| 24 (1.5×) | `taskset`-pin | **14/192** | 88 |
| | `scx_tgang` | 192/192 | 17,231 |
| 32 (2.0×) | `taskset`-pin | **0/256** | — |
| | `scx_tgang` | 62/256 | 12,456 |

This is the result the title rests on: static pinning gives *no* benefit while
gangs fit (4,920 vs the default's 4,735) and **livelocks** once oversubscribed —
pinned spinning threads on shared cores never all get the CPU at once. At 2×,
`scx_tgang` serializes 32 gangs so fewer finish inside the 60 s guard, but every
gang that completes keeps a floor above 4,000; the default and `scx_gang`
complete more campaigns with far worse per-gang floors.

## 5. Partial activation (platform A, TRIALS=5)

`results/tgang_partial_activation.txt` — activation passes that placed at least
one member but not the whole front gang:

| K | 4 | 8 | 16 | 20 | 24 | 32 |
|---|---:|---:|---:|---:|---:|---:|
| subscription | .25× | .5× | 1.0× | 1.25× | 1.5× | 2.0× |
| partial | 0.00 % | 0.00 % | 0.01 % | 1.58 % | 9.41 % | 29.36 % |

Partial activation is purely an oversubscription effect, and even at 29 % the
per-gang floor stays the highest of any policy — so strict all-or-nothing
admission is an option, not a correctness requirement.

## 6. Boundary condition: one socket (platform B, N=30)

`results/desktop_single_socket.txt`, weak / 10⁶:

| config | median |
|---|---:|
| default, unpinned | 87,322 |
| `scx_gang` | 90,972 |
| `scx_group` | 114,041 |

On a single socket there is no placement to fix: EEVDF already co-schedules a
handful of spinning threads, and gang scheduling neither helps nor hurts (it
costs ~40 % throughput — 88k vs 144k weak/s — in dispatch overhead). The
scheduler's benefit is specifically the cross-socket placement problem. Reported
as a negative control.

## 7. ARM breadth (platform C, N=10)

`results/jetson_arm_suite.txt`, weak / 10⁶, no scheduler involved:

| test | default | same-cluster | cross-cluster |
|---|---:|---:|---:|
| SB | 463,608 | 832,458 | 800,173 |
| MP | 38,584 | 10,051 | 11,969 |
| LB | 0 | 0 | 0 |
| 2+2W | 3,508 | 22,237 | 24,710 |
| IRIW | 92 | — | — |

MP, LB, 2+2W and IRIW are forbidden under x86-TSO and read 0 there; nonzero
here confirms the harness exposes genuine weak-memory behaviour on weakly
ordered hardware. LB stays 0 (the A78 does not expose it easily). IRIW needs
four workers, which do not fit a three-core cluster, so the placement columns are
n/a. Placement modulates the rates, so "placement matters" generalises beyond
x86 — but the *scheduler* results are x86-only, since the board has no
`sched_ext`.

## 8. Versus `litmus7`

See [docs/litmus7.md](litmus7.md). In short: well-tuned `litmus7`
(`-barrier timebase -affinity incr1`) reaches ~13,500 weak/s on a single test
against `scx_gang`'s ~5,400, so **pinning is enough for one test** and we do not
claim otherwise. Its static affinity collapses under oversubscription in the
same way `taskset`-pinning does above.

## Raw files

| file | what |
|---|---|
| `clean_run.txt` | platform A: single-gang placement (N=30) + throughput scaling (20 trials) |
| `throughput.txt` | platform A: earlier throughput run (12 trials) |
| `oversub.txt` | platform A: oversubscription, default vs gang vs tgang |
| `tgang_partial_activation.txt` | platform A: `scx_tgang` partial-activation rate |
| `numa_results.txt`, `numa_results_v2.txt` | platform A: earlier NUMA runs (pre-frequency-pinning) |
| `desktop_confound.txt`, `desktop_single_socket.txt` | platform B |
| `jetson_arm_suite.txt` | platform C |
| `litmus7/run1.log` | `litmus7` vs gang, single test and oversubscription sweep |
| `litmus7/clean.log` | oversubscription with the `taskset`-pin baseline, 60 s guard |
| `litmus7/cmp.log` | earlier capped run — **superseded**, see [docs/litmus7.md](litmus7.md) |
| `fig1_single_gang.*`, `fig2_throughput.*`, `fig3_oversub.*` | the paper's figures |
| `plot_results.py` | regenerates the figures |
