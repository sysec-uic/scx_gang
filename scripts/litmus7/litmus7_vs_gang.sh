#!/bin/bash
# litmus7 (static affinity) vs the paper's gang scheduler, on a NUMA box.
# Tests whether "Pinning Isn't Enough": static affinity should keep up on a
# single test but collapse under oversubscription, where whole-gang temporal
# multiplexing (scx_tgang) holds.
#
# Common metric: weak behaviours per SECOND of wall-clock (per-iteration
# semantics differ between tools, so normalise by time). Under concurrency we
# also report the per-instance floor.
#
# Prereqs on the box:
#   - litmus7 built from source on PATH (see README.md), tests/SB.litmus present
#   - the paper kit built: bin/{scx_gang,scx_tgang,sb_group_plus}
# Usage:  sudo -v ; LIT=~/.local/bin/litmus7 bash scripts/litmus7/litmus7_vs_gang.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIT="${LIT:-$HOME/.local/bin/litmus7}"
BIN="${BIN:-$ROOT/bin}"
TEST="${TEST:-$HERE/SB.litmus}"
SIZE="${SIZE:-1M}"; RUNS="${RUNS:-20}"
STATE=/sys/kernel/sched_ext/state
NCPU=$(nproc)
echo "cpus=$NCPU  litmus7=$LIT  bin=$BIN  size=$SIZE runs=$RUNS"

# ---- helpers -------------------------------------------------------------
# litmus7 -> "weak/s" : Positive / Time, with the BEST fair config (timebase).
lit_rate() {  # extra-args...  -> echoes "weak_per_s positive time"
  local out pos time
  out=$("$LIT" -s "$SIZE" -r "$RUNS" -affinity incr1 -barrier timebase "$@" "$TEST" 2>/dev/null)
  pos=$(echo "$out" | sed -n 's/^Positive: \([0-9]*\).*/\1/p' | tail -1)
  time=$(echo "$out" | sed -n 's/^Time [^ ]* \([0-9.]*\).*/\1/p' | tail -1)
  [ -z "$pos" ] && { echo "0 0 0"; return; }
  awk -v p="$pos" -v t="$time" 'BEGIN{printf "%.0f %d %.2f", (t>0?p/t:0), p, t}'
}

wait_state(){ for _ in $(seq 1 50); do [ "$(cat $STATE 2>/dev/null)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
load_sched(){ sudo rm -f /sys/fs/bpf/groups 2>/dev/null; sudo "$BIN/$1" >/tmp/$1.log 2>&1 & wait_state enabled || { echo "  !! $1 load failed"; return 1; }; }
unload_sched(){ sudo pkill -INT -f "$BIN/$1" 2>/dev/null; wait_state disabled; sudo rm -f /sys/fs/bpf/groups 2>/dev/null; }

# paper harness -> weak/s for ONE instance of $1 (sb_group_plus etc.)
gang_rate_one(){ local bin="$1" s e w; s=$(date +%s.%N); w=$(sudo "$BIN/$bin" 2>/dev/null); e=$(date +%s.%N)
  awk -v w="${w:-0}" -v s="$s" -v e="$e" 'BEGIN{d=e-s; printf "%.0f", (d>0?w/d:0)}'; }

echo
echo "########## 1. SINGLE TEST (fits) — weak/second ##########"
[ -e "$STATE" ] && { unload_sched scx_gang >/dev/null 2>&1; unload_sched scx_tgang >/dev/null 2>&1; }
read r p t < <(lit_rate);            printf "  litmus7 timebase+incr1      %8s weak/s  (pos=%s t=%ss)\n" "$r" "$p" "$t"
read r p t < <(lit_rate -p 0,1);     printf "  litmus7 timebase+pin same   %8s weak/s  (hand-tuned -p 0,1)\n" "$r"
if [ -e "$STATE" ]; then
  load_sched scx_gang  && { printf "  scx_gang (auto NUMA-local)  %8s weak/s\n" "$(gang_rate_one sb_group_plus)"; unload_sched scx_gang; }
fi

echo
echo "########## 2. OVERSUBSCRIPTION sweep — aggregate weak/s and per-instance floor ##########"
# threads/test for SB = 2; scale K so 2K goes from underutilised to ~2x cores.
for K in 1 $((NCPU/4)) $((NCPU/2)) $((NCPU*3/4)) $NCPU $((NCPU*3/2)); do
  [ "$K" -lt 1 ] && continue
  echo "--- K=$K concurrent instances (2K=$((2*K)) threads / $NCPU cores) ---"
  # litmus7: K independent pinned processes (static affinity, the 'pinning' baseline)
  tmp=$(mktemp -d); s=$(date +%s.%N); pids=()
  for i in $(seq 1 "$K"); do ("$LIT" -s "$SIZE" -r "$RUNS" -affinity incr1 -barrier timebase "$TEST" 2>/dev/null \
       | sed -n 's/^Positive: \([0-9]*\).*/\1/p' | tail -1 > "$tmp/$i") & pids+=($!); done
  for pp in "${pids[@]}"; do wait "$pp"; done
  e=$(date +%s.%N); tot=0; min=
  for i in $(seq 1 "$K"); do v=$(cat "$tmp/$i" 2>/dev/null); v=${v:-0}; tot=$((tot+v)); { [ -z "$min" ] || [ "$v" -lt "$min" ]; } && min=$v; done
  awk -v tot="$tot" -v s="$s" -v e="$e" -v min="${min:-0}" 'BEGIN{d=e-s; printf "  litmus7 (static affinity):  agg %.0f weak/s   per-inst floor %d weak/inst\n",(d>0?tot/d:0),min}'
  rm -rf "$tmp"
  # scx_tgang: K gangs, whole-gang time multiplexing
  if [ -e "$STATE" ]; then
    load_sched scx_tgang || continue
    tmp=$(mktemp -d); s=$(date +%s.%N); pids=()
    for i in $(seq 1 "$K"); do (sudo "$BIN/sb_group_plus" 2>/dev/null > "$tmp/$i") & pids+=($!); done
    for pp in "${pids[@]}"; do wait "$pp"; done
    e=$(date +%s.%N); tot=0; min=
    for i in $(seq 1 "$K"); do v=$(cat "$tmp/$i" 2>/dev/null); v=${v:-0}; tot=$((tot+v)); { [ -z "$min" ] || [ "$v" -lt "$min" ]; } && min=$v; done
    awk -v tot="$tot" -v s="$s" -v e="$e" -v min="${min:-0}" 'BEGIN{d=e-s; printf "  scx_tgang (temporal gang):  agg %.0f weak/s   per-inst floor %d weak/inst\n",(d>0?tot/d:0),min}'
    rm -rf "$tmp"; unload_sched scx_tgang
  fi
done
echo
echo "Expectation: litmus7 ~= scx_gang at K=1 (pinning enough); litmus7's floor"
echo "collapses as 2K exceeds $NCPU while scx_tgang holds (pinning NOT enough)."
