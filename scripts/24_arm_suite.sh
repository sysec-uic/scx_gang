#!/bin/bash
# ARM weak-memory breadth check (no scheduler involved; the boards we had access
# to, e.g. Jetson Orin Nano on a 5.15 tegra kernel, have no sched_ext).
# Shows which litmus tests expose weak behaviour on weakly-ordered ARM, and
# whether same-cluster vs cross-cluster placement matters.
#
# CLUSTER0/CLUSTER1 default to the Orin Nano layout (2 clusters of 3 A78AE
# cores). Override for other topologies, e.g. CLUSTER0=0-3 CLUSTER1=4-7.
#
# Build first on a host without libbpf:  NO_BPF=1 bash scripts/10_build.sh
# Usage:  N=10 bash scripts/24_arm_suite.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
L="${L:-$ROOT/bin/litmus_nobpf}"
N="${N:-10}"
C0="${CLUSTER0:-0,1,2}"; C1="${CLUSTER1:-3,4,5}"
CROSS="${CROSS:-0,1,3}"
stats(){ sort -n | awk '{a[n++]=$1;s+=$1} END{if(!n){print "n/a";exit} printf "%8.0f  [%.0f..%.0f]", s/n, a[0], a[n-1]}'; }
runcfg(){ local lbl="$1"; shift; local o=""; for _ in $(seq 1 "$N"); do o+="$("$@" 2>/dev/null)"$'\n'; done; printf "    %-14s %s\n" "$lbl" "$(printf '%s' "$o" | stats)"; }

echo "ARM litmus breadth ($(uname -m), $(nproc) cores), N=$N, weak/1M  [min..max]"
for t in SB MP LB 2+2W IRIW; do
  echo "== $t =="
  runcfg "default" $L -t "$t"
  if [ "$t" != IRIW ]; then    # IRIW needs 4 workers (+main)=5 > one 3-core cluster
    runcfg "same-cluster"  taskset -c "$C0" $L -t "$t"
    runcfg "cross-cluster" taskset -c "$CROSS" $L -t "$t"
  fi
done
echo "(SB is the only x86-TSO-allowed test; MP/LB/2+2W/IRIW are TSO-forbidden -> 0 on x86, nonzero here = weak ARM memory)"
