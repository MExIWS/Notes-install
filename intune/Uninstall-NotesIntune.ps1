#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Intune uninstall: NICE om den finns, annars msiexec pa HCL Notes, sedan residualer.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-NotesProcesses {
    foreach ($name in @('notes', 'nlnotes', 'notes2', 'ntaskldr', 'nminder')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "Stoppar $($_.Name) (PID $($_.Id))"
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
    }
}

function Find-NiceExe {
    $candidates = @(
        (Join-Path $PSScriptRoot 'NICE_x64.exe'),
        (Join-Path $PSScriptRoot '..\..\x64\NICE_x64.exe'),
        'C:\install\Notes-1451\SupportFiles\x64\NICE_x64.exe'
    )
    foreach ($c in $candidates) {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($c)
        if (Test-Path -LiteralPath $resolved) {
            return $resolved
        }
    }
    return $null
}

function Invoke-MsiexecUninstallNotes {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            $item = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if (-not $item) { return }
            $name = [string]$item.DisplayName
            if ($name -notmatch 'HCL Notes') { return }
            $guid = $_.PSChildName
            if ($guid -notmatch '^\{[0-9A-Fa-f-]+\}$') { return }
            Write-Host "msiexec /x $guid ($name)"
            $p = Start-Process -FilePath 'msiexec.exe' `
                -ArgumentList @('/x', $guid, '/qn', 'REBOOT=ReallySuppress') `
                -Wait -PassThru -NoNewWindow
            if ($p -and $p.ExitCode -ne 0 -and $p.ExitCode -ne 1605 -and $p.ExitCode -ne 3010) {
                Write-Warning "msiexec /x $guid exit $($p.ExitCode)"
            }
        }
    }
}

function Remove-PathIfExists {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Write-Host "Tar bort: $Path"
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Kunde inte ta bort $Path : $($_.Exception.Message)"
    }
}

Write-Host '==> Intune uninstall: HCL Notes'
Write-Host "64-bit PowerShell = $([Environment]::Is64BitProcess)"
Stop-NotesProcesses

$nice = Find-NiceExe
if ($nice) {
    Write-Host "NICE: $nice"
    $p = Start-Process -FilePath $nice -ArgumentList @('-rp', '/qn') `
        -WorkingDirectory (Split-Path -Parent $nice) -Wait -PassThru -NoNewWindow
    if ($p -and $p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Warning "NICE exit $($p.ExitCode) - fortsatter med msiexec"
    }
}
else {
    Write-Host 'NICE saknas (lagg NICE_x64.exe i paketet eller behall C:\install\Notes-1451).'
}

Invoke-MsiexecUninstallNotes
Stop-NotesProcesses

$paths = @(
    'C:\ProgramData\HCL\Notes',
    'C:\ProgramData\IBM\Notes',
    'C:\ProgramData\Lotus\Notes',
    (Join-Path ${env:ProgramFiles} 'HCL\Notes')
)
foreach ($p in $paths) {
    Remove-PathIfExists -Path $p
}

$desk = Join-Path $env:PUBLIC 'Desktop\HCL Notes.lnk'
Remove-PathIfExists -Path $desk
$sm = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\HCL Applications'
if (Test-Path -LiteralPath $sm) {
    Remove-PathIfExists -Path (Join-Path $sm 'Notes Minder.lnk')
    Remove-PathIfExists -Path (Join-Path $sm 'Support')
}

Write-Host 'Intune uninstall klar'
exit 0
