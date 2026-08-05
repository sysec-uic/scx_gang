#!/bin/bash
# Build the sched_ext schedulers (scx_gang, scx_tgang, scx_group) and the litmus
# tests, using ONLY system clang/bpftool/libbpf plus an scx checkout for headers.
# No meson, no bundled bpftool (which breaks under gcc 15). Validated on x86.
#
# Usage:
#   SCX_DIR=/path/to/scx  bash scripts/10_build.sh   # schedulers + tests
#   NO_BPF=1              bash scripts/10_build.sh   # tests only (no libbpf host)
#
# Knobs: SCX_TAG (default v1.1.0; "skip" = use the checkout as-is).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDS="$ROOT/src/scheds"
TESTS="$ROOT/src/tests"
OUT="$ROOT/bin"
mkdir -p "$OUT"

if [ "${NO_BPF:-0}" = 1 ]; then
  echo "=== NO_BPF: building litmus harness without libbpf ==="
  make -C "$TESTS" litmus_nobpf >/dev/null
  cp "$TESTS/litmus_nobpf" "$OUT/"
  echo "    -> $OUT/litmus_nobpf"
  exit 0
fi

: "${SCX_DIR:?Set SCX_DIR to an scx git checkout (git clone https://github.com/sched-ext/scx)}"
# Pin to a known-good release: scx 'main' drifts (e.g. scx_bpf_dsq_move_to_local
# gained a 2nd arg after v1.1.0) and may outrun an older kernel's sched_ext API.
SCX_TAG="${SCX_TAG:-v1.1.0}"
if [ "$SCX_TAG" != skip ] && [ -d "$SCX_DIR/.git" ]; then
  echo "=== checking out scx $SCX_TAG (set SCX_TAG=skip to keep current) ==="
  git -C "$SCX_DIR" checkout -q "$SCX_TAG" || echo "  (checkout failed; building against current tree)"
fi
# Locate bpftool. Keep every probe non-fatal: under `set -e -o pipefail` a bare
# `ls` of a missing path would abort the script before the error message below.
BPFTOOL="$(command -v bpftool 2>/dev/null || true)"
if [ -z "$BPFTOOL" ]; then
  for cand in /usr/sbin/bpftool /usr/local/sbin/bpftool /usr/lib/linux-tools/*/bpftool; do
    [ -x "$cand" ] && { BPFTOOL="$cand"; break; }
  done
fi
if [ -z "${BPFTOOL:-}" ] || [ ! -x "$BPFTOOL" ]; then
  echo "ERROR: bpftool not found. Install it:" >&2
  echo "  sudo apt install -y bpftool            # or: linux-tools-\$(uname -r) linux-tools-common" >&2
  echo "Run scripts/00_probe.sh to check the rest of the toolchain too." >&2
  exit 1
fi
echo "using bpftool: $BPFTOOL ($("$BPFTOOL" version 2>/dev/null | head -1))"
ARCH_DIR="$SCX_DIR/scheds/vmlinux/arch/x86"
[ -d "$ARCH_DIR" ] || ARCH_DIR="$SCX_DIR/scheds/vmlinux"   # tolerate layout differences

INC=( -I "$SCX_DIR/scheds/include"
      -I "$SCX_DIR/scheds/include/bpf-compat"
      -I "$SCX_DIR/scheds/include/lib"
      -I "$SCX_DIR/scheds/vmlinux"
      -I "$ARCH_DIR" )

build_sched () {
  local s="$1"
  echo "=== building $s ==="
  clang -g -O2 -Wall -Wno-compare-distinct-pointer-types -D__TARGET_ARCH_x86 \
        -mcpu=v3 -mlittle-endian -target bpf "${INC[@]}" \
        -c "$SCHEDS/$s.bpf.c" -o "$OUT/$s.bpf.o"
  "$BPFTOOL" gen object "$OUT/$s.bpf.l1o" "$OUT/$s.bpf.o"
  "$BPFTOOL" gen object "$OUT/$s.bpf.l2o" "$OUT/$s.bpf.l1o"
  "$BPFTOOL" gen object "$OUT/$s.bpf.l3o" "$OUT/$s.bpf.l2o"
  "$BPFTOOL" gen skeleton "$OUT/$s.bpf.l3o" name "$s" > "$OUT/$s.bpf.skel.h"
  cc -I"$OUT" -I"$SCX_DIR/scheds/include" -I"$SCX_DIR/scheds/vmlinux" \
     -D_FILE_OFFSET_BITS=64 -Wall -std=gnu11 -O2 -g -pthread \
     -o "$OUT/$s.c.o" -c "$SCHEDS/$s.c"
  cc -Wl,--as-needed -Wl,--start-group "$OUT/$s.c.o" -lbpf -lelf -lz -lzstd \
     -Wl,--end-group -pthread -o "$OUT/$s"
  echo "    -> $OUT/$s"
}

build_sched scx_gang
build_sched scx_tgang
build_sched scx_group

echo "=== building litmus tests ==="
make -C "$TESTS" >/dev/null
cp "$TESTS"/sb "$TESTS"/sb_sense "$TESTS"/sb_group "$TESTS"/sb_group_plus "$TESTS"/litmus "$OUT/"
echo "    -> tests in $OUT/"
echo
echo "BUILD COMPLETE. Binaries:"; ls -1 "$OUT" | grep -vE "\.(o|l[123]o|skel\.h)$"
