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
| [install-toolchain.sh](install-toolchain.sh) | Installs a bootstrap GHC with cabal, alex, and happy (ghcup, `~/.ghcup`) and llvm-mingw (`~/.local/opt/llvm-mingw`), per-user |
| [build-bootstrap.sh](build-bootstrap.sh) | Builds the stage 1 cross compiler, then the stage 2 compiler that runs on Windows AArch64 |
| [run-capped.sh](run-capped.sh) | Runs a step in a systemd user scope with a memory cap, logging timing and peak memory |
| [env.sh](env.sh) | The cross toolchain variables, mirroring GHC's Windows AArch64 CI job; applied to `./configure` only |

## Building the bootstrap bindist

On x86_64 Linux, from the repository root:

```sh
windows-aarch64/install-toolchain.sh
windows-aarch64/run-capped.sh bootstrap windows-aarch64/build-bootstrap.sh
```

The stage 2 compiler lands in `_build/stage2/bin/ghc.exe`, and the log, with
timing stamps and peak memory, in `_build/logs/bootstrap-<timestamp>.log`.
Hadrian cannot package it as a bindist yet; see milestone 1 in
[TODO.md](TODO.md#milestones).

| Variable | Default | Effect |
| --- | --- | --- |
| `JOBS` | `4` | Hadrian parallelism |
| `FLAVOUR` | `quick` | Hadrian flavour; `+native_bignum` is appended |
| `TARGET` | `stage3:exe:ghc-bin` | Hadrian target. Names are shifted by one stage: `stage2:exe:ghc-bin` is the stage 1 cross compiler |
| `CLEAN` | unset | `1` removes `_build` first |
| `MEMORY_HIGH` | `7G` | Memory level at which the kernel throttles the build |
| `MEMORY_MAX` | `8G` | Hard memory cap; only the build's own processes can be killed |
| `LOG_DIR` | `_build/logs` | Where logs are written |

## Validating on Windows AArch64

Copy the bindist to a Windows AArch64 machine and work through the checklist in
[TODO.md](TODO.md#windows-arm64-host-checklist), recording each result there
with the commit it ran against.
