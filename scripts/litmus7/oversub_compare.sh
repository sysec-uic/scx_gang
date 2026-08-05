#!/bin/bash
# Oversubscription, three scheduling mechanisms, bounded & comparable:
#   pin       = default scheduler + static taskset pinning (3 dedicated cores/gang,
#               overlapping once 3K>cores) -- the "pinning" baseline herdtools7's
#               -affinity also represents.
#   scx_gang  = spatial gang reservation.
#   scx_tgang = temporal gang multiplexing.
# Sync held constant (sense_barrier; pin uses sb_sense, gangs use sb_group_plus).
# Each gang gets a wall-clock CAP; a gang that cannot finish 1M iters within the
# cap is "starved" (the failure mode of un-coscheduled spinning under load). We
# report completions/K and per-gang weak/1M (median, floor) over TRIALS.
# Usage:  sudo -v ; TRIALS=5 CAP=15 bash scripts/litmus7/oversub_compare.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${BIN:-$ROOT/bin}"
TRIALS="${TRIALS:-5}"; CAP="${CAP:-15}"
NCPU=$(nproc); STATE=/sys/kernel/sched_ext/state
echo "cpus=$NCPU trials=$TRIALS cap=${CAP}s  (3 threads/gang; oversub when 3K>$NCPU)"
wait_state(){ for _ in $(seq 1 50); do [ "$(cat $STATE)" = "$1" ] && return 0; sleep 0.2; done; return 1; }
load(){ sudo rm -f /sys/fs/bpf/groups 2>/dev/null; sudo "$BIN/$1" >/tmp/$1.log 2>&1 & wait_state enabled; }
unload(){ sudo pkill -INT -f "bin/sc[x]" 2>/dev/null; wait_state disabled; sudo rm -f /sys/fs/bpf/groups 2>/dev/null; }
stats(){ sort -n | awk '{a[n++]=$1;s+=$1} END{if(!n){print "no completions";exit} printf "med=%-7.0f floor=%-7.0f [n=%d]", a[int(n/2)], a[0], n}'; }

# one campaign of K gangs; $1=mode(pin|gang) $2=binary -> prints per-gang weak (completers only)
campaign(){ local K="$1" mode="$2" bin="$3" tmp i c0 c1 c2; tmp=$(mktemp -d); local pids=()
  for i in $(seq 0 $((K-1))); do
    if [ "$mode" = pin ]; then
      c0=$(((3*i)%NCPU)); c1=$(((3*i+1)%NCPU)); c2=$(((3*i+2)%NCPU))
      ( sudo timeout "$CAP" taskset -c "$c0,$c1,$c2" "$BIN/$bin" >"$tmp/$i" 2>/dev/null ) & pids+=($!)
    else
      ( sudo timeout "$CAP" "$BIN/$bin" >"$tmp/$i" 2>/dev/null ) & pids+=($!)
    fi
  done
  for p in "${pids[@]}"; do wait "$p"; done
  for i in $(seq 0 $((K-1))); do v=$(cat "$tmp/$i" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"; done
  rm -rf "$tmp"; }

cell(){ local K="$1" mode="$2" bin="$3" sched="$4" all="" comp=0 exp=$(( $1*TRIALS ))
  [ "$sched" = default ] || { load "$sched" >/dev/null 2>&1 || { echo "  $mode: load fail"; return; }; }
  for _ in $(seq 1 "$TRIALS"); do c="$(campaign "$K" "$mode" "$bin")"; all+="$c"$'\n'; comp=$((comp + $(printf '%s' "$c" | grep -c .))); done
  [ "$sched" = default ] || unload "$sched" >/dev/null 2>&1
  printf "  %-10s completed %3d/%-3d gangs   %s\n" "$mode" "$comp" "$exp" "$(printf '%s' "$all" | stats)"; }

for K in 4 8 16 24 32; do
  sub="under"; [ $((3*K)) -gt "$NCPU" ] && sub="OVER $(echo "scale=1;3*$K/$NCPU"|bc)x"
  echo "=== K=$K (3K=$((3*K)) threads, $sub) ==="
  unload scx_gang >/dev/null 2>&1; unload scx_tgang >/dev/null 2>&1
  cell "$K" pin   sb_sense       default
  cell "$K" gang  sb_group_plus  scx_gang
  cell "$K" tgang sb_group_plus  scx_tgang
done
echo "(pin: completions should collapse once oversubscribed; tgang stays ~100%)"
