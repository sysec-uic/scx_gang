# Comparison against `litmus7`

[`litmus7`](https://github.com/herd/herdtools7) (herdtools7) is the field-standard
litmus-test runner. It offers static affinity (`-affinity`, `-p`), which is
exactly the "pinning" the paper argues is not enough. The scripts in
`scripts/litmus7/` run the comparison honestly: they give `litmus7` its *best*
configuration, not its default.

## Building `litmus7` from source

The Ubuntu `herdtools7` package cannot run tests — it compiles in a
non-existent libdir (`/sbuild-nonexistent/...`) and ships no runtime templates.
Build from source. Only `litmus7` is needed (`herd7` additionally requires
zarith/logs/ASL, and a full `make build` will fail without them):

```bash
sudo apt-get install -y ocaml ocaml-dune menhir libzarith-ocaml-dev liblogs-ocaml-dev
git clone --depth 1 https://github.com/herd/herdtools7.git
cd herdtools7
make build          # generates Version.ml
dune build litmus/litmus.exe
mkdir -p ~/.local/bin ~/.local/share/herdtools7/litmus
cp _build/default/litmus/litmus.exe ~/.local/bin/litmus7.real
cp -r litmus/libdir/* ~/.local/share/herdtools7/litmus/
printf '#!/bin/bash\nexec "$(dirname "$0")/litmus7.real" -set-libdir "$HOME/.local/share/herdtools7/litmus" "$@"\n' > ~/.local/bin/litmus7
chmod +x ~/.local/bin/litmus7
export PATH=$HOME/.local/bin:$PATH
```

## Configure it fairly

`litmus7`'s yield is dominated by `-barrier`; its default is weak, and comparing
against it would be a strawman. On the single-socket desktop, SB, weak / 10⁶:

| `litmus7` config | weak / 10⁶ |
|---|---:|
| `-affinity incr1` (default `-barrier user`) | ~0.15 |
| `-affinity incr1 -barrier pthread` | ~410 |
| `-affinity incr1 -barrier userfence` | ~1,400 |
| `-affinity incr1 -barrier timebase` | **~278,000** |

Always run it with **`-barrier timebase -affinity incr1`** (or a hand-tuned
`-p <core list>` for NUMA locality). The scripts here do.

Because per-iteration semantics differ between the two tools, the common metric
is **weak behaviours per second of wall-clock**, plus the per-instance floor
under concurrency.

## Scripts

| script | what it does |
|---|---|
| `litmus7_vs_gang.sh` | single test (`litmus7` timebase, `litmus7` hand-pinned, `scx_gang`), then an oversubscription sweep reporting aggregate weak/s and the per-instance floor for `litmus7` vs `scx_tgang` |
| `oversub_pin.sh` | adds the static `taskset`-pin baseline to the paper's oversubscription methodology (per-gang weak/10⁶, sync held constant) |
| `oversub_clean.sh` | the full four-way run — default, pin, `scx_gang`, `scx_tgang` — with completion counts and a generous 60 s hang guard. **This is the canonical oversubscription run** (`results/litmus7/clean.log`) |
| `oversub_compare.sh` | earlier, tightly capped variant, kept for provenance — see the caveat below |

```bash
sudo -v
LIT=~/.local/bin/litmus7 bash scripts/litmus7/litmus7_vs_gang.sh
TRIALS=8 CAP=60 PINCAP=20 bash scripts/litmus7/oversub_clean.sh
```

## What the comparison shows

**Single test — pinning is enough, and we say so.** On the 48-core NUMA box
(`results/litmus7/run1.log`):

| | weak/s |
|---|---:|
| `litmus7` `-barrier timebase -affinity incr1` | 13,457 |
| `litmus7` hand-tuned `-p 0,1` | 20,704 |
| `scx_gang` (automatic, NUMA-local) | 5,430 |

Well-tuned `litmus7` beats the gang scheduler on a single test. `timebase`
synchronization aligns starts by cycle counter, which is a stronger primitive
than our `sense_barrier`. The gang scheduler's contribution is therefore *not*
raw single-test rate — it is automatic NUMA locality without a hand-written core
list, and coherence under oversubscription.

**Under load — static affinity collapses.** `results/litmus7/clean.log`, at 1.5×
oversubscription only 14 of 192 pinned gangs finish inside 60 s, and 0 of 256 at
2×, while `scx_tgang` completes all 192 with a median of 17,231 weak/10⁶.
Statically pinned spinning threads on shared cores are time-sliced independently
by the OS, so they never all hold a CPU at once. That is the capability static
affinity cannot express, and it is what the paper claims.

## Caveat on `cmp.log`

`results/litmus7/cmp.log` came from `oversub_compare.sh` with a 12 s cap and
appeared to show `scx_tgang` collapsing at K=32. That was a **cap artifact**:
temporal multiplexing gives each gang a turn, so a campaign needs more
wall-clock, and a tight cap cuts it off. With the 60 s guard
(`oversub_clean.sh`) `scx_tgang` ≥ `scx_gang` at every K with much higher floors.
Use `clean.log`; `cmp.log` is retained only so the discrepancy is on the record.
