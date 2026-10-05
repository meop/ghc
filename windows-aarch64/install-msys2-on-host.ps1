# Runs on a Windows host (copied there by install-msys2-on-host.sh). Installs
# MSYS2 for this work at $Root (e.g. V:\msys2\ghc), from a pinned base archive,
# then refreshes the package databases and installs only the packages GHC's
# build and testsuite need. No `pacman -Syu`: the rest of the base stays at
# the pinned release (a recent base keeps the partial-upgrade gap small).
# Re-running it skips the extraction and only installs missing packages.
param(
    [Parameter(Mandatory)] [string] $Root,
    [Parameter(Mandatory)] [string] $Version,   # base release date, e.g. 20260927
    [Parameter(Mandatory)] [string] $Sha256,
    [string[]] $Packages = @('make', 'autoconf', 'automake', 'libtool', 'patch', 'diffutils',
                             'tar', 'xz', 'unzip', 'zip', 'curl', 'perl')
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$bash = Join-Path $Root 'usr\bin\bash.exe'
function Invoke-Msys([string] $command) {
    $env:MSYSTEM = 'MSYS'; $env:CHERE_INVOKING = '1'
    & $bash -lc $command 2>&1 | ForEach-Object { "   $_" }
    if ($LASTEXITCODE -ne 0) { throw "msys2 command failed ($LASTEXITCODE): $command" }
}

if (-not (Test-Path $bash)) {
    if (Test-Path $Root) { throw "$Root exists but has no usr\bin\bash.exe; remove it first" }
    $parent = Split-Path $Root -Parent
    New-Item -ItemType Directory -Force $parent | Out-Null
    $sfx = Join-Path $env:TEMP "msys2-base-x86_64-$Version.sfx.exe"
    $tag = $Version.Insert(6, '-').Insert(4, '-')
    "downloading msys2-base-x86_64-$Version.sfx.exe ($tag)"
    Invoke-WebRequest "https://github.com/msys2/msys2-installer/releases/download/$tag/msys2-base-x86_64-$Version.sfx.exe" -OutFile $sfx
    $hash = (Get-FileHash $sfx -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $Sha256) { throw "sha256 $hash, expected $Sha256" }
    # The archive extracts to an msys64 folder; extract next to $Root, rename.
    $staging = Join-Path $parent ".extract-$Version"
    & $sfx -y "-o$staging" | Out-Null
    Move-Item (Join-Path $staging 'msys64') $Root
    Remove-Item -Recurse -Force $staging, $sfx
    "first start (keyring, home directory):"
    Invoke-Msys 'true'
    "msys2-base-x86_64-$Version, sha256 $Sha256, installed $((Get-Date).ToUniversalTime().ToString('u'))" |
        Set-Content (Join-Path $Root 'msys2-base-version.txt')
} else {
    "already installed: $(Get-Content (Join-Path $Root 'msys2-base-version.txt') -ErrorAction SilentlyContinue)"
}

"refresh package databases and install: $($Packages -join ' ')"
Invoke-Msys "pacman -Sy --noconfirm && pacman -S --needed --noconfirm $($Packages -join ' ')"
"installed packages: $((& $bash -lc "pacman -Q $($Packages -join ' ')" 2>&1) -join ', ')" |
    Add-Content (Join-Path $Root 'msys2-base-version.txt')

"root: $Root"
& $bash -lc 'uname -a; make --version | head -1; autoconf --version | head -1'
