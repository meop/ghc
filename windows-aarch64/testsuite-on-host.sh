#!/usr/bin/env bash
# Run GHC's testsuite natively on the Windows AArch64 host, detached in a
# scheduled task so it survives SSH disconnects (see testsuite-on-host.ps1).
#
#   windows-aarch64/testsuite-on-host.sh start [speed] [threads] [tests...]
#       speed: 2 fast (default), 1 normal, 0 slow; tests: run only these
#   windows-aarch64/testsuite-on-host.sh status     # state and recent output
#   windows-aarch64/testsuite-on-host.sh fetch      # copy logs to LOG_DIR
#
# Tests the GHC that test-on-host.sh installed, from this checkout's HEAD.
# Environment: HOST (default: metal), PORT (default: 22222), MSYS2 (default:
#   C:\msys2\ghc), LOG_DIR.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
HOST=${HOST:-metal}
PORT=${PORT:-22222}
MSYS2=${MSYS2:-'C:\msys2\ghc'}
LOG_DIR=${LOG_DIR:-$here/logs}
task=ghc-testsuite
remote_rel='AppData/Local/ghc-windows-aarch64-test/testsuite'
remote_win='$env:LOCALAPPDATA\ghc-windows-aarch64-test\testsuite'
# Directories are removed with rd: Remove-Item hung on the unpacked GHC tree.
# Remote PowerShell is sent as -EncodedCommand: the host's SSH shell may be a
# wrapper (such as a .bat passing %*) that would split a multi-line command.
ssh_() {
  local enc; enc=$(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  ssh -o BatchMode=yes -p "$PORT" "$HOST" "pwsh -NoProfile -NonInteractive -EncodedCommand $enc" </dev/null
}

case ${1:-} in
  start)
    speed=${2:-2}; threads=${3:-4}; shift $(( $# < 3 ? $# : 3 )); only="$*"
    archive=$(mktemp --suffix=.tar.gz); trap 'rm -f "$archive"' EXIT
    git -C "$here/.." archive --format=tar.gz -o "$archive" HEAD
    ssh_ "if ((Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).State -eq 'Running') { throw 'a testsuite run is in progress' }
          if (Test-Path $remote_win) { cmd /c rd /s /q $remote_win }; New-Item -ItemType Directory -Force $remote_win | Out-Null"
    scp -o BatchMode=yes -q -P "$PORT" "$archive" "$HOST:$remote_rel/src.tar.gz"
    scp -o BatchMode=yes -q -P "$PORT" "$here/testsuite-on-host.ps1" "$HOST:$remote_rel/"
    args="-NoProfile -ExecutionPolicy Bypass -File $remote_win\\testsuite-on-host.ps1 -Archive $remote_win\\src.tar.gz -Work $remote_win -Msys2 $MSYS2 -Speed $speed -Threads $threads"
    # pwsh -File takes double quotes only; backtick-escaped inside the remote string.
    [[ -n $only ]] && args+=" -Only \`\"$only\`\""
    # S4U with the highest run level: no desktop session needed, and it keeps
    # running after this SSH session ends.
    # Full path: a task's PATH need not include where pwsh lives (ghpm's bin).
    ssh_ "\$a = New-ScheduledTaskAction -Execute (Join-Path \$PSHOME 'pwsh.exe') -Argument \"$args\"
          \$p = New-ScheduledTaskPrincipal -UserId (whoami) -LogonType S4U -RunLevel Highest
          \$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
          Register-ScheduledTask -TaskName $task -Action \$a -Principal \$p -Settings \$s -Force | Out-Null
          Start-ScheduledTask -TaskName $task; 'started $task: commit $(git -C "$here/.." rev-parse --short HEAD) speed=$speed threads=$threads only=$only'"
    ;;
  status)
    ssh_ "\"task: \$((Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).State)\"
          Get-Content $remote_win\\logs\\state.txt -ErrorAction SilentlyContinue
          '--- testsuite.log (last lines):'; Get-Content $remote_win\\logs\\testsuite.log -Tail 8 -ErrorAction SilentlyContinue"
    ;;
  fetch)
    out=$LOG_DIR/testsuite-$HOST-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$out"
    scp -o BatchMode=yes -q -r -P "$PORT" "$HOST:$remote_rel/logs" "$out/"
    echo "$out"
    ;;
  *) echo "usage: testsuite-on-host.sh start [speed] [threads] [tests...] | status | fetch" >&2; exit 1 ;;
esac
