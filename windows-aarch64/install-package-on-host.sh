#!/usr/bin/env bash
# Build a Hackage package's executables natively on the Windows AArch64 host
# with the native cabal (run build-cabal-on-host.sh first). E.g.:
#   windows-aarch64/install-package-on-host.sh ShellCheck-0.11.0
# Extra arguments go to install-package-on-host.ps1 (e.g. -Jobs 4).
#
# Environment: HOST (default: metal), PORT (default: 22222), LOG_DIR.
set -euo pipefail

package=${1:?usage: install-package-on-host.sh <package-version> [script arguments]}
shift
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/run-ps1-on-host.sh" "$here/install-package-on-host.ps1" -Package "$package" "$@"
