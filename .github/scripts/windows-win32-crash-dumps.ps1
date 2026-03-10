param(
  [ValidateSet("enable", "collect")]
  [string]$Action = "enable",
  [string]$ExeName = $(if ([string]::IsNullOrWhiteSpace($env:GHOSTTY_CI_CRASH_DUMP_EXE_NAME)) { "ghostty.exe" } else { $env:GHOSTTY_CI_CRASH_DUMP_EXE_NAME }),
  [string]$DumpDir = $(if ([string]::IsNullOrWhiteSpace($env:GHOSTTY_CI_CRASH_DUMP_DIR)) { "ci-dumps" } else { $env:GHOSTTY_CI_CRASH_DUMP_DIR })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
Set-Location $repoRoot

function Enable-WerLocalDumpsBestEffort {
  param(
    [string]$Hive,
    [string]$ExeName,
    [string]$DumpFolder
  )

  $keyPath = "$Hive\\SOFTWARE\\Microsoft\\Windows\\Windows Error Reporting\\LocalDumps\\$ExeName"
  New-Item -Path $keyPath -Force | Out-Null
  New-ItemProperty -Path $keyPath -Name DumpFolder -PropertyType ExpandString -Value $DumpFolder -Force | Out-Null
  New-ItemProperty -Path $keyPath -Name DumpType -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path $keyPath -Name DumpCount -PropertyType DWord -Value 10 -Force | Out-Null
}

$dumpRoot = $DumpDir
if (-not [System.IO.Path]::IsPathRooted($dumpRoot)) {
  $dumpRoot = Join-Path $repoRoot $dumpRoot
}
New-Item -ItemType Directory -Force -Path $dumpRoot | Out-Null

if ($Action -eq "enable") {
  Write-Host "Enabling WER local dumps for $ExeName -> $dumpRoot"
  $enabled = $false

  try {
    Enable-WerLocalDumpsBestEffort -Hive "HKLM:" -ExeName $ExeName -DumpFolder $dumpRoot
    Write-Host "WER local dumps enabled under HKLM."
    $enabled = $true
  } catch {
    Write-Host "Failed to enable WER dumps under HKLM: $($_.Exception.Message)"
  }

  if (-not $enabled) {
    try {
      Enable-WerLocalDumpsBestEffort -Hive "HKCU:" -ExeName $ExeName -DumpFolder $dumpRoot
      Write-Host "WER local dumps enabled under HKCU."
      $enabled = $true
    } catch {
      Write-Host "Failed to enable WER dumps under HKCU: $($_.Exception.Message)"
    }
  }

  if (-not $enabled) {
    Write-Host "WER local dumps could not be enabled. Continuing without crash dumps."
  }
  exit 0
}

if ($Action -eq "collect") {
  $dumpPattern = "$ExeName*.dmp"
  $crashDumps = $null
  if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $crashDumps = Join-Path $env:LOCALAPPDATA "CrashDumps"
  }

  $sources = @()
  if (-not [string]::IsNullOrWhiteSpace($crashDumps)) { $sources += $crashDumps }
  $sources += $dumpRoot

  foreach ($source in $sources) {
    try {
      if (-not (Test-Path $source)) { continue }
      $items = Get-ChildItem -Path $source -Filter $dumpPattern -File -ErrorAction SilentlyContinue
      foreach ($item in $items) {
        if ($item.DirectoryName -eq $dumpRoot) { continue }
        Copy-Item -Path $item.FullName -Destination (Join-Path $dumpRoot $item.Name) -Force
      }
    } catch {
    }
  }

  Write-Host "Collected crash dumps (if any):"
  Get-ChildItem -Path $dumpRoot -Filter "*.dmp" -File -ErrorAction SilentlyContinue |
    Select-Object FullName, Length, LastWriteTime |
    Format-Table -AutoSize
  exit 0
}

throw "Unknown action: $Action"

