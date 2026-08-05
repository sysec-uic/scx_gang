#!/bin/bash
# Paper-methodology oversubscription re-run (mirrors scripts/22_oversub.sh):
# per-gang weak/1M over TRIALS, fixed 1M-iteration campaign, sync held constant
# (sense_barrier). Adds a static taskset-pin baseline, and re-validates whether
# scx_tgang really beats scx_gang under oversubscription (paper Fig 4).
#
# NO cap that would distort time multiplexing: gang/tgang/default get a GENEROUS
# 60s hang-guard only -- fair time-slicing finishes a gang's 1M iters in ~1s even
# at 2x, so a 60s timeout means GENUINE starvation, not normal multiplexing. The
# pin baseline (which livelocks under load) gets a shorter PINCAP since its
# failure is already established; we just record what completes.
#
# Reports per-gang weak/1M (median, mean, [min..max]) AND completions/total.
# Usage:  sudo -v ; TRIALS=8 CAP=60 PINCAP=20 bash scripts/litmus7/oversub_clean.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${BIN:-$ROOT/bin}"
TRIALS="${TRIALS:-8}"; CAP="${CAP:-60}"; PINCAP="${PINCAP:-20}"
NCPU=$(nproc); STATE=/sys/kernel/sched_ext/state
echo "cpus=$NCPU trials=$TRIALS guard=${CAP}s pincap=${PINCAP}s (3 threads/gang; oversub when 3K>$NCPU)"
wait_state(){ for _ in $(seq 1 60); do [ "$(cat $STATE)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
load(){ sudo rm -f /sys/fs/bpf/groups 2>/dev/null; sudo "$BIN/$1" >/tmp/$1.log 2>&1 & wait_state enabled; }
unload(){ sudo pkill -INT -f "bin/sc[x]" 2>/dev/null; wait_state disabled; sudo rm -f /sys/fs/bpf/groups 2>/dev/null; }
stats(){ sort -n | awk '{a[n++]=$1;s+=$1} END{if(!n){print "no completions";exit} printf "med=%-7.0f mean=%-7.0f [%.0f..%.0f]", a[int(n/2)],s/n,a[0],a[n-1]}'; }

# K mode bin cap -> per-gang weak (completers, one per line)
campaign(){ local K="$1" mode="$2" bin="$3" cap="$4" tmp i c0 c1 c2; tmp=$(mktemp -d); local pids=()
  for i in $(seq 0 $((K-1))); do
    if [ "$mode" = pin ]; then
      c0=$(((3*i)%NCPU)); c1=$(((3*i+1)%NCPU)); c2=$(((3*i+2)%NCPU))
      ( sudo timeout "$cap" taskset -c "$c0,$c1,$c2" "$BIN/$bin" >"$tmp/$i" 2>/dev/null ) & pids+=($!)
    else
      ( sudo timeout "$cap" "$BIN/$bin" >"$tmp/$i" 2>/dev/null ) & pids+=($!)
    fi
  done
  for p in "${pids[@]}"; do wait "$p"; done
  for i in $(seq 0 $((K-1))); do v=$(cat "$tmp/$i" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"; done
  rm -rf "$tmp"; }

cell(){ local K="$1" mode="$2" bin="$3" sched="$4" cap="$5" all="" comp=0 exp=$((K*TRIALS))
  [ "$sched" = default ] || { load "$sched" >/dev/null 2>&1 || { printf "  %-9s LOAD FAIL\n" "$mode"; return; }; }
  for _ in $(seq 1 "$TRIALS"); do c="$(campaign "$K" "$mode" "$bin" "$cap")"; all+="$c"$'\n'; comp=$((comp+$(printf '%s' "$c"|grep -c .))); done
  [ "$sched" = default ] || unload "$sched" >/dev/null 2>&1
  printf "  %-9s %4d/%-4d done  %s\n" "$mode" "$comp" "$exp" "$(printf '%s' "$all"|stats)"; }

for K in 4 8 16 24 32; do
  sub="under"; [ $((3*K)) -gt "$NCPU" ] && sub="OVER $(echo "scale=1;3*$K/$NCPU"|bc)x"
  echo "=== K=$K (3K=$((3*K)) threads, $sub) -- per-gang weak/1M ==="
  unload scx_gang >/dev/null 2>&1; unload scx_tgang >/dev/null 2>&1
  cell "$K" default sb_sense      default   "$CAP"
  cell "$K" pin     sb_sense      default   "$PINCAP"
  cell "$K" gang    sb_group_plus scx_gang  "$CAP"
  cell "$K" tgang   sb_group_plus scx_tgang "$CAP"
done
echo "(validates paper Fig 4: does tgang completion/weak stay high at K=24,32 uncapped?)"
