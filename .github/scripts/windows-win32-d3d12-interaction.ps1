param(
  [ValidateSet("basic", "strict")]
  [string]$Mode = "basic"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
. (Join-Path $PSScriptRoot "windows-win32-ci-helper.ps1")
Set-Location $repoRoot

$logsDir = Join-Path $repoRoot "ci-logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$logPath = Join-Path $logsDir ("windows-win32-d3d12-interaction-{0}.log" -f $Mode)
if (Test-Path $logPath) {
  Remove-Item -Path $logPath -Force
}

function Write-Log {
  param([string]$Message)
  Write-Host $Message
  $Message | Out-File -FilePath $logPath -Append -Encoding utf8
}

function Resolve-GhosttyExePath {
  $exePath = $env:GHOSTTY_CI_SMOKE_EXE_PATH
  if (-not [string]::IsNullOrWhiteSpace($exePath)) {
    if (-not (Test-Path $exePath)) {
      throw "Expected executable not found: $exePath"
    }
    return $exePath
  }

  $zigExe = Join-Path $repoRoot "zig\zig.exe"
  if (-not (Test-Path $zigExe)) {
    $zigExe = "zig"
  }

  $buildArgs = @(
    "build",
    "-Dtarget=x86_64-windows-gnu",
    "-Dfont-backend=directwrite",
    "-Drenderer=d3d12",
    "-Demit-exe=true"
  )
  if ($Mode -eq "basic") {
    $buildArgs += @("-Dapp-runtime=win32", "-Dci-windows-smoke-minimal=true")
  } else {
    $buildArgs += "-Dapp-runtime=win32"
  }

  Write-Log "Building Ghostty interaction executable: $zigExe $($buildArgs -join ' ')"
  & $zigExe @buildArgs 2>&1 | Tee-Object -FilePath $logPath -Append
  if ($LASTEXITCODE -ne 0) {
    throw "Windows interaction build failed with exit code $LASTEXITCODE"
  }

  $builtExe = Join-Path $repoRoot "zig-out\bin\ghostty.exe"
  if (-not (Test-Path $builtExe)) {
    throw "Expected executable not found: $builtExe"
  }
  return $builtExe
}

function Start-GhosttyInteractive {
  param(
    [string]$ExePath,
    [string]$Label
  )

  $cmdExe = $env:ComSpec
  if ([string]::IsNullOrWhiteSpace($cmdExe)) {
    $cmdExe = Join-Path $env:WINDIR "System32\cmd.exe"
  }
  if (-not (Test-Path $cmdExe)) {
    throw "Expected Windows shell executable not found: $cmdExe"
  }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $ExePath
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $false
  $psi.WorkingDirectory = $repoRoot
  $psi.ArgumentList.Add("-e")
  $psi.ArgumentList.Add($cmdExe)
  $psi.ArgumentList.Add("/q")
  $psi.ArgumentList.Add("/k")
  $psi.Environment["GHOSTTY_CI_INTERACTION_LABEL"] = $Label

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $psi
  if (-not $process.Start()) {
    throw "Failed to start ghostty.exe for interaction ($Label)"
  }
  return $process
}

function Wait-ForWindow {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$Label
  )

  $hwnd = Wait-GhosttyVisibleWindowHandle -Process $Process -Label $Label
  Write-Log "Window ready label=$Label hwnd=$hwnd"
  return $hwnd
}

function Focus-Window {
  param([IntPtr]$Hwnd)
  Focus-GhosttyWindow -Hwnd $Hwnd
}

function Resize-Window {
  param(
    [IntPtr]$Hwnd,
    [int]$Width,
    [int]$Height
  )
  Resize-GhosttyWindow -Hwnd $Hwnd -Width $Width -Height $Height
}

function Send-Keys {
  param([string]$Text)
  [System.Windows.Forms.SendKeys]::SendWait($Text)
  Start-Sleep -Milliseconds 300
}

function Wait-ForExit {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$Label
  )

  if (-not $Process.WaitForExit(15000)) {
    throw "Ghostty interaction process did not exit cleanly ($Label)"
  }
  if ($Process.ExitCode -ne 0 -and $Process.ExitCode -ne -1) {
    throw "Ghostty interaction process exited with code $($Process.ExitCode) ($Label)"
  }
}

function Capture-ProcessLogs {
  param([System.Diagnostics.Process]$Process)

  if ($null -eq $Process) { return }
  try {
    $stdout = $Process.StandardOutput.ReadToEnd()
    if ($stdout) {
      $stdout | Out-File -FilePath $logPath -Append -Encoding utf8
    }
  } catch {
  }
  try {
    $stderr = $Process.StandardError.ReadToEnd()
    if ($stderr) {
      $stderr | Out-File -FilePath $logPath -Append -Encoding utf8
    }
  } catch {
  }
}

function Stop-ProcessBestEffort {
  param(
    [System.Diagnostics.Process]$Process,
    [IntPtr]$Hwnd = [IntPtr]::Zero
  )

  if ($null -eq $Process) { return }
  try {
    if (-not $Process.HasExited) {
      Close-GhosttyWindowBestEffort -Hwnd $Hwnd
      Start-Sleep -Seconds 2
      $Process.Refresh()
    }
  } catch {
  }
  try {
    if (-not $Process.HasExited) {
      $null = $Process.CloseMainWindow()
      Start-Sleep -Seconds 2
      $Process.Refresh()
    }
  } catch {
  }
  try {
    if (-not $Process.HasExited) {
      $Process.Kill($true)
    }
  } catch {
  }
}

$exePath = Resolve-GhosttyExePath
Write-Log "Running Windows interaction mode=$Mode exe=$exePath"

$primary = $null
$secondary = $null
$primaryHwnd = [IntPtr]::Zero
$secondaryHwnd = [IntPtr]::Zero
try {
  $primary = Start-GhosttyInteractive -ExePath $exePath -Label "primary"
  $primaryHwnd = Wait-ForWindow -Process $primary -Label "primary"
  Focus-Window -Hwnd $primaryHwnd
  Resize-Window -Hwnd $primaryHwnd -Width 1240 -Height 820
  Send-Keys "echo ghostty-ci-basic{ENTER}"

  if ($Mode -eq "strict") {
    Set-Clipboard -Value "echo ghostty-ci-strict-clipboard"
    Send-Keys "^v{ENTER}"

    $secondary = Start-GhosttyInteractive -ExePath $exePath -Label "secondary"
    $secondaryHwnd = Wait-ForWindow -Process $secondary -Label "secondary"
    Focus-Window -Hwnd $secondaryHwnd
    Resize-Window -Hwnd $secondaryHwnd -Width 1040 -Height 720
    Send-Keys "echo ghostty-ci-second-window{ENTER}"
    Send-Keys "exit{ENTER}"
    Wait-ForExit -Process $secondary -Label "secondary"
    Capture-ProcessLogs -Process $secondary
  }

  Focus-Window -Hwnd $primaryHwnd
  Send-Keys "exit{ENTER}"
  Wait-ForExit -Process $primary -Label "primary"
  Capture-ProcessLogs -Process $primary

  Write-Log "Windows interaction passed mode=$Mode"
}
finally {
  Capture-ProcessLogs -Process $secondary
  Capture-ProcessLogs -Process $primary
  Stop-ProcessBestEffort -Process $secondary -Hwnd $secondaryHwnd
  Stop-ProcessBestEffort -Process $primary -Hwnd $primaryHwnd
}
