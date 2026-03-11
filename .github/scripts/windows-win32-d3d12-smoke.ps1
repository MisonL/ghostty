param(
  [ValidateSet("native", "core-draw")]
  [string]$Mode = $(if ([string]::IsNullOrWhiteSpace($env:GHOSTTY_CI_WIN32_SMOKE_MODE)) { "native" } else { $env:GHOSTTY_CI_WIN32_SMOKE_MODE })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot

$logsDir = Join-Path $repoRoot "ci-logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$layer = if ([string]::IsNullOrWhiteSpace($env:GHOSTTY_CI_WIN32_SMOKE_LAYER)) { "default" } else { $env:GHOSTTY_CI_WIN32_SMOKE_LAYER }
$logPath = Join-Path $logsDir ("windows-win32-d3d12-smoke-{0}-{1}.log" -f $layer, $Mode)
$requireWindow = -not [string]::IsNullOrWhiteSpace($env:GHOSTTY_CI_WIN32_REQUIRE_WINDOW) -and $env:GHOSTTY_CI_WIN32_REQUIRE_WINDOW -notin @("0", "false", "False", "FALSE")
if (Test-Path $logPath) {
  Remove-Item -Path $logPath -Force
}

function Write-Log {
  param([string]$Message)
  Write-Host $Message
  $Message | Out-File -FilePath $logPath -Append -Encoding utf8
}

function Append-LogSharedBestEffort {
  param(
    [string]$LogPath,
    [string]$Message
  )

  if ([string]::IsNullOrWhiteSpace($LogPath) -or [string]::IsNullOrWhiteSpace($Message)) {
    return
  }

  try {
    $payload = [System.Text.Encoding]::UTF8.GetBytes($Message + [System.Environment]::NewLine)
    $stream = [System.IO.FileStream]::new(
      $LogPath,
      [System.IO.FileMode]::Append,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::ReadWrite
    )
    try {
      $stream.Write($payload, 0, $payload.Length)
    } finally {
      $stream.Dispose()
    }
  } catch {
    # Best-effort fallback. This can fail if another writer has an exclusive lock.
    try {
      $Message | Out-File -FilePath $LogPath -Append -Encoding utf8
    } catch {
    }
  }
}

function Write-GhosttyExeBaseAddressBestEffort {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$ExePath,
    [string]$LogPath
  )

  # Only enable this in CI smoke environments. Local repro flows also set the
  # GHOSTTY_CI_* vars, so key off GitHub Actions.
  if ($env:GITHUB_ACTIONS -ne "true") {
    return
  }

  if ($null -eq $Process) {
    return
  }

  $pid = $null
  try { $pid = $Process.Id } catch { }
  if ($null -eq $pid) {
    return
  }

  $baseAddress = $null
  $imagePath = $null
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $Process.Refresh()
      if ($Process.HasExited) {
        break
      }
      $module = $Process.MainModule
      if ($null -ne $module) {
        $baseAddress = $module.BaseAddress
        $imagePath = $module.FileName
        break
      }
    } catch {
    }
    Start-Sleep -Milliseconds 100
  }

  if ($null -ne $baseAddress) {
    $addr = [UInt64]$baseAddress.ToInt64()
    $hex = "0x{0:X16}" -f $addr
    $line = "ci.win32.ghostty_exe_base_address pid=$pid baseAddress=$hex exePath=$ExePath imagePath=$imagePath"
    Write-Host $line
    Append-LogSharedBestEffort -LogPath $LogPath -Message $line
    return
  }

  $line = "ci.win32.ghostty_exe_base_address pid=$pid baseAddress=unavailable exePath=$ExePath"
  Write-Host $line
  Append-LogSharedBestEffort -LogPath $LogPath -Message $line
}

Write-Log "Running Windows Win32 D3D12 smoke layer=$layer mode=$Mode requireWindow=$requireWindow"

try {
  . (Join-Path $PSScriptRoot "windows-win32-ci-helper.ps1")
} catch {
  Write-Log "Failed to load windows-win32-ci-helper.ps1: $($_.Exception.Message)"
  throw
}

