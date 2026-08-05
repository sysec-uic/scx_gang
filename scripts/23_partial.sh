#!/bin/bash
# Direct partial-activation measurement using scx_tgang's stats counter.
# partial/activations = fraction of activation passes that placed >=1 member but
# ran out of idle CPUs before the whole queued front-gang fit. Quantifies how
# atomic gang activation actually is as oversubscription grows.
# Usage:  sudo -v ; TRIALS=5 bash scripts/23_partial.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BIN="$ROOT/bin"
STATE=/sys/kernel/sched_ext/state
TRIALS="${TRIALS:-5}"
NCPU=$(nproc)
wait_state(){ for _ in $(seq 1 50); do [ "$(cat $STATE)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
load(){ sudo rm -f /sys/fs/bpf/groups 2>/dev/null; sudo "$BIN/scx_tgang" >/tmp/tg.log 2>&1 & wait_state enabled; }
unload(){ sudo pkill -INT -f "$BIN/scx_tgang" 2>/dev/null; wait_state disabled; sudo rm -f /sys/fs/bpf/groups 2>/dev/null; }
campaign(){ local K="$1"; local pids=()
  for i in $(seq 1 "$K"); do ( sudo "$BIN/sb_group_plus" >/dev/null 2>&1 ) & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p"; done; }
last(){ grep -oP "$1=\K[0-9]+" /tmp/tg.log | tail -1; }

echo "cpus=$NCPU  trials=$TRIALS  (3 threads/gang; oversub when 3K>$NCPU)"
echo "K  threads  sub    activations  partial   partial%"
for K in 4 8 16 20 24 32; do
  thr=$((3*K)); s=$([ $thr -gt $NCPU ] && echo OVER || echo fits)
  A=0; PA=0
  for _ in $(seq 1 "$TRIALS"); do
    unload >/dev/null 2>&1; : > /tmp/tg.log; load >/dev/null 2>&1
    a0=$(last activations); q0=$(last partial); a0=${a0:-0}; q0=${q0:-0}
    campaign "$K"; sleep 1.2
    a1=$(last activations); q1=$(last partial); a1=${a1:-0}; q1=${q1:-0}
    A=$((A + a1 - a0)); PA=$((PA + q1 - q0))
    unload >/dev/null 2>&1
  done
  awk -v K="$K" -v thr="$thr" -v s="$s" -v A="$A" -v PA="$PA" \
    'BEGIN{ printf "%-2d %-7d  %-5s  %-11d  %-8d  %.2f%%\n", K, thr, s, A, PA, (A? 100.0*PA/A : 0) }'
done
