param(
  [ValidateSet("native", "core-draw")]
  [string]$Mode = $(if ([string]::IsNullOrWhiteSpace($env:GHOSTTY_CI_WIN32_SMOKE_MODE)) { "native" } else { $env:GHOSTTY_CI_WIN32_SMOKE_MODE })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
. (Join-Path $PSScriptRoot "windows-win32-ci-helper.ps1")
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

Write-Log "Running Windows Win32 D3D12 smoke layer=$layer mode=$Mode"

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
$psi.ArgumentList.Add("echo ghostty-ci-smoke & ping -n 3 127.0.0.1 >nul")
$psi.Environment["GHOSTTY_CI_WIN32_SMOKE"] = "1"
$psi.Environment["GHOSTTY_CI_WIN32_SMOKE_MODE"] = $Mode

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

$deadline = (Get-Date).AddSeconds(30)
while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
  if ($windowHandle -eq [IntPtr]::Zero) {
    $windowHandle = Get-GhosttyVisibleWindowHandle -Process $process
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

$missingMarkers = @()
foreach ($marker in $requiredMarkers) {
  if ($logContent -notmatch [regex]::Escape($marker)) {
    $missingMarkers += $marker
  }
}

$failed = $false
if ($forcedTermination) {
  Write-Host "Smoke process required forced termination"
  if ($Mode -ne "native" -or $missingMarkers.Count -gt 0) {
    $failed = $true
  }
}
if ($requireWindow -and $windowHandle -eq [IntPtr]::Zero) {
  Write-Host "Smoke process never exposed a visible window handle"
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
  Write-Host "===== windows-win32-d3d12-smoke.log ====="
  Get-Content -Path $logPath
  Write-Host "===== ghostty process list ====="
  Get-Process ghostty -ErrorAction SilentlyContinue |
    Select-Object Id, ProcessName, MainWindowTitle, MainWindowHandle |
    Format-List
  throw "Windows Win32 D3D12 smoke failed (mode=$Mode)"
}

Write-Host "Windows Win32 D3D12 smoke passed (mode=$Mode)"
