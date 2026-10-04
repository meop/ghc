#!/usr/bin/env bash
# Copy a PowerShell script to the Windows AArch64 host and run it there, e.g.:
#   windows-aarch64/run-ps1-on-host.sh windows-aarch64/repro-dos-crash.ps1
# Extra arguments are passed to the script.
#
# Environment: HOST (default: metal), PORT (default: 22222), LOG_DIR.
set -euo pipefail

script=${1:?usage: run-ps1-on-host.sh <script.ps1> [script arguments]}
shift
here=$(cd "$(dirname "$0")" && pwd)
HOST=${HOST:-metal}
PORT=${PORT:-22222}
LOG_DIR=${LOG_DIR:-$here/logs}
name=$(basename "$script" .ps1)
mkdir -p "$LOG_DIR"
log=$LOG_DIR/$name-$HOST-$(date -u +%Y%m%dT%H%M%SZ).log

remote_rel='AppData/Local/ghc-windows-aarch64-test'
remote_win='$env:LOCALAPPDATA\ghc-windows-aarch64-test'
status=0
{
  echo "host=$HOST:$PORT script=$script args=$* commit=$(git -C "$here" rev-parse --short HEAD)"
  ssh -o BatchMode=yes -p "$PORT" "$HOST" "New-Item -ItemType Directory -Force $remote_win | Out-Null" </dev/null
  scp -o BatchMode=yes -q -P "$PORT" "$script" "$HOST:$remote_rel/"
  ssh -o BatchMode=yes -p "$PORT" "$HOST" "pwsh -NoProfile -NonInteractive -File $remote_win\\$name.ps1 $*" </dev/null
} 2>&1 | tee "$log" || status=$?
echo "log: $log"
exit "$status"
