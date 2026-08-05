# Building

## Requirements

| | |
|---|---|
| Kernel | `sched_ext` enabled: `CONFIG_SCHED_CLASS_EXT=y`, ≥ 6.12 (≥ 6.13 for the NUMA kfuncs `scx_gang` uses). `/sys/kernel/sched_ext/state` must exist; `disabled` means available with no scheduler loaded. |
| BTF | `/sys/kernel/btf/vmlinux` (`CONFIG_DEBUG_INFO_BTF=y`) |
| Tools | `clang`, `bpftool`, `libbpf-dev`, `libelf`, `zlib`, `libzstd`, `g++` (C++20), `numactl` |
| Headers | an [scx](https://github.com/sched-ext/scx) checkout — headers only, no scx build needed |

On Debian/Ubuntu:

```bash
sudo apt install -y clang llvm libbpf-dev libelf-dev zlib1g-dev libzstd-dev \
                    linux-tools-common linux-tools-$(uname -r) build-essential numactl git
```

`scripts/00_probe.sh` checks all of the above and prints what is missing.

## Build

```bash
git clone https://github.com/sched-ext/scx ~/scx
SCX_DIR=~/scx bash scripts/10_build.sh
```

Output lands in `bin/`: the three schedulers plus the litmus binaries (`litmus`,
`sb`, `sb_sense`, `sb_group`, `sb_group_plus`).

On a host without libbpf (ARM boards, containers), build just the harness:

```bash
NO_BPF=1 bash scripts/10_build.sh    # -> bin/litmus_nobpf, no -g gang opt-in
```

The tests can also be built directly with `make -C src/tests`.

## Why this build path

`10_build.sh` deliberately uses only system `clang`/`bpftool`/`libbpf` plus scx
headers: it compiles the BPF object, runs three `bpftool gen object` link
passes, generates a skeleton, and links the userspace loader. It does **not**
use scx's meson build or its bundled bpftool, both of which fail to build under
gcc 15.

## scx version pinning

`SCX_TAG` defaults to **v1.1.0**. scx `main` drifts ahead of released kernels —
for example `scx_bpf_dsq_move_to_local()` gained a second argument after v1.1.0,
and newer headers reference kfuncs an older kernel does not have.

| Kernel | scx tag |
|---|---|
| ≥ 6.15 | `v1.1.0` |
| 6.12 – 6.14 | ~`v1.0.4` |

Set `SCX_TAG=skip` to build against whatever the checkout has.

## Troubleshooting

**A scheduler fails to load with a verifier error about an unknown kfunc.** The
scx headers are newer than the kernel; check out an older scx tag.

**`bpftool` not found.** `apt install bpftool`, or
`linux-tools-$(uname -r)`. Note that on some Ubuntu releases the
`linux-tools-<version>` package for the running kernel does not exist while the
standalone `bpftool` package does.

**A scheduler is left loaded after an interrupted run.** `sched_ext` unloads a
misbehaving scheduler by itself, but to clean up manually:

```bash
sudo pkill -INT -f bin/scx_gang; sudo pkill -INT -f bin/scx_tgang; sudo pkill -INT -f bin/scx_group
sudo rm -f /sys/fs/bpf/groups
cat /sys/kernel/sched_ext/state   # expect: disabled
```

**Kernel without `sched_ext`.** The distribution kernel must have been built
with `CONFIG_SCHED_CLASS_EXT=y`; Ubuntu's 6.8 kernels predate the feature
entirely (it landed upstream in 6.12). The litmus harness still runs there —
only the `-g` gang opt-in and the schedulers need `sched_ext`.
