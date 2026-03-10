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

  public static IntPtr FindWindowForProcess(int processId, bool requireVisible) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
      uint pid;
      GetWindowThreadProcessId(hWnd, out pid);
      if (pid == (uint)processId) {
        if (!requireVisible || IsWindowVisible(hWnd)) {
          found = hWnd;
          return false;
        }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static IntPtr FindAnyWindowForProcess(int processId) {
    return FindWindowForProcess(processId, false);
  }

  public static IntPtr FindVisibleWindowForProcess(int processId) {
    return FindWindowForProcess(processId, true);
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

function Get-GhosttyAnyWindowHandle {
  param([System.Diagnostics.Process]$Process)

  if ($null -eq $Process) {
    return [IntPtr]::Zero
  }
  $Process.Refresh()
  if ($Process.HasExited) {
    return [IntPtr]::Zero
  }
  return [GhosttyWin32Ci]::FindAnyWindowForProcess($Process.Id)
}

function Get-GhosttyWindowHandleBestEffort {
  param([System.Diagnostics.Process]$Process)

  $hwnd = Get-GhosttyVisibleWindowHandle -Process $Process
  if ($hwnd -ne [IntPtr]::Zero) {
    return $hwnd
  }
  return Get-GhosttyAnyWindowHandle -Process $Process
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
    if ($hwnd -ne [IntPtr]::Zero) { return $hwnd }

    # On hosted runners we can sometimes create a top-level window that is not
    # "visible" yet (or visibility is misreported). If we can find a handle at
    # all, try to show it and keep waiting for the visible state.
    $any = Get-GhosttyAnyWindowHandle -Process $Process
    if ($any -ne [IntPtr]::Zero) {
      try {
        [void][GhosttyWin32Ci]::ShowWindow($any, 5)
      } catch {
      }
    }
    Start-Sleep -Milliseconds 250
  }

  $Process.Refresh()
  if ($Process.HasExited) {
    throw "Ghostty interaction process exited before window became visible ($Label), exit=$($Process.ExitCode)"
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

if (-not ("GhosttyProcessLogCapture" -as [type])) {
  Add-Type @"
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public sealed class GhosttyProcessLogCapture : IDisposable {
  private readonly Process process;
  private readonly StreamWriter writer;
  private readonly object syncRoot = new object();
  private readonly DataReceivedEventHandler dataHandler;
  private bool disposed;

  public GhosttyProcessLogCapture(Process process, string logPath) {
    this.process = process;
    this.writer = new StreamWriter(new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
    this.writer.AutoFlush = true;
    this.dataHandler = this.HandleData;
    this.process.OutputDataReceived += this.dataHandler;
    this.process.ErrorDataReceived += this.dataHandler;
    this.process.BeginOutputReadLine();
    this.process.BeginErrorReadLine();
  }

  private void HandleData(object sender, DataReceivedEventArgs args) {
    if (args == null || args.Data == null) {
      return;
    }

    lock (this.syncRoot) {
      if (this.disposed) {
        return;
      }
      this.writer.WriteLine(args.Data);
    }
  }

  public void Stop() {
    this.Dispose();
  }

  public void Dispose() {
    bool shouldDispose;
    lock (this.syncRoot) {
      shouldDispose = !this.disposed;
      this.disposed = true;
    }

    if (!shouldDispose) {
      return;
    }

    try {
      this.process.CancelOutputRead();
    } catch {
    }
    try {
      this.process.CancelErrorRead();
    } catch {
    }
    try {
      this.process.OutputDataReceived -= this.dataHandler;
    } catch {
    }
    try {
      this.process.ErrorDataReceived -= this.dataHandler;
    } catch {
    }

    lock (this.syncRoot) {
      try {
        this.writer.Flush();
      } catch {
      }
      this.writer.Dispose();
    }
  }
}
"@
}

function Start-GhosttyProcessLogCapture {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$LogPath
  )

  if ($null -eq $Process) {
    return $null
  }

  return [GhosttyProcessLogCapture]::new($Process, $LogPath)
}

function Stop-GhosttyProcessLogCapture {
  param($Capture)

  if ($null -eq $Capture) {
    return
  }

  try {
    $Capture.Stop()
  } catch {
  }
}
