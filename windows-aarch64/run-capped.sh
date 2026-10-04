#!/usr/bin/env bash
# Run a command in its own systemd user scope with a memory cap, so a large
# build cannot push the rest of the machine into the kernel's out-of-memory
# killer. Above MEMORY_HIGH the kernel throttles and reclaims memory from the
# scope; at MEMORY_MAX only processes inside the scope can be killed.
#
# Usage: windows-aarch64/run-capped.sh <name> <command> [args...]
#   MEMORY_HIGH  throttle point (default 7G)
#   MEMORY_MAX   hard cap (default 8G)
#   LOG_DIR      where <name>-<timestamp>.log is written (default windows-aarch64/logs,
#                outside _build so CLEAN=1 cannot delete a running log)
#
# Example:
#   windows-aarch64/run-capped.sh bootstrap windows-aarch64/build-bootstrap.sh

set -euo pipefail

if [[ $# -lt 2 ]]; then
    sed -n '2,13p' "$0" >&2
    exit 2
fi

name=$1
shift
cd "$(dirname "$0")/.."
: "${MEMORY_HIGH:=7G}"
: "${MEMORY_MAX:=8G}"
: "${LOG_DIR:=windows-aarch64/logs}"
mkdir -p "$LOG_DIR"
log="$LOG_DIR/$name-$(date -u +%Y%m%dT%H%M%SZ).log"
unit="ghc-$name-$(date +%s)"

echo "unit: $unit.scope  log: $log  memory: high=$MEMORY_HIGH max=$MEMORY_MAX"
status=0
systemd-run --user --scope --quiet --unit="$unit" \
    -p MemoryHigh="$MEMORY_HIGH" -p MemoryMax="$MEMORY_MAX" -p MemorySwapMax=0 \
    bash -c '"$@"; s=$?
        cg=$(cut -d: -f3 /proc/self/cgroup)
        echo "memory peak: $(( $(cat "/sys/fs/cgroup$cg/memory.peak") / 1048576 )) MiB"
        exit $s' _ "$@" >"$log" 2>&1 || status=$?
echo "exit $status" | tee -a "$log"
exit "$status"
