# Native Windows AArch64 GHC

Fork-only working folder for building and validating a GHC that runs natively
on Windows on Arm (`aarch64-unknown-mingw32`). Tracks
[#25974](https://gitlab.haskell.org/ghc/ghc/-/work_items/25974). It is not
meant to be merged: changes for review go to merge requests against `ghc/ghc`.

## Contents

| File | Purpose |
| --- | --- |
| [TODO.md](TODO.md) | Where things stand, the milestones, and the checklist for a Windows AArch64 host |
| [BOOTSTRAP.md](BOOTSTRAP.md) | How the stages produce a Windows AArch64 GHC without one to start from, where to build it, and build times |
| [install-toolchain.sh](install-toolchain.sh) | Installs a bootstrap GHC with cabal, alex, and happy (ghcup, `~/.ghcup`) and llvm-mingw pinned to GHC CI's version (`~/.local/opt/llvm-mingw`), per-user |
| [build-bootstrap.sh](build-bootstrap.sh) | Builds the stage 1 cross compiler, then the stage 2 compiler that runs on Windows AArch64 |
| [run-capped.sh](run-capped.sh) | Runs a step in a systemd user scope with a memory cap, logging timing and peak memory |
| [repro-hsc2hs-codeview.sh](repro-hsc2hs-codeview.sh) | Shows that newer clang emits the CodeView record that breaks hsc2hs's cross mode |
| [package-bindist.sh](package-bindist.sh) | Bundles llvm-mingw's Windows AArch64 build as `mingw/`, points the target file at it through `$tooldir`, and packs a `.tar.gz` |
| [test-on-host.sh](test-on-host.sh), [test-on-host.ps1](test-on-host.ps1) | Copies the package to a Windows AArch64 host over SSH and checks that GHC runs and builds working programs there |
| [build-cabal-on-host.sh](build-cabal-on-host.sh), [build-cabal-on-host.ps1](build-cabal-on-host.ps1) | On the host, builds a native AArch64 `cabal.exe` with the installed GHC (the official x64 cabal drives the first build under emulation), then has it rebuild itself |
| [env.sh](env.sh) | The cross toolchain variables, mirroring GHC's Windows AArch64 CI job; applied to `./configure` only |

## Building the bootstrap bindist

On x86_64 Linux, from the repository root:

```sh
windows-aarch64/install-toolchain.sh
windows-aarch64/run-capped.sh bootstrap windows-aarch64/build-bootstrap.sh
```

The stage 2 compiler lands in `_build/stage2/bin/ghc.exe`, and the log, with
timing stamps and peak memory, in `windows-aarch64/logs/bootstrap-<timestamp>.log` (ignored by git).
Hadrian cannot package it as a bindist yet; see milestone 1 in
[TODO.md](TODO.md#milestones).

| Variable | Default | Effect |
| --- | --- | --- |
| `JOBS` | `4` | Hadrian parallelism |
| `FLAVOUR` | `quick` | Hadrian flavour; `+native_bignum` is appended |
| `TARGET` | `stage3:exe:ghc-bin` | Hadrian target. Names are shifted by one stage: `stage2:exe:ghc-bin` is the stage 1 cross compiler. `binary-dist-dir-stage3` lays out the Windows AArch64 distribution in `_build/bindist/` |
| `CLEAN` | unset | `1` removes `_build` first |
| `MEMORY_HIGH` | `7G` | Memory level at which the kernel throttles the build |
| `MEMORY_MAX` | `8G` | Hard memory cap; only the build's own processes can be killed |
| `LOG_DIR` | `windows-aarch64/logs` | Where logs are written; outside `_build` so `CLEAN=1` cannot delete them |

## Packaging and testing on Windows AArch64

```sh
TARGET=binary-dist-dir-stage3 windows-aarch64/run-capped.sh bootstrap-bindist windows-aarch64/build-bootstrap.sh
windows-aarch64/package-bindist.sh   # -> _build/windows-aarch64/ghc-*-aarch64-unknown-mingw32.tar.gz
windows-aarch64/test-on-host.sh      # HOST=metal PORT=22222 by default: resin, through metal's port forward
```

`test-on-host.sh` copies the package and `test-on-host.ps1` to the host, unpacks
it under `%LOCALAPPDATA%\ghc-windows-aarch64-test`, and checks: `ghc.exe` and
the programs it builds are ARM64; `ghc --info` reports the target; `ghc-pkg
check`; hello world; `text`, `bytestring` and `containers` with `-O`; a
`-threaded` program with `+RTS -N`; and a C FFI call. The log goes to
`windows-aarch64/logs/`. The install stays on the host for manual use.

Builds are also published as releases of
[meop/ghc-windows-aarch64](https://github.com/meop/ghc-windows-aarch64), whose
`test-ghc.yml` runs the same checks (`test-on-host.ps1`, copied there as
`scripts/test-ghc.ps1`) on GitHub's `windows-11-arm` runners; the first,
`ghc-10.1.20261004-55ec2d5e8d`, passed all of them there. Prefer that over the
SSH host for repeatable checks.

The rest of the checklist is in [TODO.md](TODO.md#windows-arm64-host-checklist);
record each result there with the commit it ran against.
