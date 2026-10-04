#!/usr/bin/env bash
# Run a cabal command on the Windows AArch64 host, in the project that
# build-cabal-on-host.sh set up, with the installed GHC. For looking into a
# failing package, e.g.:
#   windows-aarch64/cabal-on-host.sh build directory-ospath-streaming -v2
# Uses the native cabal once one exists, else the emulated x64 one.
#
# Environment: HOST (default: metal), PORT (default: 22222), LOG_DIR.
set -euo pipefail

(( $# )) || { echo "usage: cabal-on-host.sh <cabal arguments>" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
HOST=${HOST:-metal}
PORT=${PORT:-22222}
LOG_DIR=${LOG_DIR:-$here/logs}
mkdir -p "$LOG_DIR"
log=$LOG_DIR/cabal-on-host-$HOST-$(date -u +%Y%m%dT%H%M%SZ).log

# Quote each argument for PowerShell.
args=''
for a in "$@"; do args+=" '${a//\'/\'\'}'"; done

# Sent as -EncodedCommand: the host's SSH shell may be a wrapper (such as a
# .bat passing %*) that would split a multi-line command.
script=$(cat <<PS
\$ProgressPreference = 'SilentlyContinue'
chcp.com 65001 | Out-Null  # see build-cabal-on-host.ps1
\$root = Join-Path \$env:LOCALAPPDATA 'ghc-windows-aarch64-test'
\$work = Join-Path \$root 'cabal'
\$env:CABAL_DIR = Join-Path \$work 'cabal-dir'
\$gitSh = Join-Path \$env:ProgramFiles 'Git\\usr\\bin'
if (Test-Path \$gitSh) { \$env:PATH = "\$env:PATH;\$gitSh" }
\$ghc = (Get-ChildItem (Join-Path \$root 'install') -Directory | Select-Object -First 1).FullName + '\\bin\\ghc.exe'
\$cabal = Join-Path \$work 'bin\\cabal.exe'
if (-not (Test-Path \$cabal)) { \$cabal = Join-Path \$work 'x64\\cabal.exe' }
Set-Location (Join-Path \$work 'project')
& \$cabal $args --with-compiler=\$ghc 2>&1 | ForEach-Object { "\$_" }
exit \$LASTEXITCODE
PS
)
encoded=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
status=0
{
  echo "host=$HOST:$PORT cabal$args"
  ssh -o BatchMode=yes -p "$PORT" "$HOST" "pwsh -NoProfile -NonInteractive -EncodedCommand $encoded" </dev/null
} 2>&1 | tee "$log" || status=$?
echo "log: $log"
exit "$status"
