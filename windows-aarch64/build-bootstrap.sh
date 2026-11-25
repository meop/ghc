#!/usr/bin/env bash
# Build a GHC that runs on Windows AArch64, from x86_64 Linux: a stage 1 cross
# compiler, then the stage 2 compiler, which runs on Windows AArch64.
# See BOOTSTRAP.md.
#
# Hadrian's target-executable bindist (binary-dist-stage3) is not implemented
# yet: its binary-dist-dir-stage3 rule is commented out in
# hadrian/src/Rules/BinaryDist.hs. Until it is, the default target builds the
# stage 2 compiler itself, _build/stage2/bin/ghc.exe. Hadrian's target names are
# shifted by one: stage2:exe:ghc-bin is the stage 1 cross compiler
# (_build/stage1/bin/aarch64-unknown-mingw32-ghc), and stage3:exe:ghc-bin is the
# compiler that runs on Windows AArch64.
#
# Usage: windows-aarch64/build-bootstrap.sh
#   JOBS     Hadrian parallelism (default 4)
#   FLAVOUR  Hadrian flavour, before +native_bignum (default quick)
#   TARGET   Hadrian target (default stage3:exe:ghc-bin)
#   DOCS     Hadrian --docs value (default none). With anything else the bindist
#            gets the .haddock files of the libraries (doc/html/libraries/*), which
#            the haddock tests need. no-sphinx builds only those, with no Sphinx or
#            LaTeX; x86_64 Windows CI passes no-sphinx-pdfs, which adds the user
#            guide and the man page.
#   RESUME=1 skip ./boot and ./configure and keep _build, to add targets (such
#            as docs) to an existing build. Needs the same FLAVOUR as that build.
#   CLEAN=1  remove _build first
# Run it under windows-aarch64/run-capped.sh to cap its memory.

set -euo pipefail

cd "$(dirname "$0")/.."
: "${JOBS:=4}"
: "${FLAVOUR:=quick}"
: "${TARGET:=stage3:exe:ghc-bin}"
: "${DOCS:=none}"
export PATH="$HOME/.ghcup/bin:$PATH"

start=$(date +%s)
stamp() { echo "=== $(date -u +%FT%TZ) +$(( ($(date +%s) - start) / 60 ))m $*"; }

if [[ "${CLEAN:-}" == 1 ]]; then
    stamp clean
    rm -rf _build
fi

# Pin the snapshot date in the version to the GHC master commit this branch
# is based on. Otherwise configure takes the newest commit's date, so a notes
# commit on another day changes the version and forces a full rebuild.
base=$(git merge-base HEAD origin/master 2>/dev/null || git merge-base HEAD master)
date -u -d "@$(git log -1 --format=%ct "$base")" +%Y%m%d > VERSION_DATE
# git reads info/exclude only from the common dir, also in a worktree (where .git is a file and the per-worktree
# git dir has no info/).
exclude="$(git rev-parse --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$exclude")"
grep -qx '/VERSION_DATE' "$exclude" 2>/dev/null || echo '/VERSION_DATE' >> "$exclude"
echo "VERSION_DATE $(cat VERSION_DATE) (from $(git log -1 --format='%h %cs' "$base"))"

if [[ "${RESUME:-}" != 1 ]]; then
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
fi

stamp "hadrian flavour=$FLAVOUR+native_bignum docs=$DOCS jobs=$JOBS target=$TARGET"
hadrian/build --flavour="$FLAVOUR+native_bignum" --docs="$DOCS" -j"$JOBS" "$TARGET"

stamp done
ls -la _build/stage2/bin/ _build/bindist/ 2>/dev/null || true
