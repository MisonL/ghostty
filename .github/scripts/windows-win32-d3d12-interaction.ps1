param(
  [ValidateSet("basic", "strict")]
  [string]$Mode = "basic"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class GhosttyWin32Interaction {
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool SetWindowPos(
    IntPtr hWnd,
    IntPtr hWndInsertAfter,
    int X,
    int Y,
    int cx,
    int cy,
    uint uFlags
  );
}
"@

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
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

  $deadline = (Get-Date).AddSeconds(30)
  while (-not $Process.HasExited -and (Get-Date) -lt $deadline) {
    $Process.Refresh()
    if ($Process.MainWindowHandle -ne 0) {
      Write-Log "Window ready label=$Label hwnd=$($Process.MainWindowHandle)"
      return $Process.MainWindowHandle
    }
    Start-Sleep -Milliseconds 250
  }

  throw "Ghostty interaction window was not created in time ($Label)"
}

function Focus-Window {
  param([System.Diagnostics.Process]$Process)
  $Process.Refresh()
  [void][GhosttyWin32Interaction]::ShowWindow($Process.MainWindowHandle, 5)
  Start-Sleep -Milliseconds 200
  [void][GhosttyWin32Interaction]::SetForegroundWindow($Process.MainWindowHandle)
  Start-Sleep -Milliseconds 300
}

function Resize-Window {
  param(
    [System.Diagnostics.Process]$Process,
    [int]$Width,
    [int]$Height
  )
  $SWP_NOZORDER = 0x0004
  $SWP_NOMOVE = 0x0002
  [void][GhosttyWin32Interaction]::SetWindowPos(
    $Process.MainWindowHandle,
    [IntPtr]::Zero,
    0,
    0,
    $Width,
    $Height,
    $SWP_NOZORDER -bor $SWP_NOMOVE
  )
  Start-Sleep -Milliseconds 300
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

function Stop-ProcessBestEffort {
  param([System.Diagnostics.Process]$Process)

  if ($null -eq $Process) { return }
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
try {
  $primary = Start-GhosttyInteractive -ExePath $exePath -Label "primary"
  [void](Wait-ForWindow -Process $primary -Label "primary")
  Focus-Window -Process $primary
  Resize-Window -Process $primary -Width 1240 -Height 820
  Send-Keys "echo ghostty-ci-basic{ENTER}"

  if ($Mode -eq "strict") {
    Set-Clipboard -Value "echo ghostty-ci-strict-clipboard"
    Send-Keys "^v{ENTER}"

    $secondary = Start-GhosttyInteractive -ExePath $exePath -Label "secondary"
    [void](Wait-ForWindow -Process $secondary -Label "secondary")
    Focus-Window -Process $secondary
    Resize-Window -Process $secondary -Width 1040 -Height 720
    Send-Keys "echo ghostty-ci-second-window{ENTER}"
    Send-Keys "exit{ENTER}"
    Wait-ForExit -Process $secondary -Label "secondary"
  }

  Focus-Window -Process $primary
  Send-Keys "exit{ENTER}"
  Wait-ForExit -Process $primary -Label "primary"

  Write-Log "Windows interaction passed mode=$Mode"
}
finally {
  Stop-ProcessBestEffort -Process $secondary
  Stop-ProcessBestEffort -Process $primary
}
