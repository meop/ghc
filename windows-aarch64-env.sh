# Source before configuring a native Windows AArch64 bootstrap build from
# x86_64 Linux. Mirrors the CI job
# aarch64-linux-deb12-wine-int_native-cross_aarch64-unknown-mingw32-validate,
# with llvm-mingw installed at $LLVM_MINGW instead of /opt/llvm-mingw-linux.
#
# The toolchain variables must reach ./configure only: Hadrian builds itself
# as a normal Linux program, and an exported CC would point it at the cross
# compiler. Source this in a subshell around configure:
#
#   ./boot
#   ( . ./windows-aarch64-env.sh && ./configure --target=aarch64-unknown-mingw32 \
#       --with-intree-gmp --enable-strict-ghc-toolchain-check )
#   PATH="$HOME/.ghcup/bin:$PATH" hadrian/build --flavour=quick --bignum=native \
#       --docs=none -j4 binary-dist-stage3

: "${LLVM_MINGW:=$HOME/.local/opt/llvm-mingw}"
p="$LLVM_MINGW/bin/aarch64-w64-mingw32-"
export PATH="$HOME/.ghcup/bin:$PATH"
export AR="${p}llvm-ar" CC="${p}clang" CXX="${p}clang++" NM="${p}nm"
export OBJCOPY="${p}objcopy" OBJDUMP="${p}objdump" RANLIB="${p}llvm-ranlib"
export SIZE="${p}size" STRINGS="${p}strings" STRIP="${p}strip"
export WindresCmd="${p}windres" LLVMAS="${p}clang" LD="${p}ld"
# Windows targets need the linker merge-objects check disabled.
export MergeObjsCmd=""
# llvm-mingw expects the aarch64-w64-mingw32 triple; point clang at its ld.
export CFLAGS="-fuse-ld=${p}ld --rtlib=compiler-rt"
export CONF_CC_OPTS_STAGE2="$CFLAGS" USER_CONF_CC_OPTS_STAGE2="$CFLAGS"
