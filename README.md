# scx_gang — Gang-Scheduling Memory-Model Litmus Tests with `sched_ext`

Artifact for the paper *"Pinning Isn't Enough: Gang-Scheduling Memory-Model
Litmus Tests with `sched_ext`"* (eBPF '26).

A litmus test only reveals weak hardware-memory behaviours when its threads run
**simultaneously on different cores**, within a window of a few cycles. Linux
does not guarantee that: on a multi-socket machine the default scheduler may
scatter the threads across sockets and collapse the observed rate, and static
pinning livelocks once a campaign oversubscribes the machine. This repository
contains two `sched_ext` (eBPF) schedulers that make the co-scheduling
invariant explicit, the litmus harness they schedule, and the experiments from
the paper.

- **`scx_gang`** — *spatial* gang scheduling: each gang member gets a dedicated,
  NUMA-local CPU; different gangs get disjoint CPU sets.
- **`scx_tgang`** — *temporal* gang scheduling: whole gangs are activated as
  units and time-sliced round-robin, so tests stay co-scheduled even at 2×
  oversubscription.
- **`scx_group`** — the earlier single-group co-scheduler, kept as a baseline.

## Layout

```
src/scheds/    scx_gang, scx_tgang, scx_group  (BPF part + userspace loader)
src/tests/     litmus harness (SB, MP, LB, 2+2W, IRIW) and the SB variants
scripts/       probe, build, and the paper's experiments (00_ .. 24_)
scripts/litmus7/  comparison against herdtools7 litmus7
results/       raw measurements and figures from the paper's runs
docs/          design, build, experiment and result documentation
```

## Requirements

A kernel with `sched_ext` (≥ 6.12; ≥ 6.13 for the NUMA kfuncs `scx_gang` uses)
and BTF, plus `clang`, `bpftool`, `libbpf-dev`, `g++`, `numactl`. The litmus
tests alone build anywhere with a C++20 compiler.

## Quick start

```bash
bash scripts/00_probe.sh                          # check kernel, topology, toolchain
git clone https://github.com/sched-ext/scx ~/scx  # headers only; pinned to v1.1.0
SCX_DIR=~/scx bash scripts/10_build.sh            # -> bin/
sudo -v
N=30      bash scripts/20_single_gang.sh          # placement comparison
TRIALS=20 bash scripts/21_throughput.sh           # throughput scaling
TRIALS=8  bash scripts/22_oversub.sh              # spatial vs temporal under load
```

Every experiment holds the synchronization primitive constant (a lightweight
`sense_barrier`), so any difference is attributable to scheduling alone — this
matters, see [docs/experiments.md](docs/experiments.md).

Run a single test by hand:

```bash
sudo bin/scx_gang &            # load the scheduler
sudo bin/litmus -t SB -g       # -g opts this process into a gang
```

## Results at a glance

On a 2-socket Xeon Gold 6240R (48 cores, 2 NUMA nodes, kernel 7.0):

| | median weak / 10⁶ iterations |
|---|---|
| default scheduler, unpinned | 1,429 (min 7 — wildly bimodal) |
| default, forced cross-socket | 62 |
| default, hand-pinned to one socket | 10,906 |
| **`scx_gang`** (automatic) | **11,835** |

Under 1.5× oversubscription, statically pinned gangs livelock (14 of 192
completed within 60 s) while `scx_tgang` holds a median of 17,231 per gang.
Full numbers and their caveats: [docs/results.md](docs/results.md).

## Documentation

- [docs/design.md](docs/design.md) — how the two gang schedulers work, and the BPF verifier constraints that shaped them
- [docs/build.md](docs/build.md) — toolchain, scx version pinning, troubleshooting
- [docs/experiments.md](docs/experiments.md) — what each script measures and how to read its output
- [docs/results.md](docs/results.md) — the paper's measurements, with pointers to the raw data
- [docs/litmus7.md](docs/litmus7.md) — comparison against herdtools7 `litmus7`

## License

GPL-2.0 (see `LICENSE`). The schedulers derive from `scx_simple` in the
[sched_ext scheduler collection](https://github.com/sched-ext/scx).
