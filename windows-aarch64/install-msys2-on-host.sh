#!/usr/bin/env bash
# Install MSYS2 for this work on a Windows host, at <drive>:\msys2\ghc, from a
# pinned base release (see install-msys2-on-host.ps1). E.g.:
#   DRIVE=V HOST=glass.lan PORT=22 windows-aarch64/install-msys2-on-host.sh
#   DRIVE=C windows-aarch64/install-msys2-on-host.sh        # resin, the default host
#
# Environment: HOST (default: metal), PORT (default: 22222), DRIVE (default: C),
#   MSYS2_VERSION (default: 20260927), LOG_DIR.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
HOST=${HOST:-metal}
PORT=${PORT:-22222}
DRIVE=${DRIVE:-C}
MSYS2_VERSION=${MSYS2_VERSION:-20260927}
tag=${MSYS2_VERSION:0:4}-${MSYS2_VERSION:4:2}-${MSYS2_VERSION:6:2}
sha256=$(curl -sSfL "https://github.com/msys2/msys2-installer/releases/download/$tag/msys2-base-x86_64-$MSYS2_VERSION.sfx.exe.sha256" | awk '{print $1}')
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || { echo "could not read the published sha256 for $MSYS2_VERSION" >&2; exit 1; }
HOST=$HOST PORT=$PORT exec "$here/run-ps1-on-host.sh" "$here/install-msys2-on-host.ps1" \
  -Root "$DRIVE:\\msys2\\ghc" -Version "$MSYS2_VERSION" -Sha256 "$sha256"
