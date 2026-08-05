#!/bin/bash
# Adds the MISSING "static pinning" baseline to the oversubscription experiment
# (mirrors scripts/22_oversub.sh methodology exactly: 3 threads/gang, per-gang
# weak/1M pooled over TRIALS, sync = sense_barrier held constant). Each gang's 3
# threads are taskset-pinned to 3 dedicated cores when they fit; once 3K>cores,
# gangs share cores and the OS time-slices the pinned threads independently with
# no gang awareness -- the failure mode that temporal gang scheduling avoids.
#
# Produces the "taskset-pin" row to slot into tab_oversub, next to default/
# scx_gang/scx_tgang (already in results/oversub.txt).
# Usage:  sudo -v ; TRIALS=8 bash scripts/litmus7/oversub_pin.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${BIN:-$ROOT/bin}"
TRIALS="${TRIALS:-8}"
NCPU=$(nproc)
echo "cpus=$NCPU  trials=$TRIALS  iters/run=1,000,000  (3 threads/gang; static taskset pin)"
pergang_stats(){ sort -n | awk '{a[n++]=$1;s+=$1} END{if(!n){print "n/a";exit} printf "med=%-7.0f mean=%-7.0f [%.0f..%.0f]", a[int(n/2)], s/n, a[0], a[n-1]}'; }

# one campaign of K gangs, each pinned to a dedicated (overlapping when 3K>NCPU)
# triple of cores -> prints K per-gang weak counts.
campaign_pin(){ local K="$1" tmp i c0 c1 c2; tmp=$(mktemp -d); local pids=()
  for i in $(seq 0 $((K-1))); do
    c0=$(( (3*i)   % NCPU )); c1=$(( (3*i+1) % NCPU )); c2=$(( (3*i+2) % NCPU ))
    ( sudo taskset -c "$c0,$c1,$c2" "$BIN/sb_sense" >"$tmp/$i" 2>/dev/null ) & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  for i in $(seq 0 $((K-1))); do v=$(cat "$tmp/$i" 2>/dev/null); [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"; done
  rm -rf "$tmp"; }

for K in 4 8 16 24 32; do
  sub="under"; [ $((3*K)) -gt "$NCPU" ] && sub="OVER ($(echo "scale=1;3*$K/$NCPU"|bc)x)"
  all=""
  for _ in $(seq 1 "$TRIALS"); do all+="$(campaign_pin "$K")"$'\n'; done
  printf "K=%-3s (3K=%-3s %-12s)  taskset-pin  %s\n" "$K" "$((3*K))" "$sub" "$(printf '%s' "$all" | pergang_stats)"
done
echo "(compare to default/scx_gang/scx_tgang in oversub.txt; pin should match scx_gang"
echo " while gangs fit (K<=16) then collapse once oversubscribed, unlike scx_tgang)"
