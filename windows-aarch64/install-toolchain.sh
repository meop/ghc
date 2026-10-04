#!/usr/bin/env bash
# Install the x86_64 Linux toolchain for building a Windows AArch64 GHC:
# a bootstrap GHC with cabal, alex, and happy (via ghcup, into ~/.ghcup), and
# the llvm-mingw cross toolchain (into ~/.local/opt/llvm-mingw).
# Everything is per-user; nothing is installed system-wide.
#
# Usage: windows-aarch64/install-toolchain.sh
# Override versions with GHC_VERSION, LLVM_MINGW_VERSION, LLVM_MINGW_FLAVOUR.

set -euo pipefail

: "${GHC_VERSION:=9.10}"                # configure.ac: MinBootGhcVersion
: "${LLVM_MINGW_VERSION:=20260922}"     # github.com/mstorsjo/llvm-mingw releases
: "${LLVM_MINGW_FLAVOUR:=ucrt}"         # GHC's Windows toolchain targets UCRT
: "${LLVM_MINGW_PREFIX:=$HOME/.local/opt}"

ghcup_bin="$HOME/.ghcup/bin"
mkdir -p "$ghcup_bin"
if [[ ! -x "$ghcup_bin/ghcup" ]]; then
    curl -fsSL https://downloads.haskell.org/~ghcup/x86_64-linux-ghcup -o "$ghcup_bin/ghcup"
    chmod +x "$ghcup_bin/ghcup"
fi
export PATH="$ghcup_bin:$PATH"

ghcup install ghc "$GHC_VERSION" --set
ghcup install cabal recommended --set
cabal update
cabal install alex happy --overwrite-policy=always --installdir "$ghcup_bin"

name="llvm-mingw-$LLVM_MINGW_VERSION-$LLVM_MINGW_FLAVOUR-ubuntu-22.04-x86_64"
mkdir -p "$LLVM_MINGW_PREFIX"
if [[ ! -d "$LLVM_MINGW_PREFIX/$name" ]]; then
    curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$name.tar.xz" \
        | tar -xJ -C "$LLVM_MINGW_PREFIX"
fi
ln -sfn "$name" "$LLVM_MINGW_PREFIX/llvm-mingw"

ghc --version
cabal --version | head -1
alex --version
happy --version | head -1
"$LLVM_MINGW_PREFIX/llvm-mingw/bin/aarch64-w64-mingw32-clang" --version | head -1
