#Requires -Version 5.1
<#
.SYNOPSIS
  Bygger .intunewin med Microsoft Win32 Content Prep Tool.

.EXAMPLE
  .\New-NotesIntuneWin.ps1 -KitRoot 'C:\install\Notes-1451' -OutputDir 'C:\intune-out'

.EXAMPLE
  .\New-NotesIntuneWin.ps1 -Mode NetworkCopy -OutputDir 'C:\intune-out'
#>
[CmdletBinding()]
param(
    [ValidateSet('FullPackage', 'NetworkCopy')]
    [string]$Mode = 'FullPackage',
    [string]$KitRoot = '',
    [string]$OutputDir = (Join-Path $env:TEMP 'Notes1451-intunewin'),
    [string]$IntuneWinAppUtil = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-IntuneWinAppUtil {
    param([string]$Hint)
    if ($Hint -and (Test-Path -LiteralPath $Hint)) { return (Resolve-Path $Hint).Path }
    $cmd = Get-Command 'IntuneWinAppUtil.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $guess = Join-Path $env:USERPROFILE 'Downloads\IntuneWinAppUtil.exe'
    if (Test-Path -LiteralPath $guess) { return $guess }
    return $null
}

$tool = Find-IntuneWinAppUtil -Hint $IntuneWinAppUtil
if (-not $tool) {
    throw @"
Hittar inte IntuneWinAppUtil.exe.

Ladda ner Microsoft Win32 Content Prep Tool:
  https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool

Kor sedan:
  .\New-NotesIntuneWin.ps1 -IntuneWinAppUtil 'C:\verktyg\IntuneWinAppUtil.exe' ...
"@
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

if ($Mode -eq 'NetworkCopy') {
    $setupFolder = $PSScriptRoot
    $setupFile = Join-Path $setupFolder 'Install-NotesIntune.cmd'
    Write-Host "NetworkCopy: wrappar bara $setupFolder"
    Write-Host "Lag intune.parameters.json har (InstallMode=NetworkCopy) innan du kor verktyget."
}
else {
    if ([string]::IsNullOrWhiteSpace($KitRoot)) {
        $scriptsDir = Split-Path -Parent $PSScriptRoot
        $supportDir = Split-Path -Parent $scriptsDir
        $KitRoot = Split-Path -Parent $supportDir
    }
    $KitRoot = (Resolve-Path -LiteralPath $KitRoot).Path
    $setupFolder = $KitRoot
    $setupFile = Join-Path $KitRoot 'SupportFiles\scripts\intune\Install-NotesIntune.cmd'
    if (-not (Test-Path -LiteralPath $setupFile)) {
        throw "Saknar $setupFile - ar KitRoot hela Notes-1451?"
    }
    Write-Host "FullPackage: wrappar $KitRoot"
    Write-Host "Uteslut Notes_1451_Win64_English och MUI ur kitet om ni inte behover dem (mindre nedladdning)."
}

if (-not (Test-Path -LiteralPath $setupFile)) {
    throw "Saknar setup-fil: $setupFile"
}

Write-Host "IntuneWinAppUtil = $tool"
Write-Host "Output           = $OutputDir"

$p = Start-Process -FilePath $tool -ArgumentList @(
    '-c', $setupFolder,
    '-s', $setupFile,
    '-o', $OutputDir,
    '-q'
) -Wait -PassThru -NoNewWindow

if ($null -eq $p -or $p.ExitCode -ne 0) {
    $code = if ($p) { $p.ExitCode } else { 'null' }
    throw "IntuneWinAppUtil exit $code"
}

Get-ChildItem -LiteralPath $OutputDir -Filter '*.intunewin' | ForEach-Object {
    Write-Host "Skapad: $($_.FullName) ($([math]::Round($_.Length / 1MB, 1)) MB)"
}
