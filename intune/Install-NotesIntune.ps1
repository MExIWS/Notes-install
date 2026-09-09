#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Intune-wrapper for install_notes.ps1 (samma kedja som PDQ).

.DESCRIPTION
  FullPackage: kitet ligger i .intunewin (IMECache). Speglas till LocalMediaRoot,
  sedan kor install_notes.ps1 -SkipLocalMirror (IMECache raderas efter install).

  NetworkCopy: litet .intunewin. Robocopy fran NetworkMediaRoot (samma share som PDQ).

  Kopiera intune.parameters.json.example till intune.parameters.json och fyll i varden.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-IntuneConfig {
    $cfg = [pscustomobject]@{
        InstallMode              = 'FullPackage'
        DominoName               = ''
        DominoAddress            = ''
        LocalMediaRoot           = 'C:\install\Notes-1451'
        NetworkMediaRoot         = ''
        NotesEdition             = 'Swedish'
        InstallLanguagePack      = $false
        AddToHostsAsSetupServer  = $false
        HostsIp                  = ''
        HostsName                = ''
        CleanupStaging           = $false
    }

    $path = Join-Path $PSScriptRoot 'intune.parameters.json'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Ingen intune.parameters.json - anvander defaults ($($cfg.InstallMode))."
        return $cfg
    }

    Write-Host "Laser $path"
    $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in @($cfg.PSObject.Properties.Name)) {
        $prop = $json.PSObject.Properties[$name]
        if ($prop -and $null -ne $prop.Value) {
            $cfg.$name = $prop.Value
        }
    }
    return $cfg
}

function Get-FullPackageKitRoot {
    $scriptsDir = Split-Path -Parent $PSScriptRoot
    $supportDir = Split-Path -Parent $scriptsDir
    $kitRoot = Split-Path -Parent $supportDir
    if ((Split-Path -Leaf $scriptsDir) -ine 'scripts') { return $null }
    if ((Split-Path -Leaf $supportDir) -ine 'SupportFiles') { return $null }
    $swedish = Join-Path $kitRoot 'Notes_1451_Win64_Swedish'
    $installPs1 = Join-Path $kitRoot 'SupportFiles\scripts\install_notes.ps1'
    if ((Test-Path -LiteralPath $swedish) -and (Test-Path -LiteralPath $installPs1)) {
        return $kitRoot
    }
    return $null
}

function Invoke-RobocopyKit {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Write-Host "Robocopy:"
    Write-Host "  Fran: $Source"
    Write-Host "  Till: $Destination"
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $p = Start-Process -FilePath 'robocopy.exe' -ArgumentList @(
        $Source.TrimEnd('\'),
        $Destination.TrimEnd('\'),
        '/E', '/R:2', '/W:2', '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
    ) -Wait -PassThru -NoNewWindow

    if ($null -eq $p -or $p.ExitCode -ge 8) {
        $code = if ($p) { $p.ExitCode } else { 'null' }
        throw "robocopy misslyckades (exit $code)"
    }
}

function Convert-ToBool {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($null -eq $Value) { return $false }
    return [System.Convert]::ToBoolean($Value)
}

Write-Host '==> Intune wrapper: HCL Notes 14.5.1'
Write-Host "64-bit PowerShell = $([Environment]::Is64BitProcess)"
if (-not [Environment]::Is64BitProcess) {
    throw 'Kor 64-bitars PowerShell (Install-NotesIntune.cmd via SysNative). 32-bit IME saboterar x64 setup.exe.'
}

$cfg = Read-IntuneConfig
$mode = [string]$cfg.InstallMode
if ([string]::IsNullOrWhiteSpace($mode)) { $mode = 'FullPackage' }
$dest = [string]$cfg.LocalMediaRoot
if ([string]::IsNullOrWhiteSpace($dest)) { $dest = 'C:\install\Notes-1451' }

Write-Host "InstallMode     = $mode"
Write-Host "LocalMediaRoot  = $dest"

$installArgs = @{
    MediaRoot     = $dest
    NotesEdition  = [string]$cfg.NotesEdition
}

if (-not [string]::IsNullOrWhiteSpace([string]$cfg.DominoName)) {
    $installArgs.DominoName = [string]$cfg.DominoName
}
if (-not [string]::IsNullOrWhiteSpace([string]$cfg.DominoAddress)) {
    $installArgs.DominoAddress = [string]$cfg.DominoAddress
}
if (-not [string]::IsNullOrWhiteSpace([string]$cfg.HostsIp)) {
    $installArgs.HostsIp = [string]$cfg.HostsIp
}
if (-not [string]::IsNullOrWhiteSpace([string]$cfg.HostsName)) {
    $installArgs.HostsName = [string]$cfg.HostsName
}
if (Convert-ToBool $cfg.AddToHostsAsSetupServer) {
    $installArgs.AddToHostsAsSetupServer = $true
}
if (Convert-ToBool $cfg.InstallLanguagePack) {
    $installArgs.InstallLanguagePack = $true
}

if ($mode -ieq 'NetworkCopy') {
    $unc = [string]$cfg.NetworkMediaRoot
    if ([string]::IsNullOrWhiteSpace($unc)) {
        throw 'InstallMode=NetworkCopy kraver NetworkMediaRoot i intune.parameters.json'
    }
    Write-Host "NetworkMediaRoot = $unc"
    if (-not (Test-Path -LiteralPath (Join-Path $unc 'SupportFiles\scripts\install_notes.ps1'))) {
        throw "Hittar inte kit pa $unc (VPN/share/ACL?)"
    }
    Invoke-RobocopyKit -Source $unc -Destination $dest
    $installArgs.MediaRoot = $dest
    $installArgs.SkipLocalMirror = $true
    $scriptPath = Join-Path $dest 'SupportFiles\scripts\install_notes.ps1'
}
elseif ($mode -ieq 'FullPackage') {
    $kit = Get-FullPackageKitRoot
    if (-not $kit) {
        throw @"
InstallMode=FullPackage men hittar inte kit-roten.
Wrap:a hela Notes-1451\ (Notes_1451_Win64_Swedish + SupportFiles) som .intunewin,
eller byt till NetworkCopy.
PSScriptRoot = $PSScriptRoot
"@
    }
    Write-Host "Kit i paketet = $kit"
    if ([IO.Path]::GetFullPath($kit).TrimEnd('\') -ne [IO.Path]::GetFullPath($dest).TrimEnd('\')) {
        Invoke-RobocopyKit -Source $kit -Destination $dest
    }
    $installArgs.MediaRoot = $dest
    $installArgs.SkipLocalMirror = $true
    $scriptPath = Join-Path $dest 'SupportFiles\scripts\install_notes.ps1'
}
else {
    throw "Okand InstallMode '$mode' (anvand FullPackage eller NetworkCopy)"
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Hittar inte $scriptPath"
}

Write-Host "Kor: $scriptPath"
& $scriptPath @installArgs

if (Convert-ToBool $cfg.CleanupStaging) {
    Write-Host "CleanupStaging: tar bort $dest"
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Intune wrapper klar'
exit 0