$exePath = $env:GHOSTTY_CI_SMOKE_EXE_PATH
if ([string]::IsNullOrWhiteSpace($exePath)) {
  $zigExe = Join-Path $repoRoot "zig\zig.exe"
  if (-not (Test-Path $zigExe)) {
    $zigExe = "zig"
  }

  Write-Host "Using Zig executable: $zigExe"

  $buildArgs = @(
    "build",
    "-Dtarget=x86_64-windows-gnu",
    "-Dfont-backend=directwrite",
    "-Drenderer=d3d12",
    "-Demit-exe=true"
  )
  $useDefaultRuntime = $env:GHOSTTY_CI_WIN32_BUILD_USE_DEFAULT_RUNTIME
  if ([string]::IsNullOrWhiteSpace($useDefaultRuntime) -or $useDefaultRuntime -eq "0" -or $useDefaultRuntime -eq "false") {
    $buildArgs += "-Dapp-runtime=win32"
  }

  $buildMinimal = $env:GHOSTTY_CI_WIN32_BUILD_MINIMAL
  if ([string]::IsNullOrWhiteSpace($buildMinimal) -or $buildMinimal -eq "1" -or $buildMinimal -eq "true") {
    $buildArgs += "-Dci-windows-smoke-minimal=true"
  }

  & $zigExe @buildArgs 2>&1 | Tee-Object -FilePath $logPath -Append
  if ($LASTEXITCODE -ne 0) {
    throw "Windows D3D12 smoke build failed with exit code $LASTEXITCODE"
  }

  $exePath = Join-Path $repoRoot "zig-out\bin\ghostty.exe"
} else {
  Write-Log "Using prebuilt smoke executable: $exePath"
}

if (-not (Test-Path $exePath)) {
  Write-Log "Expected executable not found: $exePath"
  $parentDir = Split-Path -Parent $exePath
  if (-not [string]::IsNullOrWhiteSpace($parentDir) -and (Test-Path $parentDir)) {
    Write-Log "Listing contents of $parentDir"
    Get-ChildItem -Path $parentDir -Force |
      Select-Object FullName, Length, LastWriteTime |
      Format-Table -AutoSize | Out-String |
      Out-File -FilePath $logPath -Append -Encoding utf8
  }
  throw "Expected executable not found: $exePath"
}

$cmdExe = $env:ComSpec
if ([string]::IsNullOrWhiteSpace($cmdExe)) {
  $winDir = $env:WINDIR
  if ([string]::IsNullOrWhiteSpace($winDir)) {
    throw "Unable to determine Windows shell path from ComSpec or WINDIR"
  }
  $cmdExe = Join-Path $winDir "System32\cmd.exe"
}

if (-not (Test-Path $cmdExe)) {
  throw "Expected Windows shell executable not found: $cmdExe"
}

Write-Log "Using Windows shell executable: $cmdExe"

$smokeTimeoutSeconds = 45
if (-not [string]::IsNullOrWhiteSpace($env:GHOSTTY_CI_WIN32_SMOKE_TIMEOUT_SECONDS)) {
  try {
    $smokeTimeoutSeconds = [int]$env:GHOSTTY_CI_WIN32_SMOKE_TIMEOUT_SECONDS
  } catch {
  }
}

$keepaliveSeconds = $smokeTimeoutSeconds + 5
if (-not [string]::IsNullOrWhiteSpace($env:GHOSTTY_CI_WIN32_SMOKE_KEEPALIVE_SECONDS)) {
  try {
    $keepaliveSeconds = [int]$env:GHOSTTY_CI_WIN32_SMOKE_KEEPALIVE_SECONDS
  } catch {
  }
}
if ($keepaliveSeconds -lt 20) { $keepaliveSeconds = 20 }
$pingCount = $keepaliveSeconds + 1
if ($pingCount -lt 3) { $pingCount = 3 }
Write-Log "Smoke timeoutSeconds=$smokeTimeoutSeconds keepaliveSeconds=$keepaliveSeconds pingCount=$pingCount"

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $exePath
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $false
$psi.WorkingDirectory = $repoRoot
$psi.ArgumentList.Add("-e")
$psi.ArgumentList.Add($cmdExe)
$psi.ArgumentList.Add("/c")
$psi.ArgumentList.Add("echo ghostty-ci-smoke & ping -n $pingCount 127.0.0.1 >nul")
$psi.Environment["GHOSTTY_CI_WIN32_SMOKE"] = "1"
$psi.Environment["GHOSTTY_CI_WIN32_SMOKE_MODE"] = $Mode
if (-not [string]::IsNullOrWhiteSpace($layer)) {
  $psi.Environment["GHOSTTY_CI_WIN32_SMOKE_LAYER"] = $layer
}

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $psi
$process.EnableRaisingEvents = $true
$forcedTermination = $false
$windowHandle = [IntPtr]::Zero
$logCapture = $null

