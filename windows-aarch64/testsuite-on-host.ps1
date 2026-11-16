# Runs on the Windows AArch64 host, from the caller's shell (in the foreground,
# or as a background command the caller tracks). Runs GHC's testsuite (the make driver,
# testsuite/mk/test.mk) against an installed GHC, using MSYS2's make and sh and
# the host's Python.
#
# Writes $Work\logs\testsuite.log, summary.txt, junit.xml, perf-metrics.tsv and state.txt.
# The last line of state.txt is always "finished: <reason>" (written in a
# finally block), unless the process itself is killed.
#
# Protections:
#   - TMP/TEMP/TMPDIR point at a per-run directory, $Work\tmp-<utc-stamp>,
#     removed in the finally block. MSYS2's /etc/profile resets TMP and TEMP to
#     /tmp (C:\msys64\tmp) in every login shell, so they are exported again
#     inside the bash command line; that is what keeps GHC's leaked ghc*_tmp_*
#     directories out of C:\msys64\tmp.
#   - Free space on the drive of $Work: refuse to start below -MinFreeGB (15),
#     append a "free-space:" line to state.txt every -LogEveryMinutes (10), and
#     abort the run (killing its process tree) below -AbortFreeGB (5).
#   - -ExpectGhc / -ExpectTree: abort unless `ghc --info`'s "Project Git commit
#     id" and the test tree's COMMIT file start with the expected hash.
#
# Test tree layout in the archive: testsuite-tree/testsuite/... plus
# testsuite-tree/COMMIT (what T04 produces), or the older layout with
# testsuite/ at the archive root (no COMMIT; -ExpectTree then fails).
#
# Test tools: the testsuite calls check-ppr, check-exact, dump-decls, count-deps and
# changelog-d from <tree>\inplace\bin (testsuite/mk/boilerplate.mk), which a bindist run
# does not have. -Tools <zip> (e.g. testsuite-tools-<hash>.zip: the five .exe files, built
# natively with the compiler under test) is extracted there after the tree is in place, also
# with -NoExtract (an existing inplace\bin is overwritten file by file, nothing else is removed).
# make also gets CHANGELOG_D=<inplace\bin\changelog-d.exe>, because tests/linters/Makefile does
# not include boilerplate.mk and hadrian is what normally passes it.
#
# Coverage flags (T24). testsuite/mk/test.mk, the make driver, never passes config.have_ncg
# (Hadrian does, RunTest.hs) and takes config.debug_rts from the compiler's list of RTS
# ways ("RTS ways" in `ghc --info`, which names every way the install ships, debug among
# them) instead of the way the compiler itself runs with. Left alone, have_ncg() is False
# on a native-code-generator build, so llvm_build() is True: every th ext-interp case becomes
# fragile_for(16087), `optasm` is dropped from numeric/should_run, and the NCG-only tests are
# skipped; and debug_rts() is True, which runs T23142 and T25374 (they need `ghc +RTS -Di`)
# and skips InternalCounters. So the runner does what Hadrian does, from this compiler, and
# passes both through EXTRA_RUNTEST_OPTS:
#   config.have_ncg   = `ghc --info` "Have native code generator" is YES
#   config.debug_rts  = the "RTS way" of `ghc +RTS --info` (the way ghc.exe itself runs) has "debug" in it
# Both values are written to state.txt at the start of a run.
#
# Environment of the make child: NoDefaultCurrentDirectoryInExePath is removed (an agent harness sets it, a user's shell
# does not; with it cmd.exe does not search the current directory, so a test that runs a bare program name through
# System.Process.shell fails), and TEST_HC is exported next to the make variable of the same name (Hadrian puts it in the
# test environment; T18382 reads it). Both are recorded in `env:` lines of state.txt.
#
# Perf tests: runtests.py skips every performance test (forceSkipPerfTests) when the tree is
# not a git checkout and there is no --metrics-file. The runner passes METRICS_FILE=
# <Work>\logs\perf-metrics.tsv, so they run; the file collects their metrics (test, way, metric,
# value) as the run appends them at its end. The metrics file alone is not enough: report_stats()
# in testlib.py returns before it records anything unless `git rev-parse HEAD` works in the
# tests directory (a perf test that runs outside a git checkout passes and stores nothing). So
# the runner gives an extracted tree a throwaway git repository with one empty commit (the tree
# has no hie.yaml in `git ls-files`, so req_ls_files tests stay skipped). With no baseline in
# git notes a new metric trivially passes: perf tests here measure and record, not compare.
#
# Exit code: make's exit code if it ran; otherwise 10 refused (low disk at
# start), 11 aborted (low disk during the run), 12 commit mismatch, 13 other
# error.
param(
    [string] $Archive = '',                      # tar.gz of the test tree; not needed with -NoExtract
    [Parameter(Mandatory)] [string] $Work,
    [Parameter(Mandatory)] [string] $Msys2,      # e.g. C:\msys64
    [int] $Speed = 2,                            # 2 fast, 1 normal, 0 slow
    [int] $Threads = 4,
    [string] $Only = '',                         # space-separated test names
    [string] $Python = (Join-Path $HOME '.local\bin\python.exe'),
    [switch] $NoExtract,                         # reuse an already-extracted $Work\src
    [string] $Tools = '',                        # zip of test tool exes, extracted into <tree>\inplace\bin
    [string] $ExpectTree = '',                   # commit the test tree must be (prefix match)
    [string] $ExpectGhc = '',                    # commit the compiler must be (prefix match)
    [string] $Ghc = '',                          # ghc.exe to test; default: the only install\ghc-* dir
    [double] $MinFreeGB = 15,
    [double] $AbortFreeGB = 5,
    [int] $LogEveryMinutes = 10
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$tarExe = 'C:\Windows\System32\tar.exe'
# Always the full path to cmd.exe. C:\msys64\usr\bin holds a file named `cmd` (no extension); with that directory
# first on PATH a bare `cmd` resolves to it and Windows shows "Select an app to open 'cmd'". (Earlier versions of
# this script put it first on PATH; now only the MSYS2 login shell does, for itself.)
$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
$logs = Join-Path $Work 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$state = Join-Path $logs 'state.txt'
function State([string] $s) {
    $line = "$((Get-Date).ToUniversalTime().ToString('u')) $s"
    $line | Add-Content -Encoding utf8 $state
    Write-Host $line
}

$drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot((Resolve-Path $Work).ProviderPath))
function FreeGB { [math]::Round($drive.AvailableFreeSpace / 1GB, 2) }
# MSYS2 paths for make: C:\x\y -> /c/x/y
function MsysPath([string] $p) { '/' + $p.Substring(0, 1).ToLower() + ($p.Substring(2) -replace '\\', '/') }
function MsysGhcTmpCount {
    @(Get-ChildItem (Join-Path $Msys2 'tmp') -Directory -Filter 'ghc*_tmp_*' -ErrorAction SilentlyContinue).Count
}
function Same-Commit([string] $a, [string] $b) {
    $a = $a.Trim().ToLower(); $b = $b.Trim().ToLower()
    $a.Length -ge 7 -and $b.Length -ge 7 -and ($a.StartsWith($b) -or $b.StartsWith($a))
}
# The newest *.run directory under the tests is the test most recently started.
function LatestTest([string] $tests) {
    try {
        $d = Get-ChildItem $tests -Recurse -Directory -Filter '*.run' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($d) { $d.Name -replace '\.run$', '' } else { '-' }
    } catch { '-' }
}
function KillTree([int] $id) { & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $id *> $null }
# Anything left that runs from the work dir or was started with it (tests, ghc, iserv, python driver).
function SweepStragglers {
    Get-CimInstance Win32_Process | Where-Object {
        $_.ProcessId -ne $PID -and ($_.ExecutablePath -like "$Work\*" -or
            ($_.CommandLine -and $_.CommandLine -like "*$Work\src*"))
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        State "swept straggler $($_.ProcessId) $($_.Name)" | Out-Null
    }
}

