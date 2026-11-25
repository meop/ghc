# Native Windows AArch64 GHC

Fork-only working folder for building and validating a GHC that runs natively
on Windows on Arm (`aarch64-unknown-mingw32`). Tracks
[#25974](https://gitlab.haskell.org/ghc/ghc/-/work_items/25974). It is not
meant to be merged: changes for review go to merge requests against `ghc/ghc`.

The `.sh` scripts run on x86_64 Linux (stone): they build and package the
cross-built distribution. The `.ps1` scripts run on the Windows AArch64 host
(acrylic), started from that host's own shell. Nothing here drives the host over
SSH, and nothing registers a scheduled task: a long run is a background command
of the shell that starts it.

## Contents

| File | Purpose |
| --- | --- |
| [TODO.md](TODO.md) | Where things stand, the milestones, and the checklist for a Windows AArch64 host. Its dated entries keep the names of the scripts and hosts of their day |
| [BOOTSTRAP.md](BOOTSTRAP.md) | How the stages produce a Windows AArch64 GHC without one to start from, where to build it, and build times |
| [install-toolchain.sh](install-toolchain.sh) | Installs a bootstrap GHC with cabal, alex, and happy (ghcup, `~/.ghcup`) and llvm-mingw pinned to GHC CI's version (`~/.local/opt/llvm-mingw`), per-user |
| [build-bootstrap.sh](build-bootstrap.sh) | Builds the stage 1 cross compiler, then the stage 2 compiler that runs on Windows AArch64 |
| [run-capped.sh](run-capped.sh) | Runs a step in a systemd user scope with a memory cap, logging timing and peak memory |
| [repro-hsc2hs-codeview.sh](repro-hsc2hs-codeview.sh) | Shows that newer clang emits the CodeView record that breaks hsc2hs's cross mode |
| [package-bindist.sh](package-bindist.sh) | Bundles llvm-mingw's Windows AArch64 build as `mingw/`, points the target file at it through `$tooldir`, and packs a `.tar.gz` |
| [env.sh](env.sh) | The cross toolchain variables, mirroring GHC's Windows AArch64 CI job; applied to `./configure` only |
| [make-test-archive.sh](make-test-archive.sh) | Packs a worktree's `testsuite/` (and the sibling directories tests reach) with a `COMMIT` file, for `testsuite-on-host.ps1` |
| [triage.py](triage.py) | Turns a testsuite `junit.xml` into a `(test, way, result, first-error-line)` TSV and joins runs |
| [test-on-host.ps1](test-on-host.ps1) | On the host: unpacks the package and checks that GHC runs and builds working programs (15 checks). Identical to `scripts/test-ghc.ps1` in [meop/ghc-windows-aarch64](https://github.com/meop/ghc-windows-aarch64) |
| [testsuite-on-host.ps1](testsuite-on-host.ps1) | On the host: runs GHC's testsuite (the make driver) against an installed GHC, with disk guards and a `state.txt` that always ends in `finished:`. Identical to the release repo's `scripts/testsuite-on-host.ps1` |
| [build-cabal-on-host.ps1](build-cabal-on-host.ps1) | On the host: builds a native AArch64 `cabal.exe` with the installed GHC (the official x64 cabal drives the first build under emulation), then has it rebuild itself. A copy of the release repo's `scripts/build-cabal-on-host.ps1`, which is the source |
| [install-package-on-host.ps1](install-package-on-host.ps1) | On the host: builds a Hackage package's executables (and with `-Test`, its test suites) with that native cabal. Identical to the release repo's copy |
| [install-msys2-on-host.ps1](install-msys2-on-host.ps1) | On a Windows host: installs MSYS2 at `-Root` from a pinned base release. Nothing runs it now (acrylic uses `C:\msys64`, CI uses `msys2/setup-msys2`) |
| [repro-dos-crash.ps1](repro-dos-crash.ps1) | On the host: reproduces a GHC exit with code 11 while building a cabal-install dependency |
| [patches/](patches/) | The package patches `build-cabal-on-host.ps1` and `install-package-on-host.ps1` apply; the reason is in each file. Same files as the release repo's `scripts/patches/` |

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

On stone:

```sh
TARGET=binary-dist-dir-stage3 windows-aarch64/run-capped.sh bootstrap-bindist windows-aarch64/build-bootstrap.sh
windows-aarch64/package-bindist.sh   # -> _build/windows-aarch64/ghc-*-aarch64-unknown-mingw32.tar.gz
nu ~/.agents/skills/hosts/scripts/hosts.nu put acrylic <the .tar.gz> <name on acrylic>   # lands in acrylic's ~ unless a path is given
```

On the Windows host, in pwsh, with this folder's scripts (a checkout of this
branch, or copies; the host's work directory is
`%LOCALAPPDATA%\ghc-windows-aarch64-test`):

```powershell
$w = "$env:LOCALAPPDATA\ghc-windows-aarch64-test"
pwsh -NoProfile -File windows-aarch64\test-on-host.ps1 -Tarball <the .tar.gz> -Dest $w\install
```

`test-on-host.ps1` unpacks the package into `-Dest` and checks: `ghc.exe` and
the programs it builds are ARM64; `ghc --info` reports the target; `ghc-pkg
check`; hello world; `text`, `bytestring` and `containers` with `-O`; a
`-threaded` program with `+RTS -N`; and a C FFI call. The install stays on the
host for manual use. Tee the output to a file if you want a log; nothing is
written to `windows-aarch64/logs/` any more.

A single command from stone to the host is `delish acrylic '<pwsh command>'`
(the hosts skill has the details); a long script is better copied over and
started in the host's own shell.

Builds are also published as releases of
[meop/ghc-windows-aarch64](https://github.com/meop/ghc-windows-aarch64), whose
`test-ghc.yml` runs the same checks (`test-on-host.ps1`, copied there as
`scripts/test-ghc.ps1`) on GitHub's `windows-11-arm` runners; the first,
`ghc-10.1.20261004-55ec2d5e8d`, passed all of them there. Prefer that for
repeatable checks. The same repo's `test-packages.yml` and `test-testsuite.yml`
are the tested command lines for the two scripts below.

### The testsuite

```sh
windows-aarch64/make-test-archive.sh <worktree> <out-dir>   # on stone
```

```powershell
pwsh -NoProfile -File windows-aarch64\testsuite-on-host.ps1 -Archive <testsuite-HASH.tar.gz> `
  -Work $w\testsuite -Msys2 C:\msys64 -Speed 1 -Threads 3 -ExpectTree <tree hash> -ExpectGhc <compiler hash>
```

Run it from the agent's shell as a background command that is tracked until it
ends, never as a scheduled task. The script's header lists its parameters
(`-Only`, `-Tools`, `-Ghc`, `-NoExtract`, and the disk guards), its outputs
(`logs\testsuite.log`, `summary.txt`, `junit.xml`, `state.txt`) and its exit
codes. `triage.py` reads the `junit.xml`.

### Cabal and Hackage packages

```powershell
git -C utils\hsc2hs archive --format=tar.gz -o $w\hsc2hs.tar.gz HEAD
pwsh -NoProfile -File windows-aarch64\build-cabal-on-host.ps1 -Ghc <ghc.exe> -Work $w\cabal `
  -CabalVersion 3.18.2.0 -CabalSha256 <from the release's SHA256SUMS> -BuildVersion 3.18.1.0 `
  -Hsc2hsArchive $w\hsc2hs.tar.gz -PatchesDir windows-aarch64\patches -Jobs 2
```

Then, with the native cabal it built in `$w\cabal\bin`, packages (the script
reads the patches from `$w\patches`, so copy the folder there first):

```powershell
Copy-Item -Recurse -Force windows-aarch64\patches $w\
pwsh -NoProfile -File windows-aarch64\install-package-on-host.ps1 -Package ShellCheck-0.11.0 -Test -Jobs 2
```

`test-packages.yml` in the release repo runs exactly this on `windows-11-arm`.
`build-cabal-on-host.ps1` there is the source: bring changes to it back here
rather than editing this copy.

The rest of the checklist is in [TODO.md](TODO.md#windows-arm64-host-checklist);
record each result there with the commit it ran against.
