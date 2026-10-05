#!/usr/bin/env bash
# Turn the stage 3 bindist directory into a self-contained Windows AArch64
# distribution: bundle llvm-mingw's Windows AArch64 build as mingw/, point the
# target file at it through $tooldir (see Note [tooldir: How GHC finds mingw on
# Windows] in compiler/GHC/SysTools/BaseDir.hs), and pack it as a .tar.gz that
# Windows' built-in tar can extract.
#
# Run after: TARGET=binary-dist-dir-stage3 windows-aarch64/run-capped.sh ...
#
# Environment:
#   BINDIST  bindist directory (default: the only _build/bindist/ghc-*-aarch64-unknown-mingw32)
#   OUT_DIR  where the .tar.gz goes (default: _build/windows-aarch64)
#   CACHE    download cache (default: ~/.cache/ghc-windows-aarch64)
#   LLVM_MINGW_VERSION  defaults to install-toolchain.sh's pin
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
# Same pin as install-toolchain.sh, so the bundled toolchain matches the cross one.
: "${LLVM_MINGW_VERSION:=$(sed -n 's/^: "${LLVM_MINGW_VERSION:=\([0-9]*\)}".*/\1/p' "$here/install-toolchain.sh")}"
: "${LLVM_MINGW_VERSION:?could not read the LLVM_MINGW_VERSION pin from install-toolchain.sh}"

cd "$root"
if [[ -z ${BINDIST:-} ]]; then
  # The newest: an older build's directory stays when the version changes.
  BINDIST=$(ls -td _build/bindist/ghc-*-aarch64-unknown-mingw32 2>/dev/null | head -1)
  [[ -n $BINDIST ]] || { echo "no bindist directory under _build/bindist; set BINDIST" >&2; exit 1; }
  echo "bindist: $BINDIST"
fi
OUT_DIR=${OUT_DIR:-_build/windows-aarch64}
CACHE=${CACHE:-$HOME/.cache/ghc-windows-aarch64}
name=$(basename "$BINDIST")

# The Windows-hosted toolchain: the same release GHC's own CI pins (see the
# hsc2hs note in TODO.md), built to run on Windows AArch64.
zip_name=llvm-mingw-$LLVM_MINGW_VERSION-ucrt-aarch64.zip
mkdir -p "$CACHE"
if [[ ! -f $CACHE/$zip_name ]]; then
  curl -sSfL -o "$CACHE/$zip_name.part" \
    "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$zip_name"
  mv "$CACHE/$zip_name.part" "$CACHE/$zip_name"
fi

stage=$OUT_DIR/stage
rm -rf "$stage"
mkdir -p "$stage"
cp -a "$BINDIST" "$stage/$name"
dist=$stage/$name

# _build keeps the library tree of an earlier version (the version has a date
# in it); the package database only refers to this version's, so drop others.
version=${name#ghc-}; version=${version%-aarch64-unknown-mingw32}
for d in "$dist"/lib/aarch64-windows-ghc-*-inplace; do
  [[ $d == */aarch64-windows-ghc-$version-inplace ]] || { echo "dropping stale $(basename "$d")"; rm -rf "$d"; }
done

unzip -q "$CACHE/$zip_name" -d "$stage"
mv "$stage/${zip_name%.zip}" "$dist/mingw"

# The cross build recorded this machine's llvm-mingw, by absolute path and with
# the target-prefixed tool names. On Windows the same tools are the bundled
# ones under $tooldir/mingw/bin. llvm-mingw's Windows build has no prefixed
# `ld` wrapper, so the -fuse-ld=<path> flag becomes plain lld, as native Windows
# GHC uses.
cross_bin=$(sed -n 's/.*prgPath = *"\([^"]*\)\/aarch64-w64-mingw32-clang".*/\1/p' "$dist/lib/targets/default.target" | head -1)
[[ -n $cross_bin ]] || { echo "could not find the cross toolchain path in default.target" >&2; exit 1; }
sed -i \
  -e "s|-fuse-ld=$cross_bin/aarch64-w64-mingw32-ld|-fuse-ld=lld|g" \
  -e "s|\"$cross_bin/\(aarch64-w64-mingw32-[A-Za-z0-9+_-]*\)\"|\"\$tooldir/mingw/bin/\1.exe\"|g" \
  "$dist/lib/targets/default.target"
if grep -q "$cross_bin" "$dist/lib/targets/default.target"; then
  echo "default.target still refers to $cross_bin:" >&2
  grep -n "$cross_bin" "$dist/lib/targets/default.target" >&2
  exit 1
fi
for tool in $(grep -o '\$tooldir/mingw/bin/[^"]*' "$dist/lib/targets/default.target" | sort -u); do
  [[ -f $dist/${tool#\$tooldir/} ]] || { echo "missing bundled tool: $tool" >&2; exit 1; }
done

# settings names unlit with the cross prefix, but the bindist ships unlit.exe.
sed -i 's|"\$topdir/../bin/aarch64-unknown-mingw32-unlit"|"$topdir/../bin/unlit.exe"|' "$dist/lib/settings"
grep -q '"\$topdir/../bin/unlit.exe"' "$dist/lib/settings" || { echo "unlit setting not rewritten" >&2; exit 1; }

tarball=$OUT_DIR/$name.tar.gz
tar -C "$stage" -czf "$tarball" "$name"
rm -rf "$stage"
echo "$tarball ($(du -h "$tarball" | cut -f1))"