$reason = ''        # set when the run ends for a reason other than an unexpected exception
$exitCode = 13
$runTmp = ''
$aborted = $false
try {
    State "started: Work=$Work Msys2=$Msys2 Speed=$Speed Threads=$Threads Only='$Only' NoExtract=$NoExtract Tools='$Tools' ExpectTree='$ExpectTree' ExpectGhc='$ExpectGhc'"

    # NoDefaultCurrentDirectoryInExePath=1 (an agent harness sets it in its own process environment; a user's shell does not)
    # makes cmd.exe skip the current directory when it looks for a program, which breaks tests that run a bare program name
    # through System.Process.shell (hWaitForInput-accurate-stdin). Remove it for this run: the runner is a child process,
    # so the caller's environment keeps it.
    $noDefCwd = [Environment]::GetEnvironmentVariable('NoDefaultCurrentDirectoryInExePath')
    Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
    State "env: SystemRoot=$env:SystemRoot COMSPEC=$env:COMSPEC PATHEXT=$env:PATHEXT NoDefaultCurrentDirectoryInExePath=$(if ($null -eq $noDefCwd) { '(unset)' } else { "'$noDefCwd' in the caller, removed for the run" }) (inherited; the runner only sets TMP/TEMP/TMPDIR, removes NoDefaultCurrentDirectoryInExePath, and adds MSYSTEM, CHERE_INVOKING, MSYS2_PATH_TYPE and TEST_HC; PATH is not touched)"

    # --- free space at start
    $free = FreeGB
    State "free-space: $free GB on $($drive.Name) at start (refuse below $MinFreeGB GB, abort below $AbortFreeGB GB)" | Out-Null
    if ($free -lt $MinFreeGB) { $reason = "refused: $free GB free on $($drive.Name), below $MinFreeGB GB"; $exitCode = 10; throw $reason }

    # --- tools
    if (-not (Test-Path $tarExe)) { throw "missing $tarExe" }
    if (-not (Test-Path $Python)) { throw "python not found at $Python (pass -Python)" }
    $bash = Join-Path $Msys2 'usr\bin\bash.exe'
    if (-not (Test-Path $bash)) { throw "missing $bash" }

    # --- compiler
    $root0 = Join-Path $env:LOCALAPPDATA 'ghc-windows-aarch64-test'
    if ($Ghc) { $ghc = $Ghc } else {
        $dirs = @(Get-ChildItem (Join-Path $root0 'install') -Directory -Filter 'ghc-*' |
                  Where-Object { Test-Path (Join-Path $_.FullName 'bin\ghc.exe') })
        if ($dirs.Count -ne 1) { throw "expected exactly one install\ghc-* dir, found $($dirs.Count) ($($dirs.Name -join ', ')); pass -Ghc <path to ghc.exe>" }
        $ghc = Join-Path $dirs[0].FullName 'bin\ghc.exe'
    }
    $info = (& $ghc --info) -join "`n"
    $ghcCommit = if ($info -match '\("Project Git commit id","([^"]*)"\)') { $Matches[1] } else { '' }
    State "ghc $(& $ghc --numeric-version) at $ghc; Project Git commit id: '$ghcCommit'" | Out-Null
    if ($ExpectGhc -and -not (Same-Commit $ghcCommit $ExpectGhc)) {
        $reason = "commit mismatch: ghc is '$ghcCommit', expected '$ExpectGhc'"; $exitCode = 12; throw $reason
    }

    # --- coverage flags, derived from the compiler the way Hadrian does (see the header)
    $haveNcg = $info -match '\("Have native code generator","YES"\)'
    $rtsInfo = (& $ghc +RTS --info) -join "`n"
    if ($rtsInfo -notmatch '\("RTS way",\s*"([^"]*)"\)') { throw 'no "RTS way" in the output of ghc +RTS --info' }
    $rtsWay = $Matches[1]
    $debugRts = $rtsWay -match 'debug'
    $extraOpts = "-e config.have_ncg=$(if ($haveNcg) { 'True' } else { 'False' }) -e config.debug_rts=$(if ($debugRts) { 'True' } else { 'False' })"
    State "coverage: ghc --info Have native code generator=$(if ($haveNcg) { 'YES' } else { 'not YES' }); ghc +RTS --info RTS way='$rtsWay'; EXTRA_RUNTEST_OPTS='$extraOpts'" | Out-Null

    # --- test tree
    $src = Join-Path $Work 'src'
    if ($NoExtract) {
        if (-not (Test-Path $src)) { throw "-NoExtract but $src does not exist" }
        State "reusing extracted tree in $src" | Out-Null
    } else {
        if (-not $Archive) { throw '-Archive is required unless -NoExtract is given' }
        if (-not (Test-Path $Archive)) { throw "archive not found: $Archive" }
        if (Test-Path $src) { & $cmdExe /c rd /s /q $src }   # Remove-Item hangs on this tree
        New-Item -ItemType Directory -Force $src | Out-Null
        & $tarExe -xzf $Archive -C $src
        if ($LASTEXITCODE -ne 0) { throw "tar failed: $LASTEXITCODE" }
        State "unpacked $Archive with $tarExe" | Out-Null
    }
    $root = if (Test-Path (Join-Path $src 'testsuite-tree\testsuite\tests')) { Join-Path $src 'testsuite-tree' }
            elseif (Test-Path (Join-Path $src 'testsuite\tests')) { $src }
            else { throw "no testsuite\tests under $src (neither testsuite-tree\ nor top-level layout)" }
    $commitFile = Join-Path $root 'COMMIT'
    $treeCommit = if (Test-Path $commitFile) { (Get-Content $commitFile -TotalCount 1).Trim() } else { '' }
    State "test tree root $root; COMMIT: '$treeCommit'" | Out-Null
    if ($ExpectTree -and -not (Same-Commit $treeCommit $ExpectTree)) {
        $reason = "commit mismatch: test tree is '$treeCommit', expected '$ExpectTree'"; $exitCode = 12; throw $reason
    }

    # --- test tools (inplace\bin), after the tree is in place; also with -NoExtract
    if ($Tools) {
        if (-not (Test-Path $Tools)) { throw "tools zip not found: $Tools" }
        $inplaceBin = Join-Path $root 'inplace\bin'
        New-Item -ItemType Directory -Force $inplaceBin | Out-Null
        & $tarExe -xf $Tools -C $inplaceBin
        if ($LASTEXITCODE -ne 0) { throw "tar failed on $Tools : $LASTEXITCODE" }
        State "tools: $Tools -> $inplaceBin : $((Get-ChildItem $inplaceBin -File).Name -join ' ')" | Out-Null
    }

    # --- throwaway git repo so that perf metrics are recorded (see the header)
    if (-not (Test-Path (Join-Path $root '.git'))) {
        $git = Get-Command git -ErrorAction Stop
        & $git.Source -C $root init -q
        & $git.Source -C $root -c user.name=testsuite -c user.email=testsuite@localhost commit -q --allow-empty -m "testsuite tree $treeCommit"
        if ($LASTEXITCODE -ne 0) { throw "git commit in $root failed: $LASTEXITCODE" }
        State "git: empty repository with one commit in $root (perf metrics need git rev-parse HEAD)" | Out-Null
    }

    # --- per-run temp dir
    $runTmp = Join-Path $Work ('tmp-' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    New-Item -ItemType Directory -Force $runTmp | Out-Null
    $env:TMP = $runTmp; $env:TEMP = $runTmp; $env:TMPDIR = $runTmp
    $msysTmpBefore = MsysGhcTmpCount
    State "temp dir $runTmp; $Msys2\tmp has $msysTmpBefore ghc*_tmp_* dirs before the run" | Out-Null

    # inherit: keep the Windows PATH in MSYS2's login shell (the driver runs git).
    $env:MSYSTEM = 'MSYS'; $env:CHERE_INVOKING = '1'; $env:MSYS2_PATH_TYPE = 'inherit'
    $only = if ($Only) { "TEST='$Only'" } else { '' }
    $mt = MsysPath $runTmp
    # tests/linters/Makefile does not include boilerplate.mk, so it only sees CHANGELOG_D when hadrian passes it;
    # do the same when the tools are there. (The other tools get their default from boilerplate.mk.)
    $changelogD = Join-Path $root 'inplace\bin\changelog-d.exe'
    $toolVars = if ($Tools -and (Test-Path $changelogD)) { "CHANGELOG_D='$(MsysPath $changelogD)' " } else { '' }
    # /etc/profile resets TMP and TEMP to /tmp, so export them again after login.
    # TEST_HC is also exported, as Hadrian does (hadrian/src/Rules/Test.hs); some tests read it from the environment (T18382).
    $cmd = "export TMP='$mt' TEMP='$mt' TMPDIR='$mt' TEST_HC='$(MsysPath $ghc)'; " +
           "make -C testsuite/tests test TEST_HC='$(MsysPath $ghc)' PYTHON='$(MsysPath $Python)' " +
           "THREADS=$Threads SPEED=$Speed SUMMARY_FILE='$(MsysPath (Join-Path $logs 'summary.txt'))' " +
           "JUNIT_FILE='$(MsysPath (Join-Path $logs 'junit.xml'))' " +
           "METRICS_FILE='$(MsysPath (Join-Path $logs 'perf-metrics.tsv'))' " +
           "EXTRA_RUNTEST_OPTS='$extraOpts' $toolVars$only"
    State "env: TEST_HC=$(MsysPath $ghc) exported to the make child (msys form, as passed to make)" | Out-Null
    State "running: $cmd" | Out-Null

    # cmd.exe merges stdout and stderr into the log; taskkill /T takes the whole tree.
    $log = Join-Path $logs 'testsuite.log'
    $cmdline = "/s /c `"`"$bash`" -lc `"$cmd`" > `"$log`" 2>&1`""
    $p = Start-Process -FilePath $cmdExe -ArgumentList $cmdline `
         -WorkingDirectory $root -NoNewWindow -PassThru
    $null = $p.Handle    # keep the handle so ExitCode is available after exit
    $tests = Join-Path $root 'testsuite\tests'
    $every = [TimeSpan]::FromMinutes($LogEveryMinutes)
    $next = Get-Date
    while (-not $p.WaitForExit(15000)) {
        $free = FreeGB
        if ($free -lt $AbortFreeGB) {
            $aborted = $true
            $reason = "aborted: $free GB free on $($drive.Name), below $AbortFreeGB GB (latest test: $(LatestTest $tests))"
            $exitCode = 11
            State "free-space: $free GB; $reason; killing process tree $($p.Id)" | Out-Null
            KillTree $p.Id
            break
        }
        if ((Get-Date) -ge $next) {
            State "free-space: $free GB on $($drive.Name); latest test: $(LatestTest $tests)" | Out-Null
            $next = (Get-Date) + $every
        }
    }
    if (-not $aborted) {
        $code = $p.ExitCode
        $reason = "make exit $code"
        $exitCode = $code
    }
    State "free-space: $(FreeGB) GB on $($drive.Name) after the run; $Msys2\tmp has $(MsysGhcTmpCount) ghc*_tmp_* dirs (before: $msysTmpBefore)" | Out-Null
} catch {
    if (-not $reason) { $reason = "error: $($_.Exception.Message)"; $exitCode = 13 }
} finally {
    try {
        if ($aborted) { SweepStragglers }
        if ($runTmp -and (Test-Path $runTmp)) {
            $leaked = @(Get-ChildItem $runTmp -Force -ErrorAction SilentlyContinue).Count
            # A program still running from the temp dir (GHC's temp executables) keeps it locked: stop it, then retry.
            for ($i = 1; $i -le 6; $i++) {
                & $cmdExe /c rd /s /q $runTmp 2>$null
                if (-not (Test-Path $runTmp)) { break }
                Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$runTmp\*" } | ForEach-Object {
                    State "stopping $($_.ProcessId) $($_.ExecutablePath), still running from the temp dir" | Out-Null
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
                Start-Sleep 5
            }
            $gone = if (Test-Path $runTmp) { 'FAILED to remove: ' + ((Get-ChildItem $runTmp -Force -ErrorAction SilentlyContinue).Name -join ' ') } else { "removed (attempt $i)" }
            State "temp dir $runTmp ($leaked entries at the end): $gone" | Out-Null
        }
    } catch { State "cleanup error: $($_.Exception.Message)" | Out-Null }
    State "free-space: $(FreeGB) GB at the end" | Out-Null
    State "finished: $reason" | Out-Null
}
exit $exitCode
