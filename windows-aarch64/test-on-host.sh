#!/usr/bin/env bash
# Copy the packaged distribution (package-bindist.sh) to a Windows AArch64 host
# over SSH and run test-on-host.ps1 there. The host's SSH shell must be
# PowerShell or cmd; the test unpacks into %LOCALAPPDATA% and leaves the
# install there for manual use.
#
# Environment:
#   HOST     SSH host (default: metal)
#   PORT     SSH port (default: 22222; metal forwards it to resin, the ARM64 VM)
#   TARBALL  distribution (default: the only _build/windows-aarch64/ghc-*.tar.gz)
#   LOG_DIR  where the log goes (default: windows-aarch64/logs)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$root"

HOST=${HOST:-metal}
PORT=${PORT:-22222}
LOG_DIR=${LOG_DIR:-$here/logs}
if [[ -z ${TARBALL:-} ]]; then
  shopt -s nullglob
  found=(_build/windows-aarch64/ghc-*-aarch64-unknown-mingw32.tar.gz)
  shopt -u nullglob
  (( ${#found[@]} == 1 )) || { echo "expected one packaged distribution, found ${#found[@]}; set TARBALL" >&2; exit 1; }
  TARBALL=${found[0]}
fi

mkdir -p "$LOG_DIR"
log=$LOG_DIR/test-on-host-$HOST-$(date -u +%Y%m%dT%H%M%SZ).log
ssh_opts=(-o BatchMode=yes -p "$PORT")
scp_opts=(-o BatchMode=yes -q -P "$PORT")

# Paths relative to the remote home directory, which is where scp lands.
remote_dir='AppData/Local/ghc-windows-aarch64-test'
{
  echo "host=$HOST:$PORT tarball=$TARBALL commit=$(git rev-parse --short HEAD)"
  ssh "${ssh_opts[@]}" "$HOST" "New-Item -ItemType Directory -Force \$env:LOCALAPPDATA\\ghc-windows-aarch64-test | Out-Null" </dev/null
  scp "${scp_opts[@]}" "$TARBALL" "$here/test-on-host.ps1" "$HOST:$remote_dir/"
  echo "copied"
  ssh "${ssh_opts[@]}" "$HOST" \
    "pwsh -NoProfile -NonInteractive -File \$env:LOCALAPPDATA\\ghc-windows-aarch64-test\\test-on-host.ps1 -Tarball \$env:LOCALAPPDATA\\ghc-windows-aarch64-test\\$(basename "$TARBALL") -Dest \$env:LOCALAPPDATA\\ghc-windows-aarch64-test\\install" </dev/null
} 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
echo "log: $log"
exit "$status"
