# Runs on the Windows AArch64 host. Reproduces GHC exiting with code 11 and
# no output while building directory-ospath-streaming-0.3 (a cabal-install
# dependency), outside cabal so all output is visible, then varies the flags.
# Needs the store that build-cabal-on-host.ps1 filled (for atomic-counter).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'ghc-windows-aarch64-test'
$work = Join-Path $root 'cabal'
$env:CABAL_DIR = Join-Path $work 'cabal-dir'
$ghc = (Get-ChildItem (Join-Path $root 'install') -Directory | Select-Object -First 1).FullName + '\bin\ghc.exe'
$store = Get-ChildItem (Join-Path $env:CABAL_DIR 'store') -Directory | Select-Object -First 1
$db = Join-Path $store.FullName 'package.db'
$atomic = (Get-ChildItem $db -Filter 'atomic-counter-*.conf' | Select-Object -First 1).BaseName

$repro = Join-Path $work 'repro-dos'
if (Test-Path $repro) { Remove-Item -Recurse -Force $repro }
New-Item -ItemType Directory -Force $repro | Out-Null
$tarball = Get-ChildItem (Join-Path $env:CABAL_DIR 'packages\hackage.haskell.org\directory-ospath-streaming') -Recurse -Filter '*.tar.gz' | Select-Object -First 1
tar -xzf $tarball.FullName -C $repro
$src = Join-Path $repro 'directory-ospath-streaming-0.3'
"ghc: $ghc"; "atomic-counter: $atomic"

$modules = 'System.Directory.OsPath.Streaming', 'System.Directory.OsPath.Streaming.Internal',
    'System.Directory.OsPath.Streaming.Internal.Raw', 'System.Directory.OsPath.Types',
    'System.Directory.OsPath.Contents', 'System.Directory.OsPath.FileType', 'System.Directory.OsPath.Utils'
$common = @('-package-env=-', '--make', '-isrc', '-hide-all-packages', '-no-user-package-db',
    '-package-db', $db, '-package-id', $atomic,
    '-package', 'Win32', '-package', 'base', '-package', 'deepseq', '-package', 'directory',
    '-package', 'filepath', '-package', 'os-string', '-XHaskell2010', '-j1') + $modules
$weverything = @('-Weverything', '-Wno-all-missed-specialisations', '-Wno-implicit-prelude',
    '-Wno-missed-specialisations', '-Wno-missing-import-lists', '-Wno-missing-local-signatures',
    '-Wno-safe', '-Wno-unsafe', '-Wno-missing-deriving-strategies', '-Wno-missing-safe-haskell-mode',
    '-Wno-prepositive-qualified-module', '-Wno-missing-kind-signatures', '-Wno-missing-role-annotations',
    '-Wno-missing-poly-kind-signatures')

$variants = [ordered]@{
    'as cabal: -O -Weverything' = @('-O') + $weverything
    '-O only'                   = @('-O')
    '-O0 -Weverything'          = @('-O0') + $weverything
    '-O0'                       = @('-O0')
}
Push-Location $src
try {
    foreach ($name in $variants.Keys) {
        $out = Join-Path $repro ("out-" + ($name -replace '[^A-Za-z0-9]+', '-'))
        $argv = $common + @('-outputdir', $out) + $variants[$name]
        $lines = & $ghc @argv 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
        "== $name : exit $code"
        $lines | Select-Object -Last 12 | ForEach-Object { "   $_" }
    }
} finally {
    Pop-Location
}
