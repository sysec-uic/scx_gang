#!/bin/bash
# Improved controlled NUMA experiment (v2):
#  - fixes multi-gang harness (correct per-gang + aggregate weak counts)
#  - richer stats: mean, sd, median, min, max (exposes the default's bimodality)
#  - throughput scaling: K gangs, scx_gang vs default, weak/second
# Sync held constant (sense_barrier); only scheduler/placement varies.
#
# Usage:  sudo -v ; N=20 bash scripts/20_single_gang.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin"
N="${N:-20}"
STATE=/sys/kernel/sched_ext/state
[ -e "$STATE" ] || { echo "No sched_ext ($STATE missing)"; exit 1; }

declare -A NODE_CPUS
while IFS=, read -r cpu node _; do
  [[ "$cpu" =~ ^# ]] && continue
  NODE_CPUS[$node]+="$cpu "
done < <(lscpu -p=CPU,NODE)
NODES=($(printf '%s\n' "${!NODE_CPUS[@]}" | sort -n))
NCPU=$(nproc)
echo "nodes=${#NODES[@]} cpus=$NCPU  N=$N  iters/run=1,000,000"
first_n () { echo $1 | tr ' ' '\n' | grep -v '^$' | head -n "$2" | paste -sd, ; }
WITHIN=$(first_n "${NODE_CPUS[${NODES[0]}]}" 3)
CROSS=""
[ "${#NODES[@]}" -ge 2 ] && CROSS="$(first_n "${NODE_CPUS[${NODES[0]}]}" 2),$(first_n "${NODE_CPUS[${NODES[1]}]}" 1)"

stats () {  # numbers on stdin -> "mean +- sd  median min max"
  sort -n | awk '{a[n++]=$1; s+=$1; ss+=$1*$1}
    END{ if(!n){printf "no data"; exit}
      m=s/n; v=ss/n-m*m; if(v<0)v=0;
      med=(n%2)?a[int(n/2)]:(a[n/2-1]+a[n/2])/2;
      printf "%7.0f +- %-6.0f  med=%-7.0f min=%-6.0f max=%-7.0f", m, sqrt(v), med, a[0], a[n-1] }'
}
wait_state () { for _ in $(seq 1 50); do [ "$(cat $STATE)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
load_sched () { sudo rm -f /sys/fs/bpf/groups /sys/fs/bpf/explore 2>/dev/null
  sudo "$BIN/$1" >/tmp/$1.log 2>&1 & wait_state enabled || { echo "  !! $1 load failed: $(tail -1 /tmp/$1.log)"; return 1; }; }
unload_sched () { sudo pkill -INT -f "$BIN/$1" 2>/dev/null; wait_state disabled; sudo rm -f /sys/fs/bpf/groups 2>/dev/null; }

run_single () {  # label cmd...
  local label="$1"; shift; local out=""
  for _ in $(seq 1 "$N"); do v=$("$@" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && out+="$v"$'\n'; done
  printf "  %-12s %s\n" "$label" "$(printf '%s' "$out" | stats)"
}

multigang () {  # K binary -> prints aggregate over 3 trials
  local K="$1" bin="$2"
  local agg=""
  for trial in 1 2 3; do
    local tmp; tmp=$(mktemp -d); local start end
    start=$(date +%s.%N)
    local pids=()
    for i in $(seq 1 "$K"); do ( sudo "$BIN/$bin" >"$tmp/$i" 2>/dev/null ) & pids+=($!); done
    for p in "${pids[@]}"; do wait "$p"; done
    end=$(date +%s.%N)
    local tot=0 v
    for i in $(seq 1 "$K"); do v=$(cat "$tmp/$i" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && tot=$((tot+v)); done
    local wall thr; wall=$(echo "$end-$start"|bc); thr=$(echo "scale=0; $tot/$wall"|bc 2>/dev/null)
    agg+="$tot $wall $thr"$'\n'
    rm -rf "$tmp"
  done
  printf '%s' "$agg" | awk '{t+=$1; w+=$3; n++} END{printf "total_weak~%-8.0f  agg_throughput~%-9.0f weak/s  (mean of %d trials)\n", t/n, w/n, n}'
}

echo
echo "########## SINGLE-GANG (controlled: sync=sense_barrier), weak/1M ##########"
unload_sched scx_gang >/dev/null 2>&1; unload_sched scx_group >/dev/null 2>&1
run_single "D-unpinned"  sudo "$BIN/sb_sense"
run_single "D-1socket"   sudo taskset -c "$WITHIN" "$BIN/sb_sense"
[ -n "$CROSS" ] && run_single "D-crossnode" sudo taskset -c "$CROSS" "$BIN/sb_sense"
load_sched scx_gang  && { run_single "scx_gang"  sudo "$BIN/sb_group_plus"; unload_sched scx_gang; }
load_sched scx_group && { run_single "scx_group" sudo "$BIN/sb_group_plus"; unload_sched scx_group; }

echo
echo "########## THROUGHPUT SCALING (K gangs; aggregate weak/second) ##########"
MAXK=$(( NCPU / 6 )); [ "$MAXK" -lt 1 ] && MAXK=1   # 3 threads/gang, leave headroom
KS=(1 2 4 8);
for K in "${KS[@]}"; do
  [ "$K" -le "$MAXK" ] || continue
  echo "--- K=$K gangs ---"
  unload_sched scx_gang >/dev/null 2>&1
  echo -n "  default :  "; multigang "$K" sb_sense
  load_sched scx_gang && { echo -n "  scx_gang:  "; multigang "$K" sb_group_plus; unload_sched scx_gang; }
done
echo
echo "(default uses sb_sense; scx_gang uses sb_group_plus; both = lightweight sense_barrier)"
