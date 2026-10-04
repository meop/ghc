#!/usr/bin/env bash
# Reproduce the stage 2 hsc2hs failure in a Windows AArch64 cross build:
#
#   hsc2hs: Cannot combine instructions: [Quad 408,Long 4,Long 241,Ref ".Ltmp1-.Ltmp0"]
#
# In --cross-compile mode hsc2hs compiles each probe to assembly and parses the
# values after each ___hsc2hs_* label (utils/hsc2hs/src/ATTParser.hs). If clang
# also emits a CodeView .debug$S section, its words (.long 4 = CV signature,
# .long 241 = DEBUG_S_SYMBOLS, .word .Ltmp1-.Ltmp0) follow the last label and
# are read as part of that value.
#
# This compiles one probe left behind by a failed build (hsc2hs --keep-files)
# with different target triples and counts .debug$S sections in the output.
#
# Usage: windows-aarch64/repro-hsc2hs-codeview.sh [probe.c]

set -euo pipefail
cd "$(dirname "$0")/.."

probe=${1:-_build/stage2/libraries/ghc-internal/build/GHC/Internal/RTS/Flags/Test_hsc_test5.c}
cc=${LLVM_MINGW:-$HOME/.local/opt/llvm-mingw}/bin/aarch64-w64-mingw32-clang
out=$(mktemp --suffix=.s)
trap 'rm -f "$out"' EXIT

flags=(
    -Qunused-arguments
    -Irts/include -I_build/stage2/rts/build/include
    -I_build/stage2/libraries/ghc-internal/build
    -I_build/stage2/libraries/ghc-internal/build/include
    -Ilibraries/ghc-internal/include
    -include _build/stage2/libraries/ghc-internal/build/autogen/cabal_macros.h
    -D_WIN32_WINNT=0x06010000 -DBIGNUM_NATIVE
    -Daarch64_HOST_ARCH=1 -Dmingw32_HOST_OS=1 -D__GLASGOW_HASKELL__=1001
)

for variant in \
    "" \
    "--target=aarch64-unknown-windows-gnu" \
    "--target=aarch64-w64-mingw32" \
    "--target=aarch64-w64-windows-gnu" \
    "--target=aarch64-unknown-windows-gnu -g0" \
    "--target=aarch64-unknown-windows-gnu -gno-codeview"
do
    read -r -a extra <<<"$variant"
    rm -f "$out"
    if "$cc" "${extra[@]}" "${flags[@]}" -S -o "$out" "$probe" 2>/dev/null; then
        printf '%-55s .debug$S sections: %s\n' "${variant:-<llvm-mingw default triple>}" "$(grep -c 'debug\$S' "$out" || true)"
    else
        printf '%-55s compile failed\n' "${variant:-<llvm-mingw default triple>}"
    fi
done
