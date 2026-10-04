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
- hsc2hs `--cross-compile` breaks with newer llvm-mingw. clang 23 (llvm-mingw
  20260922) always emits a CodeView `.debug$S` record in COFF assembly, even
  with `-g0`, and hsc2hs's `ATTParser` reads its words as part of the last
  `___hsc2hs_*` value ("Cannot combine instructions: [Quad 408,Long 4,Long
  241,Ref \".Ltmp1-.Ltmp0\"]"). clang 19 (llvm-mingw 20250114, GHC CI's pin)
  does not emit it. `repro-hsc2hs-codeview.sh` shows the difference. Fix in
  hsc2hs: stop collecting a value at a section change.
- Hadrian builds stage 2 compilers for cross targets (23c9b6c392, 2023-12), but
  cannot package one as a target-executable bindist: `binary-dist-stage3` needs
  `binary-dist-dir-stage3`, which is commented out in
  `hadrian/src/Rules/BinaryDist.hs` ("Not working yet"), and `targetBindist` is
  not defined. `.gitlab/ci.sh` documents `CROSS_STAGE=3` regardless.

## Progress

- 2026-10-04: `_build/stage2/bin/ghc.exe` built from x86_64 Linux: a 139 MB
  PE32+ ARM64 executable (machine `0xAA64`) importing only Windows system DLLs.
  Two fixes were needed: pin llvm-mingw to GHC CI's 20250114 (see the hsc2hs
  note above), and the Hadrian commit "use the stage's target executable
  suffix for programs".
- 2026-10-04: `binary-dist-dir-stage3` builds
  `_build/bindist/ghc-10.1.20261004-aarch64-unknown-mingw32/` (829 MB): 20
  ARM64 executables in `bin/` and a recached package database (49 packages).
  Needed the Hadrian commit "enable binary-dist-dir-stage3 and recache it with
  a host ghc-pkg".
- 2026-10-04: **milestone 1 done, and GHC runs natively.** `package-bindist.sh`
  bundles llvm-mingw 20250114's Windows AArch64 build as `mingw/`, rewrites the
  target file to `$tooldir/mingw/bin/...` (with `-fuse-ld=lld`, since that
  build has no prefixed `ld`), and fixes the cross-prefixed `unlit` name in
  `settings`. On resin (Windows 11 26H2 ARM64 VM, reached through `metal` port 22222), `test-on-host.sh` passed
  every check: ARM64 `ghc.exe` and output, hello world, `text`/`bytestring`/
  `containers` with `-O`, `-threaded` with `+RTS -N` on 4 cores, and C FFI
  through the bundled clang and lld (log `test-on-host-metal-20261004T204319Z`; logs are named after the SSH host).
- 2026-10-04: **native `cabal.exe` (cabal-install 3.18.1.0, ARM64) built on
  resin** with this GHC in 19 minutes (`build-cabal-on-host.sh`). The x64
  cabal release drove the build under emulation. Blockers on the way:

  | Package | Problem | Windows AArch64 specific | Handling here | Upstream |
  | --- | --- | --- | --- | --- |
  | hsc2hs 0.68.10 (Hackage) | `#error Unknown mingw32 arch` | yes | GHC's `utils/hsc2hs` as a local package | Fixed in hsc2hs's repo ("Add Support for Windows Aarch64", 2025-01) but not released |
  | network 3.2.9.0 | `HsNetDef.h`: `#error Unknown mingw32 arch` | yes | `patches/network-3.2.9.0.patch` (one line) | Not fixed; no issue or PR yet |
  | tar >= 0.6, directory-ospath-streaming | OsPath quasiquotes run Template Haskell, which needs the RTS linker | yes (milestone 3) | `tar < 0.6` | Milestone 3 |
  | (GHC) | When TH needs the linker, GHC prints "PE/PE+ not supported on ARM64" and then crashes with an access violation (exit 11) instead of an error (`repro-dos-crash.ps1`) | yes | — | GHC bug to report with milestone 3 |
  | hashable 1.5.1.0 | imports `GHC.Num.*` without depending on `ghc-bignum` | no (GHC master) | `-package ghc-bignum` | Ecosystem catches up with GHC 10.x |
  | windns 0.1.0.1 | hsc2hs: "cannot encode character" | no (legacy code page over SSH) | `chcp 65001` | — |

- Packaging is a script for now. For upstream, Hadrian should do it: bundle the
  host toolchain into a target bindist and write `$tooldir` paths, as
  `SUBST_TOOLDIR` (`m4/subst_tooldir.m4`) does for native Windows builds, and
  name `unlit` without the cross prefix.

## Milestones

1. **Bootstrap bindist** (see [BOOTSTRAP.md](BOOTSTRAP.md)). On x86_64 Linux, build the `aarch64-unknown-mingw32`
   cross compiler with llvm-mingw, then the stage 2 compiler
   (Hadrian target `stage3:exe:ghc-bin`), which runs on Windows ARM64. Then implement
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

## For you (needs your account)

- [ ] Get the gitlab.haskell.org account verified. New accounts cannot create
      projects, so they cannot fork `ghc/ghc` (the API reports
      `projects_limit: 0`). Open an issue from the "get-verified" template:
      <https://gitlab.haskell.org/ghc/ghc/-/issues/new?description_template=get-verified>.
      It asks for one sentence on why, for example "I want to contribute
      native Windows AArch64 support fixes to Hadrian in ghc/ghc", and a
      checkbox that the instance is only for GHC-related projects. The
      alternative is asking an admin on the
      [mailing list or IRC](https://gitlab.haskell.org/ghc/ghc/-/wikis/mailing-lists-and-irc).
      glab on the Linux host is already logged in (SSH for git, token in the
      keyring), so once verified the fork, the `fork` remote and the push can
      be done from there.
- [ ] Optional: log glab in on resin too
      (`glab auth login --hostname gitlab.haskell.org`), if work there will
      push directly.

## Windows ARM64 host checklist

The ARM64 host is resin, reached as `ssh metal -p 22222` (a port forward on
metal): a Windows 11 26H2 ARM64 VM with 4 CPUs and 8 GB of RAM, code in `~/code`.

- [x] Install the milestone 1 bindist; confirm `ghc --info` reports
      `aarch64-unknown-mingw32` and the binary is native ARM64, not emulated.
      (resin, 2026-10-04, `test-on-host.sh`)
- [x] Compile and run a hello world, a program using `Data.Text` and
      `Data.ByteString`, and a threaded program (`-threaded`, `+RTS -N`).
      (resin, 2026-10-04, `test-on-host.sh`; also C FFI)
- [ ] Build ShellCheck from source with `cabal build` and run its tests.
- [ ] Run the GHC testsuite natively (`hadrian/build test`) from a source
      tree, and record failures that do not occur on x86_64 Windows.
- [ ] After milestone 3: run `ghci`, load a module, and build a Template
      Haskell program.
- [ ] Record each result here with the commit it ran against.
