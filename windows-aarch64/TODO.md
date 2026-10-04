# Native Windows AArch64 GHC

Goal: a GHC that runs natively on Windows on Arm (`aarch64-unknown-mingw32`),
shipped as a release bindist, so projects can build Windows ARM64 binaries on
`windows-11-arm` runners without a cross toolchain. Tracks
[#25974](https://gitlab.haskell.org/ghc/ghc/-/work_items/25974).

## Where things stand (master, 2026-10-02)

- Cross-compiling to `aarch64-unknown-mingw32` works (#24603, !13856). CI
  validates it from AArch64 Linux with llvm-mingw, running the testsuite under
  an ARM64 Wine (`aarch64-linux-deb12-wine-int_native-cross_aarch64-unknown-mingw32-validate`
  in `.gitlab/jobs.yaml`).
- !13856 built GHC natively on Windows 11 ARM64, but needed a GHC that already
  ran there plus workarounds: LLVM backend, tables-next-to-code disabled,
  `-ffixed-x18` for the RTS, large address space disabled, native bignum.
- Tables-next-to-code is hard-disabled for this target in
  `m4/ghc_tables_next_to_code.m4` (#25979; draft !15346).
- The RTS linker cannot load ARM64 COFF objects: the `IMAGE_REL_ARM64_*` case in
  `rts/linker/PEi386.c` is a stub that fails. GHCi, Template Haskell, and
  dynamic code loading therefore do not work natively (#26760).
- Split sections are broken for this target (#26763).
- `platformCConvNeedsExtension` needs Windows ARM64 handling (#27684).
- Hadrian builds stage 2 compilers for cross targets (23c9b6c392, 2023-12), but
  cannot package one as a target-executable bindist: `binary-dist-stage3` needs
  `binary-dist-dir-stage3`, which is commented out in
  `hadrian/src/Rules/BinaryDist.hs` ("Not working yet"), and `targetBindist` is
  not defined. `.gitlab/ci.sh` documents `CROSS_STAGE=3` regardless.

## Milestones

1. **Bootstrap bindist** (see [BOOTSTRAP.md](BOOTSTRAP.md)). On x86_64 Linux, build the `aarch64-unknown-mingw32`
   cross compiler with llvm-mingw, then the stage 2 compiler
   (`stage2:exe:ghc-bin`), which runs on Windows ARM64. Then implement
   `binary-dist-dir-stage3` in Hadrian (a `targetBindist`: the stage 2
   compiler with target libraries) so it ships as a bindist.
2. **Validate natively** (Windows ARM64 host): see below.
3. **RTS linker.** Implement ARM64 COFF relocations in `rts/linker/PEi386.c`
   (ADDR32/64, ADDR32NB, BRANCH26, PAGEBASE_REL21, PAGEOFFSET_12A/12L,
   SECREL, REL32), following the ELF AArch64 relocations in
   `rts/linker/elf_reloc_aarch64.c`, plus jump islands for out-of-range
   branches. Validate with GHCi and a Template Haskell program natively.
4. **Remove workarounds** one at a time, each validated natively:
   tables-next-to-code, `-ffixed-x18`, large address space, split sections,
   the C calling-convention fix.
5. **CI and release.** Add a `CROSS_STAGE=3` job for this target so a release
   bindist exists for ghcup, then open merge requests and link #25974.

## Windows ARM64 host checklist

- [ ] Install the milestone 1 bindist; confirm `ghc --info` reports
      `aarch64-unknown-mingw32` and the binary is native ARM64, not emulated.
- [ ] Compile and run a hello world, a program using `Data.Text` and
      `Data.ByteString`, and a threaded program (`-threaded`, `+RTS -N`).
- [ ] Build ShellCheck from source with `cabal build` and run its tests.
- [ ] Run the GHC testsuite natively (`hadrian/build test`) from a source
      tree, and record failures that do not occur on x86_64 Windows.
- [ ] After milestone 3: run `ghci`, load a module, and build a Template
      Haskell program.
- [ ] Record each result here with the commit it ran against.
