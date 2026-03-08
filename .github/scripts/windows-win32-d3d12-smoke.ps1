Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot

$logsDir = Join-Path $repoRoot "ci-logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$logPath = Join-Path $logsDir "windows-win32-d3d12-smoke.log"
if (Test-Path $logPath) {
  Remove-Item -Path $logPath -Force
}

$exePath = $env:GHOSTTY_CI_SMOKE_EXE_PATH
if ([string]::IsNullOrWhiteSpace($exePath)) {
  $zigExe = Join-Path $repoRoot "zig\zig.exe"
  if (-not (Test-Path $zigExe)) {
    $zigExe = "zig"
  }

  Write-Host "Using Zig executable: $zigExe"

  & $zigExe build `
    -Dtarget=x86_64-windows-gnu `
    -Dfont-backend=directwrite `
    -Dapp-runtime=win32 `
    -Drenderer=d3d12 `
    -Dci-windows-smoke-minimal=true `
    -Demit-exe=true 2>&1 | Tee-Object -FilePath $logPath -Append
  if ($LASTEXITCODE -ne 0) {
    throw "Windows D3D12 smoke build failed with exit code $LASTEXITCODE"
  }

  $exePath = Join-Path $repoRoot "zig-out\bin\ghostty.exe"
} else {
  Write-Host "Using prebuilt smoke executable: $exePath"
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

"Using Windows shell executable: $cmdExe" | Out-File -FilePath $logPath -Append -Encoding utf8
Write-Host "Using Windows shell executable: $cmdExe"

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

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $psi
$process.EnableRaisingEvents = $true
$forcedTermination = $false

if (-not $process.Start()) {
  throw "Failed to start ghostty.exe for Windows smoke"
}

$sawWindow = $false
$deadline = (Get-Date).AddSeconds(30)
while (-not $process.HasExited -and (Get-Date) -lt $deadline) {
  $process.Refresh()
  if ($process.MainWindowHandle -ne 0) {
    $sawWindow = $true
  }
  Start-Sleep -Milliseconds 250
}

if (-not $process.HasExited) {
  try {
    $null = $process.CloseMainWindow()
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
} catch {
}

$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
if ($stdout) {
  $stdout | Out-File -FilePath $logPath -Append -Encoding utf8
}
if ($stderr) {
  $stderr | Out-File -FilePath $logPath -Append -Encoding utf8
}

if (-not (Test-Path $logPath)) {
  throw "Smoke log missing: $logPath"
}

$logContent = Get-Content -Path $logPath -Raw
$requiredMarkers = @(
  "ci.win32.window_ready",
  "ci.win32.native_draw_ready",
  "ci.win32.present_ok"
)

$missingMarkers = @()
foreach ($marker in $requiredMarkers) {
  if ($logContent -notmatch [regex]::Escape($marker)) {
    $missingMarkers += $marker
  }
}

$failed = $false
if ($forcedTermination) {
  Write-Host "Smoke process required forced termination"
  $failed = $true
}
if ($process.ExitCode -ne 0 -and $process.ExitCode -ne -1) {
  Write-Host "Smoke process exit code: $($process.ExitCode)"
  $failed = $true
}
if (-not $sawWindow) {
  Write-Host "Smoke process never exposed a non-zero MainWindowHandle"
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
  throw "Windows Win32 D3D12 smoke failed"
}

Write-Host "Windows Win32 D3D12 smoke passed"
