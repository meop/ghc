# Runs on the Windows AArch64 host (copied there by build-cabal-on-host.sh).
# Builds a native AArch64 cabal.exe with the GHC that test-on-host.ps1
# installed. cabal publishes no Windows AArch64 build, so the official x64
# cabal.exe drives this first build under Windows' x64 emulation; it only
# orchestrates, and every compile runs on the native AArch64 GHC. Then the
# native cabal builds itself again as a check that it works.
param(
    [Parameter(Mandatory)] [string] $Ghc,
    [Parameter(Mandatory)] [string] $Work,
    [Parameter(Mandatory)] [string] $CabalVersion,
    [Parameter(Mandatory)] [string] $CabalSha256,
    [int] $Jobs = 2
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$failed = 0

function Check([string] $name, [scriptblock] $body) {
    $start = Get-Date
    try {
        $detail = & $body
        "PASS  $name  $detail  ($([math]::Round(((Get-Date) - $start).TotalMinutes, 1)) min)"
    } catch {
        "FAIL  $name  $($_.Exception.Message)"
        $script:failed++
    }
}

function Get-PEMachine([string] $path) {
    $b = [IO.File]::ReadAllBytes((Resolve-Path $path).ProviderPath)
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    '0x{0:X4}' -f [BitConverter]::ToUInt16($b, $pe + 4)
}

# Runs a native command with its output in $Work\logs\<log>.log; throws on a
# nonzero exit with the last lines of output.
function Invoke-Logged([string] $log, [string] $exe, [string[]] $argv) {
    $path = Join-Path $Work "logs\$log.log"
    & $exe @argv 2>&1 | ForEach-Object { "$_" } | Set-Content -Encoding utf8 $path
    if ($LASTEXITCODE -ne 0) {
        throw "exit $LASTEXITCODE (see $log.log):`n$((Get-Content $path | Select-Object -Last 15) -join "`n")"
    }
    Get-Content $path
}

New-Item -ItemType Directory -Force (Join-Path $Work 'logs'), (Join-Path $Work 'x64'), (Join-Path $Work 'bin') | Out-Null
# A private cabal directory (store, package index, config), so this leaves
# no trace in the user's own %APPDATA%\cabal.
$env:CABAL_DIR = Join-Path $Work 'cabal-dir'

"ghc: $Ghc ($(& $Ghc --numeric-version), $(Get-PEMachine $Ghc))"

$zip = Join-Path $Work "cabal-install-$CabalVersion-x86_64-mingw64.zip"
$x64Cabal = Join-Path $Work 'x64\cabal.exe'
Check "x64 cabal $CabalVersion (emulated)" {
    if (-not (Test-Path $zip)) {
        Invoke-WebRequest "https://downloads.haskell.org/~cabal/cabal-install-$CabalVersion/cabal-install-$CabalVersion-x86_64-mingw64.zip" -OutFile $zip
    }
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $CabalSha256) { throw "sha256 $hash, expected $CabalSha256" }
    Expand-Archive -Force $zip (Join-Path $Work 'x64')
    "$(& $x64Cabal --numeric-version), $(Get-PEMachine $x64Cabal)"
}

Check 'cabal update' { Invoke-Logged 'cabal-update' $x64Cabal @('update') | Select-Object -Last 1 }

# Packages with build-type Configure need a POSIX sh; Git for Windows has one.
$gitSh = Join-Path $env:ProgramFiles 'Git\usr\bin'
if (Test-Path (Join-Path $gitSh 'sh.exe')) { $env:PATH = "$env:PATH;$gitSh" }

$nativeCabal = Join-Path $Work 'bin\cabal.exe'
Check 'build cabal-install with x64 cabal and AArch64 GHC' {
    Invoke-Logged 'build-cabal-1' $x64Cabal @(
        'install', "cabal-install-$CabalVersion", "--with-compiler=$Ghc", "-j$Jobs",
        '--install-method=copy', '--overwrite-policy=always', "--installdir=$(Join-Path $Work 'bin')"
    ) | Out-Null
    $m = Get-PEMachine $nativeCabal
    if ($m -ne '0xAA64') { throw "cabal.exe is $m" }
    "cabal.exe $m"
}
Check 'native cabal --version' { (Invoke-Logged 'native-version' $nativeCabal @('--version')) -join ' ' }

# Self-host: the native cabal builds cabal-install again into a second dir.
Check 'native cabal rebuilds cabal-install' {
    $again = Join-Path $Work 'bin-selfhost'
    Invoke-Logged 'build-cabal-2' $nativeCabal @(
        'install', "cabal-install-$CabalVersion", "--with-compiler=$Ghc", "-j$Jobs",
        '--install-method=copy', '--overwrite-policy=always', "--installdir=$again"
    ) | Out-Null
    "$(Get-PEMachine (Join-Path $again 'cabal.exe'))"
}

if ($failed) { "$failed check(s) failed"; exit 1 }
"native cabal: $nativeCabal"
'all checks passed'
