#Requires -Version 5.1
<#
.SYNOPSIS
  Skapar eller uppdaterar en PSADT v4.1-mapp och lägger Notes-overlay ovanpå officiell mall.

.DESCRIPTION
  Anropar New-ADTTemplate (PSAppDeployToolkit 4.1+) om mallen saknas, kopierar sedan
  overlay\Invoke-AppDeployToolkit.ps1, Files\install.parameters.json och (om den finns)
  scripts\install_notes.ps1 in i mall-roten.

  Baka inte in hela Notes-kitet i Files\. Peka MediaRoot mot UNC eller C:\install\Notes-1451.

.EXAMPLE
  Install-Module PSAppDeployToolkit -Scope CurrentUser -Force
  .\New-NotesPsadtFolder.ps1 -Destination 'C:\Temp\HCL-Notes-1451-PSADT'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Destination = (Join-Path $env:TEMP 'HCL-Notes-1451-PSADT')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$overlayRoot = $PSScriptRoot
$overlayInvoke = Join-Path $overlayRoot 'overlay\Invoke-AppDeployToolkit.ps1'
$overlayJson = Join-Path $overlayRoot 'Files\install.parameters.json.example'
$repoInstall = Join-Path (Split-Path -Parent $overlayRoot) 'scripts\install_notes.ps1'

if (-not (Test-Path -LiteralPath $overlayInvoke)) {
    throw "Saknar overlay: $overlayInvoke"
}

$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
$parent = Split-Path -Parent $Destination
$name = Split-Path -Leaf $Destination
if (-not $parent -or -not $name) {
    throw "Destination måste vara en full sökväg till paketmappen, t.ex. C:\Temp\HCL-Notes-1451-PSADT"
}

$generatedInvoke = Join-Path $Destination 'Invoke-AppDeployToolkit.ps1'
$generatedExe = Join-Path $Destination 'Invoke-AppDeployToolkit.exe'
$generatedModule = Join-Path $Destination 'PSAppDeployToolkit\PSAppDeployToolkit.psd1'

$alreadyTemplate = (Test-Path -LiteralPath $generatedModule) -or (Test-Path -LiteralPath $generatedExe)

if (-not $alreadyTemplate) {
    $mod = Get-Module -ListAvailable -Name 'PSAppDeployToolkit' |
        Where-Object { $_.Version -ge [version]'4.1.0' } |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $mod) {
        throw @"
PSAppDeployToolkit 4.1+ saknas, och $Destination är inte en uppackad Template_v4-mapp.

  Install-Module PSAppDeployToolkit -Scope CurrentUser -Force

Eller packa upp PSAppDeployToolkit_Template_v4.zip till $Destination
och kör det här scriptet igen (det skriver bara overlay).
https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases
"@
    }

    Import-Module -Name $mod.Path -Force
    Write-Host "PSADT $($mod.Version)"
    Write-Host "New-ADTTemplate -Destination '$parent' -Name '$name'"
    # Destination = förälder, Name = mappnamn. Utan -Name skapas PSAppDeployToolkit_4.x under Destination.
    New-ADTTemplate -Destination $parent -Name $name
}

if (-not (Test-Path -LiteralPath $generatedExe) -and -not (Test-Path -LiteralPath $generatedModule)) {
    throw "Hittar inte PSAppDeployToolkit-mall i $Destination (saknar exe och PSAppDeployToolkit\)."
}

Copy-Item -LiteralPath $overlayInvoke -Destination $generatedInvoke -Force
Write-Host "Skrev $generatedInvoke"

$filesDir = Join-Path $Destination 'Files'
New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
$destExample = Join-Path $filesDir 'install.parameters.json.example'
$destJson = Join-Path $filesDir 'install.parameters.json'
Copy-Item -LiteralPath $overlayJson -Destination $destExample -Force
if (-not (Test-Path -LiteralPath $destJson)) {
    Copy-Item -LiteralPath $overlayJson -Destination $destJson -Force
    Write-Host "Skapade $destJson (redigera Domino/MediaRoot)."
}

if (Test-Path -LiteralPath $repoInstall) {
    Copy-Item -LiteralPath $repoInstall -Destination (Join-Path $filesDir 'install_notes.ps1') -Force
    Write-Host "Kopierade Files\install_notes.ps1 (fallback; kitets SupportFiles\scripts\ används först)."
}

Write-Host ''
Write-Host 'Nästa:'
Write-Host "  notepad '$destJson'"
Write-Host "  cd '$Destination'"
Write-Host '  .\Invoke-AppDeployToolkit.exe -DeploymentType Install'
Write-Host '  .\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
Write-Host ''
Write-Host 'Baka inte in Notes-kitet i Files\. MediaRoot i JSON pekar pa UNC eller C:\install\Notes-1451.'
