# Runs on the Windows AArch64 host, from the caller's shell (in the foreground,
# or as a background command the caller tracks). Runs GHC's testsuite (the make driver,
# testsuite/mk/test.mk) against an installed GHC, using MSYS2's make and sh and
# the host's Python.
#
# Writes $Work\logs\testsuite.log, summary.txt, junit.xml and state.txt.
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
    State "started: Work=$Work Msys2=$Msys2 Speed=$Speed Threads=$Threads Only='$Only' NoExtract=$NoExtract ExpectTree='$ExpectTree' ExpectGhc='$ExpectGhc'"

    State "env: SystemRoot=$env:SystemRoot COMSPEC=$env:COMSPEC PATHEXT=$env:PATHEXT (inherited; the runner only sets TMP/TEMP/TMPDIR and adds MSYSTEM, CHERE_INVOKING and MSYS2_PATH_TYPE; PATH is not touched)"

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
    # /etc/profile resets TMP and TEMP to /tmp, so export them again after login.
    $cmd = "export TMP='$mt' TEMP='$mt' TMPDIR='$mt'; " +
           "make -C testsuite/tests test TEST_HC='$(MsysPath $ghc)' PYTHON='$(MsysPath $Python)' " +
           "THREADS=$Threads SPEED=$Speed SUMMARY_FILE='$(MsysPath (Join-Path $logs 'summary.txt'))' " +
           "JUNIT_FILE='$(MsysPath (Join-Path $logs 'junit.xml'))' $only"
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
