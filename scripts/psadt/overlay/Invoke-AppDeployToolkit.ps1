#Requires -Version 5.1
<#
.SYNOPSIS
  Overlay: PSADT v4.1-skal som anropar install_notes.ps1 (HCL Notes 14.5.1).

.DESCRIPTION
  Ersätt den genererade mallens Invoke-AppDeployToolkit.ps1 med den här filen.
  Behåll PSAppDeployToolkit\ och Invoke-AppDeployToolkit.exe från New-ADTTemplate
  eller PSAppDeployToolkit_Template_v4.zip.

  All Notes-logik ligger kvar i install_notes.ps1. PSADT skoter valkomst,
  stäng Notes och defer (3 gånger).

.NOTES
  https://psappdeploytoolkit.com
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)

##================================================
## MARK: Variables
##================================================

$adtSession = @{
    AppVendor = 'HCL'
    AppName = 'Notes'
    AppVersion = '14.5.1'
    AppArch = 'x64'
    AppLang = 'SV'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @(
        @{ Name = 'notes'; Description = 'HCL Notes' }
        @{ Name = 'nlnotes'; Description = 'HCL Notes (nlnotes)' }
        @{ Name = 'notes2'; Description = 'HCL Notes' }
        @{ Name = 'ntaskldr'; Description = 'Notes Task Loader' }
        @{ Name = 'nminder'; Description = 'Notes Minder' }
    )
    AppScriptVersion = '1.0.0'
    AppScriptDate = '2026-09-11'
    AppScriptAuthor = 'Notes-1451 pack'
    RequireAdmin = $true
    InstallName = ''
    InstallTitle = ''
    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.1.8'
}

function Get-NotesJsonBool {
    param($Cfg, [string]$Name)
    if (-not $Cfg) { return $false }
    if ($Cfg.PSObject.Properties.Name -notcontains $Name) { return $false }
    return [bool]$Cfg.$Name
}

function Get-NotesJsonString {
    param($Cfg, [string]$Name)
    if (-not $Cfg) { return '' }
    if ($Cfg.PSObject.Properties.Name -notcontains $Name) { return '' }
    return [string]$Cfg.$Name
}

function Get-NotesInstallParameters {
    $example = Join-Path $PSScriptRoot 'Files\install.parameters.json.example'
    $path = Join-Path $PSScriptRoot 'Files\install.parameters.json'
    if (-not (Test-Path -LiteralPath $path)) {
        if (Test-Path -LiteralPath $example) {
            throw "Kopiera Files\install.parameters.json.example till Files\install.parameters.json och fyll i Domino/MediaRoot."
        }
        throw "Saknar $path"
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-NotesInstallScriptPath {
    param($Cfg)
    $candidates = @(
        (Join-Path (Get-NotesJsonString $Cfg 'MediaRoot') 'SupportFiles\scripts\install_notes.ps1')
        (Join-Path (Get-NotesJsonString $Cfg 'LocalMediaRoot') 'SupportFiles\scripts\install_notes.ps1')
        (Join-Path $PSScriptRoot 'Files\install_notes.ps1')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    throw "Hittar inte install_notes.ps1 under MediaRoot, LocalMediaRoot eller Files\. Kontrollera Files\install.parameters.json."
}

function Get-PowerShell64 {
    $sysNative = Join-Path $env:SystemRoot 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysNative) { return $sysNative }
    return (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Install-ADTDeployment {
    [CmdletBinding()]
    param()

    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"

    $saiwParams = @{
        AllowDefer     = $true
        DeferTimes     = 3
        CheckDiskSpace = $true
        PersistPrompt  = $true
    }
    if ($adtSession.AppProcessesToClose.Count -gt 0) {
        $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
    }
    Show-ADTInstallationWelcome @saiwParams
    Show-ADTInstallationProgress

    $adtSession.InstallPhase = $adtSession.DeploymentType

    $cfg = Get-NotesInstallParameters
    $installPs1 = Get-NotesInstallScriptPath -Cfg $cfg
    Write-ADTLogEntry -Message "Anropar $installPs1"

    $argList = Get-NotesPs1ArgumentList -Cfg $cfg -InstallPs1 $installPs1
    $ps = Get-PowerShell64
    Start-ADTProcess -FilePath $ps -ArgumentList $argList -Timeout 7200

    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
}

function Get-NotesPs1ArgumentList {
    param($Cfg, [string]$InstallPs1, [switch]$Uninstall)

    $mediaRoot = Get-NotesJsonString $Cfg 'MediaRoot'
    $localRoot = Get-NotesJsonString $Cfg 'LocalMediaRoot'
    if (-not $localRoot) { $localRoot = 'C:\install\Notes-1451' }

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $InstallPs1,
        '-MediaRoot', $mediaRoot,
        '-LocalMediaRoot', $localRoot,
        '-ForceCloseNotes'
    )
    if ($Uninstall) {
        $argList += '-Uninstall'
        if (Get-NotesJsonBool $Cfg 'RemoveUserData') { $argList += '-RemoveUserData' }
    }
    else {
        $dominoName = Get-NotesJsonString $Cfg 'DominoName'
        $dominoAddress = Get-NotesJsonString $Cfg 'DominoAddress'
        if ($dominoName) { $argList += @('-DominoName', $dominoName) }
        if ($dominoAddress) { $argList += @('-DominoAddress', $dominoAddress) }
    }
    if (Get-NotesJsonBool $Cfg 'SkipLocalMirror') { $argList += '-SkipLocalMirror' }
    return $argList
}

function Uninstall-ADTDeployment {
    [CmdletBinding()]
    param()

    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"
    if ($adtSession.AppProcessesToClose.Count -gt 0) {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress

    $adtSession.InstallPhase = $adtSession.DeploymentType
    $cfg = Get-NotesInstallParameters
    $installPs1 = Get-NotesInstallScriptPath -Cfg $cfg
    Write-ADTLogEntry -Message "Avinstallerar via $installPs1 -Uninstall"

    $argList = Get-NotesPs1ArgumentList -Cfg $cfg -InstallPs1 $installPs1 -Uninstall
    $ps = Get-PowerShell64
    Start-ADTProcess -FilePath $ps -ArgumentList $argList -Timeout 7200

    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"
}

function Repair-ADTDeployment {
    [CmdletBinding()]
    param()
    Write-ADTLogEntry -Message 'Repair är inte implementerat för Notes-skalet.' -Severity 2
}

##================================================
## MARK: Initialization
##================================================

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

try {
    $localModule = Join-Path $PSScriptRoot 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'
    $devModule = Join-Path $PSScriptRoot '..\..\..\PSAppDeployToolkit\PSAppDeployToolkit.psd1'
    if (Test-Path -LiteralPath $localModule -PathType Leaf) {
        Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'PSAppDeployToolkit') -Recurse -File |
            Unblock-File -ErrorAction Ignore
        Import-Module -Name $localModule -Force
    }
    elseif (Test-Path -LiteralPath $devModule -PathType Leaf) {
        Import-Module -Name $devModule -Force
    }
    else {
        Import-Module -Name 'PSAppDeployToolkit' -MinimumVersion '4.1.0' -Force
    }

    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch {
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}

##================================================
## MARK: Invocation
##================================================

try {
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | ForEach-Object {
        if ($_.Name -match 'PSAppDeployToolkit\..+$') {
            Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
            Import-Module -Name $_.FullName -Force
        }
    }

    & "$($adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch {
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity 3
    Close-ADTSession -ExitCode 60001
}
