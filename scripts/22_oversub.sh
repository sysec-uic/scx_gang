#!/bin/bash
# Oversubscription experiment: default vs scx_gang (spatial) vs scx_tgang
# (temporal). As the number of concurrent gangs K grows past what fits on the
# machine (3 threads/gang), spatial reservation can no longer give every gang
# dedicated CPUs; temporal multiplexing time-slices whole gangs so each stays
# co-scheduled. We report PER-GANG weak/1M (coherence) pooled over trials.
# Sync held constant (sense_barrier). Usage: sudo -v ; TRIALS=8 bash scripts/22_oversub.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BIN="$ROOT/bin"
TRIALS="${TRIALS:-8}"; STATE=/sys/kernel/sched_ext/state
NCPU=$(nproc)
echo "cpus=$NCPU  trials=$TRIALS  iters/run=1,000,000  (3 threads/gang; oversub when 3K>$NCPU)"

wait_state(){ for _ in $(seq 1 50); do [ "$(cat $STATE)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
load(){ sudo rm -f /sys/fs/bpf/groups 2>/dev/null; sudo "$BIN/$1" >/tmp/$1.log 2>&1 & wait_state enabled; }
unload(){ sudo pkill -INT -f "$BIN/$1" 2>/dev/null; wait_state disabled; sudo rm -f /sys/fs/bpf/groups 2>/dev/null; }
pergang_stats(){ sort -n | awk '{a[n++]=$1;s+=$1} END{if(!n){print "n/a";exit} printf "med=%-7.0f mean=%-7.0f [%.0f..%.0f]", a[int(n/2)], s/n, a[0], a[n-1]}'; }

# one campaign of K gangs with $1=binary -> prints K per-gang weak counts (one per line)
campaign(){ local K="$1" bin="$2" tmp; tmp=$(mktemp -d); local pids=()
  for i in $(seq 1 "$K"); do ( sudo "$BIN/$bin" >"$tmp/$i" 2>/dev/null ) & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p"; done
  for i in $(seq 1 "$K"); do v=$(cat "$tmp/$i" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"; done
  rm -rf "$tmp"; }

run_cell(){ local K="$1" sched="$2" bin="$3"   # collect per-gang counts over TRIALS
  [ "$sched" = default ] || load "$sched" >/dev/null 2>&1
  local all=""
  for _ in $(seq 1 "$TRIALS"); do all+="$(campaign "$K" "$bin")"$'\n'; done
  [ "$sched" = default ] || unload "$sched" >/dev/null 2>&1
  printf "  %-10s %s\n" "$sched" "$(printf '%s' "$all" | pergang_stats)"; }

for K in 4 8 16 24 32; do
  sub="under"; [ $((3*K)) -gt "$NCPU" ] && sub="OVER ($(echo "scale=1;3*$K/$NCPU"|bc)x)"
  echo "=== K=$K gangs  (3K=$((3*K)) threads, $sub) -- per-gang weak/1M ==="
  unload scx_gang >/dev/null 2>&1; unload scx_tgang >/dev/null 2>&1
  run_cell "$K" default   sb_sense
  run_cell "$K" scx_gang  sb_group_plus
  run_cell "$K" scx_tgang sb_group_plus
done
echo "(higher per-gang median = better gang coherence under load)"
