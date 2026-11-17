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
#   CROSS_GHC_PKG  the cross ghc-pkg, to rebuild package.cache after the package edits
#                  (default: _build/stage1/bin/aarch64-unknown-mingw32-ghc-pkg)
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

# C++. llvm-mingw's clang++ finds libc++ (its headers, and the library to
# link) through a config file named after the triple the driver normalises the
# target to: aarch64-w64-windows-gnu.cfg, for the aarch64-w64-mingw32 driver
# name. The target file passes --target=aarch64-unknown-windows-gnu, whose
# config file name does not exist, so the driver falls back to libstdc++'s
# search paths, none of which are there: `#include <iostream>` fails. Ask for
# libc++ outright. (The x86_64 bundle sets no -stdlib either; m4/fp_setup_windows_toolchain.m4
# names libc++ as its C++ library, so its MSYS2 clang must default to it.)
cxx_flags='"--target=aarch64-unknown-windows-gnu"'
sed -i "/tgtCxxCompiler/s|prgFlags = \[$cxx_flags\]|prgFlags = [$cxx_flags,\"-stdlib=libc++\"]|" "$dist/lib/targets/default.target"
grep -q 'tgtCxxCompiler.*"-stdlib=libc++"' "$dist/lib/targets/default.target" \
  || { echo "C++ compiler flags not rewritten in default.target" >&2; exit 1; }

# system-cxx-std-lib. The cross configure probed `-lc++ -lc++abi`, which lld
# resolves to llvm-mingw's DLL import libraries: executables would need
# libc++.dll and libunwind.dll at run time, and those live in
# mingw/aarch64-w64-mingw32/bin, which nothing puts on PATH. Link the static
# libraries, as the x86_64 bundle does (CXX_STD_LIB_LIBS=":libc++.a
# :libc++abi.a" in m4/fp_setup_windows_toolchain.m4). llvm-mingw's libc++abi.a
# leaves the unwinder (_Unwind_RaiseException and friends) to libunwind.a.
# GHC reads only package.cache, so the edit needs a recache; the cross
# ghc-pkg does it on the files in place.
pkgdb=$dist/lib/package.conf.d
cxx_conf=$pkgdb/system-cxx-std-lib-1.0.conf
sed -i -E 's/^(extra-libraries(-static)?:) +c\+\+ c\+\+abi *$/\1 :libc++.a :libc++abi.a :libunwind.a/' "$cxx_conf"
[[ $(grep -c '^extra-libraries.*: :libc++.a :libc++abi.a :libunwind.a$' "$cxx_conf") == 2 ]] \
  || { echo "system-cxx-std-lib extra-libraries not rewritten:" >&2; grep -n 'extra-libraries' "$cxx_conf" >&2; exit 1; }
: "${CROSS_GHC_PKG:=$root/_build/stage1/bin/aarch64-unknown-mingw32-ghc-pkg}"
"$CROSS_GHC_PKG" --global-package-db "$pkgdb" recache

# Library docs. When the build made them (build-bootstrap.sh DOCS=no-sphinx),
# the bindist has doc/html/libraries/<pkg>-<version>/<pkg>.haddock beside lib/.
# The package confs still name them as in the build tree, where doc/ is a
# sibling of the stage's lib/: ${pkgroot}/../../doc/... (pkgroot is lib/). In the
# bindist, doc/ is next to lib/, so one level up less. `make install` rewrites
# these paths for its docdir (patchpackageconf in the bindist's Makefile); this
# bindist is used where it is unpacked, so make the same edit for doc/. Without
# it haddock fails on its first dependency ("array.haddock: withBinaryFile: does
# not exist") and the haddock tests fail.
if [[ -d $dist/doc/html/libraries ]]; then
  sed -i 's|${pkgroot}/\.\./\.\./doc/html/libraries/|${pkgroot}/../doc/html/libraries/|' "$pkgdb"/*.conf
  pkgroot_prefix='${pkgroot}/'
  n=0
  for f in $(grep -l '^haddock-interfaces:' "$pkgdb"/*.conf); do
    h=$(grep -A1 '^haddock-interfaces:' "$f" | grep -o '\${pkgroot}/[^ ]*\.haddock' | head -1)
    [[ -n $h && -f $dist/lib/${h#"$pkgroot_prefix"} ]] || { echo "$(basename "$f"): haddock-interfaces does not name a file in the bindist: ${h:-none}" >&2; exit 1; }
    n=$((n + 1))
  done
  echo "docs: haddock-interfaces of $n packages point at doc/html/libraries"
  "$CROSS_GHC_PKG" --global-package-db "$pkgdb" recache
fi

# settings names unlit with the cross prefix, but the bindist ships unlit.exe.
sed -i -e 's|"\$topdir/../bin/aarch64-unknown-mingw32-unlit"|"\$topdir/../bin/unlit.exe"|' -e 's|"\$topdir/../bin/unlit"|"\$topdir/../bin/unlit.exe"|' "$dist/lib/settings"
grep -q '"\$topdir/../bin/unlit.exe"' "$dist/lib/settings" || { echo "unlit setting not rewritten" >&2; exit 1; }

tarball=$OUT_DIR/$name.tar.gz
tar -C "$stage" -czf "$tarball" "$name"
rm -rf "$stage"
echo "$tarball ($(du -h "$tarball" | cut -f1))"
