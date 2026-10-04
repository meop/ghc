#!/usr/bin/env bash
# Build a GHC that runs on Windows AArch64, from x86_64 Linux: a stage 1 cross
# compiler, then the stage 2 compiler packaged as a target-executable bindist
# (Hadrian's binary-dist-stage3). See BOOTSTRAP.md.
#
# Usage: windows-aarch64/build-bootstrap.sh
#   JOBS     Hadrian parallelism (default 4)
#   FLAVOUR  Hadrian flavour (default quick)
#   CLEAN=1  remove _build first
# Run it under windows-aarch64/run-capped.sh to cap its memory.

set -euo pipefail

cd "$(dirname "$0")/.."
: "${JOBS:=4}"
: "${FLAVOUR:=quick}"
export PATH="$HOME/.ghcup/bin:$PATH"

start=$(date +%s)
stamp() { echo "=== $(date -u +%FT%TZ) +$(( ($(date +%s) - start) / 60 ))m $*"; }

if [[ "${CLEAN:-}" == 1 ]]; then
    stamp clean
    rm -rf _build
fi

stamp boot
./boot

stamp configure
# The cross toolchain variables must reach configure only: Hadrian builds
# itself as a normal Linux program and would otherwise use the cross compiler.
(
    . windows-aarch64/env.sh
    ./configure --target=aarch64-unknown-mingw32 \
        --with-intree-gmp --enable-strict-ghc-toolchain-check
)

stamp "hadrian flavour=$FLAVOUR jobs=$JOBS"
hadrian/build --flavour="$FLAVOUR" --bignum=native --docs=none -j"$JOBS" binary-dist-stage3

stamp done
ls -la _build/bindist/
