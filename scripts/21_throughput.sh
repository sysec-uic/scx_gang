#!/bin/bash
# Focused throughput-scaling measurement with proper statistics.
# For each K (concurrent gangs) and scheduler, run TRIALS independent campaigns
# and report aggregate weak/second as mean +- sd [min..max].
# Usage:  sudo -v ; TRIALS=10 bash scripts/21_throughput.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BIN="$ROOT/bin"
TRIALS="${TRIALS:-10}"; STATE=/sys/kernel/sched_ext/state
NCPU=$(nproc)
echo "cpus=$NCPU  trials/cell=$TRIALS  iters/run=1,000,000  (sync=sense_barrier throughout)"

wait_state () { for _ in $(seq 1 50); do [ "$(cat $STATE)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
load_sched () { sudo rm -f /sys/fs/bpf/groups 2>/dev/null; sudo "$BIN/$1" >/tmp/$1.log 2>&1 & wait_state enabled; }
unload_sched () { sudo pkill -INT -f "$BIN/$1" 2>/dev/null; wait_state disabled; sudo rm -f /sys/fs/bpf/groups 2>/dev/null; }

campaign () {  # K binary -> echoes one aggregate weak/second number
  local K="$1" bin="$2" tmp; tmp=$(mktemp -d)
  local start end; start=$(date +%s.%N)
  local pids=(); for i in $(seq 1 "$K"); do ( sudo "$BIN/$bin" >"$tmp/$i" 2>/dev/null ) & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p"; done
  end=$(date +%s.%N)
  local tot=0 v; for i in $(seq 1 "$K"); do v=$(cat "$tmp/$i" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && tot=$((tot+v)); done
  rm -rf "$tmp"
  echo "scale=0; $tot/($end-$start)" | bc
}
stats () { sort -n | awk '{a[n++]=$1;s+=$1;ss+=$1*$1} END{if(!n){print "no data";exit} m=s/n;v=ss/n-m*m;if(v<0)v=0; printf "%8.0f +- %-7.0f [%6.0f..%-7.0f]", m, sqrt(v), a[0], a[n-1]}'; }

printf "\n%-4s  %-38s  %-38s  %s\n" "K" "default (weak/s)" "scx_gang (weak/s)" "gain"
for K in 1 2 4 6 8; do
  [ $((K*3)) -le $((NCPU-2)) ] || continue
  unload_sched scx_gang >/dev/null 2>&1
  d=""; for _ in $(seq 1 "$TRIALS"); do d+="$(campaign "$K" sb_sense)"$'\n'; done
  load_sched scx_gang >/dev/null 2>&1
  g=""; for _ in $(seq 1 "$TRIALS"); do g+="$(campaign "$K" sb_group_plus)"$'\n'; done
  unload_sched scx_gang >/dev/null 2>&1
  dm=$(printf '%s' "$d" | sort -n | awk '{a[n++]=$1} END{print a[int(n/2)]}')
  gm=$(printf '%s' "$g" | sort -n | awk '{a[n++]=$1} END{print a[int(n/2)]}')
  gain=$(echo "scale=1; $gm/($dm+1)" | bc)
  printf "%-4s  %-38s  %-38s  %sx (median)\n" "$K" "$(printf '%s' "$d" | stats)" "$(printf '%s' "$g" | stats)" "$gain"
done
