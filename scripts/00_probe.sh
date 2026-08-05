#!/bin/bash
# Probe a candidate NUMA box for everything the experiment needs.
# Run as a normal user (it will note where sudo is required). Read-only.
echo "==================== HOST ===================="
hostname; uname -r; echo

echo "==================== CPU / NUMA TOPOLOGY ===================="
lscpu | grep -iE "^Model name|^CPU\(s\)|^Socket|^Core|^Thread|NUMA node"
echo "--- numactl ---"
if command -v numactl >/dev/null; then numactl --hardware | grep -E "available|node [0-9]+ cpus"; else echo "numactl: MISSING (apt install numactl)"; fi
echo

echo "==================== sched_ext SUPPORT ===================="
if [ -e /sys/kernel/sched_ext/state ]; then
  echo "sched_ext state: $(cat /sys/kernel/sched_ext/state)   (disabled = available, no scheduler loaded)"
else
  echo "sched_ext: NOT PRESENT — kernel needs CONFIG_SCHED_CLASS_EXT=y (>= 6.12, ideally >= 6.13 for NUMA kfuncs)"
fi
zcat /proc/config.gz 2>/dev/null | grep -E "SCHED_CLASS_EXT|DEBUG_INFO_BTF" || \
  grep -E "SCHED_CLASS_EXT|DEBUG_INFO_BTF" /boot/config-$(uname -r) 2>/dev/null || echo "(kernel config not readable; check BTF below)"
echo "BTF available: $([ -e /sys/kernel/btf/vmlinux ] && echo YES || echo NO  '(need CONFIG_DEBUG_INFO_BTF=y)')"
echo

echo "==================== TOOLCHAIN ===================="
for t in clang bpftool gcc g++ make git; do
  if command -v $t >/dev/null; then printf "%-9s %s\n" "$t:" "$($t --version 2>&1 | head -1)"; else printf "%-9s MISSING\n" "$t:"; fi
done
echo -n "libbpf-dev headers: "; [ -e /usr/include/bpf/bpf.h ] && echo "present" || echo "MISSING (apt install libbpf-dev)"
echo -n "libbpf runtime:     "; ldconfig -p 2>/dev/null | grep -q libbpf && echo "present" || echo "MISSING"
echo
echo "==================== SUGGESTED SETUP (Debian/Ubuntu) ===================="
echo "  sudo apt install -y clang llvm libbpf-dev libelf-dev zlib1g-dev libzstd-dev \\"
echo "                      linux-tools-common linux-tools-\$(uname -r) build-essential numactl git"
echo "  # scx headers (matching your kernel). Pick a release tag near your kernel:"
echo "  git clone https://github.com/sched-ext/scx ~/scx_src"
echo "  # then run: SCX_DIR=~/scx_src bash scripts/10_build.sh"
