param(
  [ValidateSet("basic", "strict")]
  [string]$Mode = "basic"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot

$logsDir = Join-Path $repoRoot "ci-logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$logPath = Join-Path $logsDir ("windows-win32-d3d12-interaction-{0}.log" -f $Mode)
$interactionLayer = if ([string]::IsNullOrWhiteSpace($env:GHOSTTY_CI_WIN32_SMOKE_LAYER)) { $null } else { $env:GHOSTTY_CI_WIN32_SMOKE_LAYER }
if (Test-Path $logPath) {
  Remove-Item -Path $logPath -Force
}

function Write-Log {
  param([string]$Message)
  Write-Host $Message
  $Message | Out-File -FilePath $logPath -Append -Encoding utf8
}

Write-Log "Starting Windows interaction mode=$Mode"

try {
  . (Join-Path $PSScriptRoot "windows-win32-ci-helper.ps1")
} catch {
  Write-Log "Failed to load windows-win32-ci-helper.ps1: $($_.Exception.Message)"
  throw
}

try {
  Add-Type -AssemblyName System.Windows.Forms
} catch {
  Write-Log "Failed to load System.Windows.Forms: $($_.Exception.Message)"
  throw
}

function Resolve-GhosttyExePath {
  $exePath = $env:GHOSTTY_CI_SMOKE_EXE_PATH
  if (-not [string]::IsNullOrWhiteSpace($exePath)) {
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
  if (-not [string]::IsNullOrWhiteSpace($interactionLayer)) {
    $psi.Environment["GHOSTTY_CI_WIN32_SMOKE_LAYER"] = $interactionLayer
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $psi
  if (-not $process.Start()) {
    throw "Failed to start ghostty.exe for interaction ($Label)"
  }
  $capture = Start-GhosttyProcessLogCapture -Process $process -LogPath $logPath
  return [pscustomobject]@{
    Process = $process
    Capture = $capture
  }
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
  $Process.WaitForExit()
  if ($Process.ExitCode -ne 0 -and $Process.ExitCode -ne -1) {
    throw "Ghostty interaction process exited with code $($Process.ExitCode) ($Label)"
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
  try {
    if (-not $Process.HasExited) {
      $Process.WaitForExit(5000) | Out-Null
    }
    $Process.WaitForExit()
  } catch {
  }
}

$exePath = Resolve-GhosttyExePath
Write-Log "Running Windows interaction mode=$Mode exe=$exePath"

$primary = $null
$secondary = $null
$primaryCapture = $null
$secondaryCapture = $null
$primaryHwnd = [IntPtr]::Zero
$secondaryHwnd = [IntPtr]::Zero
try {
  $primaryHandle = Start-GhosttyInteractive -ExePath $exePath -Label "primary"
  $primary = $primaryHandle.Process
  $primaryCapture = $primaryHandle.Capture
  $primaryHwnd = Wait-ForWindow -Process $primary -Label "primary"
  Focus-Window -Hwnd $primaryHwnd
  Resize-Window -Hwnd $primaryHwnd -Width 1240 -Height 820
  Send-Keys "echo ghostty-ci-basic{ENTER}"

  if ($Mode -eq "strict") {
    Set-Clipboard -Value "echo ghostty-ci-strict-clipboard"
    Send-Keys "^v{ENTER}"

    $secondaryHandle = Start-GhosttyInteractive -ExePath $exePath -Label "secondary"
    $secondary = $secondaryHandle.Process
    $secondaryCapture = $secondaryHandle.Capture
    $secondaryHwnd = Wait-ForWindow -Process $secondary -Label "secondary"
    Focus-Window -Hwnd $secondaryHwnd
    Resize-Window -Hwnd $secondaryHwnd -Width 1040 -Height 720
    Send-Keys "echo ghostty-ci-second-window{ENTER}"
    Send-Keys "exit{ENTER}"
    Wait-ForExit -Process $secondary -Label "secondary"
  }

  Focus-Window -Hwnd $primaryHwnd
  Send-Keys "exit{ENTER}"
  Wait-ForExit -Process $primary -Label "primary"

  Write-Log "Windows interaction passed mode=$Mode"
}
finally {
  Stop-ProcessBestEffort -Process $secondary -Hwnd $secondaryHwnd
  Stop-ProcessBestEffort -Process $primary -Hwnd $primaryHwnd
  Stop-GhosttyProcessLogCapture -Capture $secondaryCapture
  Stop-GhosttyProcessLogCapture -Capture $primaryCapture
}
