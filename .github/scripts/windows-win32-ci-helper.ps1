Set-StrictMode -Version Latest

if (-not ("GhosttyWin32Ci" -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class GhosttyWin32Ci {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);

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

  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool PostMessageW(
    IntPtr hWnd,
    uint Msg,
    IntPtr wParam,
    IntPtr lParam
  );

  public static IntPtr FindVisibleWindowForProcess(int processId) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
      uint pid;
      GetWindowThreadProcessId(hWnd, out pid);
      if (pid == (uint)processId && IsWindowVisible(hWnd)) {
        found = hWnd;
        return false;
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
}

function Get-GhosttyVisibleWindowHandle {
  param([System.Diagnostics.Process]$Process)

  if ($null -eq $Process) {
    return [IntPtr]::Zero
  }
  $Process.Refresh()
  if ($Process.HasExited) {
    return [IntPtr]::Zero
  }
  return [GhosttyWin32Ci]::FindVisibleWindowForProcess($Process.Id)
}

function Wait-GhosttyVisibleWindowHandle {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$Label,
    [int]$TimeoutSeconds = 30
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while (-not $Process.HasExited -and (Get-Date) -lt $deadline) {
    $hwnd = Get-GhosttyVisibleWindowHandle -Process $Process
    if ($hwnd -ne [IntPtr]::Zero) {
      return $hwnd
    }
    Start-Sleep -Milliseconds 250
  }

  throw "Ghostty interaction window was not created in time ($Label)"
}

function Focus-GhosttyWindow {
  param([IntPtr]$Hwnd)

  if ($Hwnd -eq [IntPtr]::Zero) { return }
  [void][GhosttyWin32Ci]::ShowWindow($Hwnd, 5)
  Start-Sleep -Milliseconds 200
  [void][GhosttyWin32Ci]::SetForegroundWindow($Hwnd)
  Start-Sleep -Milliseconds 300
}

function Resize-GhosttyWindow {
  param(
    [IntPtr]$Hwnd,
    [int]$Width,
    [int]$Height
  )

  if ($Hwnd -eq [IntPtr]::Zero) { return }
  $SWP_NOZORDER = 0x0004
  $SWP_NOMOVE = 0x0002
  [void][GhosttyWin32Ci]::SetWindowPos(
    $Hwnd,
    [IntPtr]::Zero,
    0,
    0,
    $Width,
    $Height,
    $SWP_NOZORDER -bor $SWP_NOMOVE
  )
  Start-Sleep -Milliseconds 300
}

function Close-GhosttyWindowBestEffort {
  param([IntPtr]$Hwnd)

  if ($Hwnd -eq [IntPtr]::Zero) { return }
  [void][GhosttyWin32Ci]::PostMessageW($Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
}
