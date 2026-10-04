#!/usr/bin/env bash
# Build a GHC that runs on Windows AArch64, from x86_64 Linux: a stage 1 cross
# compiler, then the stage 2 compiler, which runs on Windows AArch64.
# See BOOTSTRAP.md.
#
# Hadrian's target-executable bindist (binary-dist-stage3) is not implemented
# yet: its binary-dist-dir-stage3 rule is commented out in
# hadrian/src/Rules/BinaryDist.hs. Until it is, the default target builds the
# stage 2 compiler itself, _build/stage2/bin/ghc.exe.
#
# Usage: windows-aarch64/build-bootstrap.sh
#   JOBS     Hadrian parallelism (default 4)
#   FLAVOUR  Hadrian flavour, before +native_bignum (default quick)
#   TARGET   Hadrian target (default stage2:exe:ghc-bin)
#   CLEAN=1  remove _build first
# Run it under windows-aarch64/run-capped.sh to cap its memory.

set -euo pipefail

cd "$(dirname "$0")/.."
: "${JOBS:=4}"
: "${FLAVOUR:=quick}"
: "${TARGET:=stage2:exe:ghc-bin}"
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

stamp "hadrian flavour=$FLAVOUR+native_bignum jobs=$JOBS target=$TARGET"
hadrian/build --flavour="$FLAVOUR+native_bignum" --docs=none -j"$JOBS" "$TARGET"

stamp done
ls -la _build/stage2/bin/ _build/bindist/ 2>/dev/null || true
