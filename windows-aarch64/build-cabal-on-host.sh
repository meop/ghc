#!/usr/bin/env bash
# Build a native Windows AArch64 cabal.exe on the host, with the GHC that
# test-on-host.sh installed there (run that first). See build-cabal-on-host.ps1.
#
# Environment:
#   HOST           SSH host (default: metal)
#   PORT           SSH port (default: 22222; metal forwards it to resin, the ARM64 VM)
#   CABAL_VERSION  cabal-install release whose x64 build bootstraps (default: 3.18.2.0)
#   BUILD_VERSION  cabal-install version built from Hackage (default: 3.18.1.0;
#                  Hackage can lag the binary releases)
#   JOBS           parallel package builds on the host (default: 2; the VM has 8 GB)
#   LOG_DIR        where the log goes (default: windows-aarch64/logs)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
HOST=${HOST:-metal}
PORT=${PORT:-22222}
CABAL_VERSION=${CABAL_VERSION:-3.18.2.0}
BUILD_VERSION=${BUILD_VERSION:-3.18.1.0}
JOBS=${JOBS:-2}
LOG_DIR=${LOG_DIR:-$here/logs}

zip=cabal-install-$CABAL_VERSION-x86_64-mingw64.zip
sha256=$(curl -sSfL "https://downloads.haskell.org/~cabal/cabal-install-$CABAL_VERSION/SHA256SUMS" | awk -v f="$zip" '$2 == f || $2 == "./"f || $2 == "*"f {print $1}')
[[ -n $sha256 ]] || { echo "no SHA256SUMS entry for $zip" >&2; exit 1; }

mkdir -p "$LOG_DIR"
log=$LOG_DIR/build-cabal-on-host-$HOST-$(date -u +%Y%m%dT%H%M%SZ).log
ssh_opts=(-o BatchMode=yes -p "$PORT")
remote_win='$env:LOCALAPPDATA\ghc-windows-aarch64-test'
# set -e would end the script at a failing run, before the logs are kept.
status=0
{
  echo "host=$HOST:$PORT cabal=$CABAL_VERSION build=$BUILD_VERSION sha256=$sha256 commit=$(git -C "$here" rev-parse --short HEAD)"
  scp -o BatchMode=yes -q -P "$PORT" "$here/build-cabal-on-host.ps1" "$HOST:AppData/Local/ghc-windows-aarch64-test/"
  # test-on-host.ps1 unpacked GHC into install\ghc-*; pick that ghc.exe.
  ssh "${ssh_opts[@]}" "$HOST" \
    "\$ghc = (Get-ChildItem $remote_win\\install -Directory | Select-Object -First 1).FullName + '\\bin\\ghc.exe'; pwsh -NoProfile -NonInteractive -File $remote_win\\build-cabal-on-host.ps1 -Ghc \$ghc -Work $remote_win\\cabal -CabalVersion $CABAL_VERSION -CabalSha256 $sha256 -BuildVersion $BUILD_VERSION -Jobs $JOBS" </dev/null
} 2>&1 | tee "$log" || status=$?
echo "log: $log"
exit "$status"
