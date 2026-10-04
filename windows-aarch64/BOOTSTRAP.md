# Bootstrapping GHC for Windows AArch64

How a native Windows AArch64 GHC is produced when no GHC yet runs there, and
where to build it. [README.md](README.md) covers the scripts; the plan and
validation checklist are in [TODO.md](TODO.md).

## Stages

Each stage is built by the one before it.

| Stage | Windows x64 (how GHC releases are built today) | Windows AArch64 (this work) |
| --- | --- | --- |
| **Stage 0**: an existing GHC on the build machine | A Windows x64 GHC (from ghcup), running natively on Windows x64 | A Linux x64 GHC (9.10 or later) |
| **Stage 1**: built by stage 0 | Runs on Windows x64 and produces Windows x64 programs | A cross compiler: runs on Linux x64 and produces Windows AArch64 programs |
| **Stage 2**: built by stage 1 | Runs on Windows x64; what releases ship | Runs on Windows AArch64. Built on Linux and never run there. Hadrian target `binary-dist-stage3` (`CROSS_STAGE=3` in `.gitlab/ci.sh`) |

GHC's Windows x64 releases are not cross-compiled: CI builds them natively on
Windows (MSYS2 `CLANG64`) from an existing Windows x64 GHC. Windows AArch64 has
no existing GHC, so the only way in is cross-compiling from another platform.

The stage 2 Windows AArch64 GHC then becomes stage 0 for native builds on
Windows AArch64, which is how !13856 was built. That avoids running an x64 GHC
under emulation, which !13856 notes is very slow.

Building does not need Windows: llvm-mingw produces the Windows AArch64 code on
Linux, as GHC's own CI does. Windows AArch64 is needed only to run and test the
result.

## Where to build

| Option | Build | Test on real Windows AArch64 | Notes |
| --- | --- | --- | --- |
| Local x86_64 Linux | Hours of local CPU | Manual: copy the bindist to a Windows AArch64 machine | Simplest to start, and gives a measured build time. |
| GitHub Actions on a fork of the `ghc/ghc` GitHub mirror | `ubuntu-24.04` or `ubuntu-24.04-arm` runner: 4 cores, 16 GB, free for public repositories, 6-hour job limit | Yes: a follow-on `windows-11-arm` job runs the bindist checks automatically | A `quick` stage 2 build should fit in 6 hours; if not, split it across jobs with caching. Merge requests still go to GitLab. |
| GitLab CI on gitlab.haskell.org | GHC's own runners | Under Wine only | Fork pipelines normally get no runners; a pipeline runs only for a merge request against `ghc/ghc`. |

## Build time estimates

For the cross compiler plus a `quick` stage 2 on an AMD Ryzen 7 5700G
(8 cores, 16 threads). These are estimates until a build is timed.

| Setup | Parallelism | Estimate |
| --- | --- | --- |
| About 13 GB free | `-j8` (a compile job peaks around 1–2 GB, a few modules near 3 GB) | about 1.5–2.5 hours |
| About 55 GB free | `-j16` | about 1–1.5 hours |

More memory buys maybe 25–40%, not twice the speed: only 8 of the 16 threads
are physical cores, and Hadrian's dependency graph rarely keeps more than about
8–12 jobs busy. A `release` flavour roughly doubles these times. GitHub's
4-core runners are roughly 2.5–4 times slower than the `-j16` row.