if (-not $process.Start()) {
  throw "Failed to start ghostty.exe for Windows smoke"
}

$logCapture = Start-GhosttyProcessLogCapture -Process $process -LogPath $logPath
Write-GhosttyExeBaseAddressBestEffort -Process $process -ExePath $exePath -LogPath $logPath

$requiredMarkers = switch ($Mode) {
  "core-draw" {
    @(
      "ci.win32.window_ready",
      "ci.win32.core_surface_ready",
      "ci.win32.core_draw_ready",
      "ci.win32.present_ok"
    )
  }
  default {
    @(
      "ci.win32.window_ready",
      "ci.win32.native_draw_ready",
      "ci.win32.present_ok"
    )
  }
}

$deadline = (Get-Date).AddSeconds($smokeTimeoutSeconds)
while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
  if ($windowHandle -eq [IntPtr]::Zero) {
    $windowHandle = Get-GhosttyWindowHandleBestEffort -Process $process
  }

  # Once we have all expected markers, we can start shutting down early.
  $liveContent = ""
  try {
    $liveContent = Get-Content -Path $logPath -Raw
  } catch {
  }

  $missingLive = @()
  foreach ($marker in $requiredMarkers) {
    if ($liveContent -notmatch [regex]::Escape($marker)) {
      $missingLive += $marker
    }
  }
  if ($missingLive.Count -eq 0) {
    break
  }

  Start-Sleep -Milliseconds 250
}

if (-not $process.HasExited) {
  try {
    Close-GhosttyWindowBestEffort -Hwnd $windowHandle
    Start-Sleep -Seconds 2
    $process.Refresh()
  } catch {
  }
}

if (-not $process.HasExited) {
  try {
    $forcedTermination = $true
    $process.Kill($true)
  } catch {
  }
}

try {
  $process.WaitForExit()
  $process.WaitForExit(1000) | Out-Null
} catch {
}
Stop-GhosttyProcessLogCapture -Capture $logCapture

if (-not (Test-Path $logPath)) {
  throw "Smoke log missing: $logPath"
}

$logContent = Get-Content -Path $logPath -Raw

$missingMarkers = @()
foreach ($marker in $requiredMarkers) {
  if ($logContent -notmatch [regex]::Escape($marker)) {
    $missingMarkers += $marker
  }
}

$failed = $false
if ($forcedTermination) {
  Write-Host "Smoke process required forced termination"
  if ($missingMarkers.Count -gt 0) {
    $failed = $true
  }
}
if ($requireWindow -and $windowHandle -eq [IntPtr]::Zero -and $logContent -notmatch [regex]::Escape("ci.win32.window_ready")) {
  Write-Host "Smoke process never exposed a window handle (and log did not report ci.win32.window_ready)"
  $failed = $true
}
if ($process.ExitCode -ne 0 -and $process.ExitCode -ne -1) {
  Write-Host "Smoke process exit code: $($process.ExitCode)"
  $failed = $true
}
if ($missingMarkers.Count -gt 0) {
  Write-Host "Missing smoke markers: $($missingMarkers -join ', ')"
  $failed = $true
}

if ($failed) {
  try {
    "Smoke diagnostics: exitCode=$($process.ExitCode) forcedTermination=$forcedTermination windowHandle=$windowHandle" | Out-File -FilePath $logPath -Append -Encoding utf8
    "===== ghostty process list =====" | Out-File -FilePath $logPath -Append -Encoding utf8
    (Get-Process ghostty -ErrorAction SilentlyContinue |
      Select-Object Id, ProcessName, MainWindowTitle, MainWindowHandle |
      Format-List | Out-String) | Out-File -FilePath $logPath -Append -Encoding utf8
  } catch {
  }

  Write-Host "===== windows-win32-d3d12-smoke.log ====="
  Get-Content -Path $logPath
  Write-Host "===== ghostty process list ====="
  Get-Process ghostty -ErrorAction SilentlyContinue |
    Select-Object Id, ProcessName, MainWindowTitle, MainWindowHandle |
    Format-List
  throw "Windows Win32 D3D12 smoke failed (mode=$Mode)"
}

Write-Host "Windows Win32 D3D12 smoke passed (mode=$Mode)"
