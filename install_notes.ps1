#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installerar HCL Notes 14.5.1 (multi-user), FP1, svenskt language pack
  samt kopierar in SetupNotes.txt efter NICE-rensning.

.DESCRIPTION
  PowerShell-motsvarighet till äldre CMD-flöde för Notes 12.x.
  Anpassa filnamnen under param()-blocket till era faktiska mediafiler.

.NOTES
  Kör som Administrator (krävs för NICE, MSI per-machine, hosts, ProgramData).
#>

[CmdletBinding()]
param(
    # Kit-rot: Notes-1451\ (innehalle Notes_1451_Win64_Swedish + SupportFiles)
    # Default nar scriptet ligger i SupportFiles\scripts\: farforaldern till SupportFiles
    [string]$MediaRoot = $(
        $here = $PSScriptRoot
        if ((Split-Path -Leaf $here) -ieq 'scripts') {
            $parent = Split-Path -Parent $here
            if ((Split-Path -Leaf $parent) -ieq 'SupportFiles') {
                Split-Path -Parent $parent
            }
            elseif (Test-Path -LiteralPath (Join-Path $parent 'SupportFiles')) {
                $parent
            }
            else {
                $parent
            }
        }
        else {
            $here
        }
    ),

    # Swedish | English -> val av undermapp + MSI-namn
    [ValidateSet('Swedish', 'English')]
    [string]$NotesEdition = 'Swedish',

    # Override om ni byter mappnamn (annars satts fran NotesEdition)
    [string]$NotesKitRel = '',
    [string]$NotesMsi = '',
    [string]$NotesSetupExe = 'setup.exe',

    # Custom MST (tom = ingen). HCL:s 1053.mst i kitet ar spraktransform, inte er paketering.
    [string]$NotesMst = '',

    # SupportFiles-relativa sokvagar (fran MediaRoot / kit-rot)
    [string]$NiceExe = 'SupportFiles\x64\NICE_x64.exe',
    [string]$FixPackDir = 'SupportFiles\Notes_1451FP1_x64',
    # Uppackat MUI (rekommenderat): ...\Notes_1451_x64_MUI\MUI.msi.w64.nl2a\setup.exe
    [string]$MuiRoot = 'SupportFiles\Notes_1451_x64_MUI',
    [string]$MuiGroup2aDir = 'SupportFiles\Notes_1451_x64_MUI\MUI.msi.w64.nl2a',
    # Fallback om .exe fortfarande ligger ouppackade
    [string]$MuiGroup2aExe = 'SupportFiles\Notes_1451_x64_MUI\MUI.msi.w64.nl2a.exe',
    [string]$MuiExe = 'SupportFiles\Notes_1451_x64_MUI\notes1451_notes_windows_prod_x64.exe',
    [string]$MuiLanguage = 'Swedish',
    [string]$SetupNotesFile = 'SupportFiles\SetupNotes.txt',
    # Valfri mall som mergas in i ProgramData notes.ini (ConfigFile sattes separat)
    [string]$SharedNotesIniSource = 'SupportFiles\x64\Notes.ini',

    [switch]$UseMsiexecDirect,

    [string]$SetupNotesTargetDir = (Join-Path ${env:ProgramFiles} 'HCL\Notes\license'),
    [string]$SharedDataDir = 'C:\ProgramData\HCL\Notes\Data',

    # SetupNotes Domino-falt (uppdateras vid kopia, oberoende av hosts)
    # -DominoAddress tom + -HostsName satt => Domino.Address = HostsName
    [string]$DominoName = '',      # t.ex. Zeus/TUVAN
    [string]$DominoAddress = '',   # t.ex. zeus eller zeus.domain.se

    # Opt-in: lagg till IP/namn i local hosts (default: gor ingenting)
    [switch]$AddToHostsAsSetupServer,
    [string]$HostsIp = '',
    [string]$HostsName = '',

    [string]$LocalMediaRoot = 'C:\install\Notes-1451',
    [switch]$SkipLocalMirror,

    # VC++ 2015-2022 (vcruntime140_1.dll). Lag vc_redist.x64.exe + vc_redist.x86.exe i mappen.
    [string]$VcRedistDir = 'SupportFiles\vcredist',
    [switch]$SkipVcRedist,

    [switch]$SkipNice,
    [switch]$SkipResidualCleanup,
    # Hoppa over rensning av rcpInstallerTemp.properties i TEMP (Notes 14.5.1-bug)
    [switch]$SkipRcpTempCleanup,
    [switch]$SkipFixPack,
    # Explicit: hoppa over MST aven om -NotesMst angetts
    [switch]$SkipMst,
    # Engelskt bas-kit + MUI. Svenskt kit: behoovs normalt inte.
    [switch]$InstallLanguagePack,
    # Tvinga notes.ini-patch aven om custom MST anvands
    [switch]$PatchNotesIni,
    [switch]$RunCompact,
    # Behall Notes Minder / NSD / skrivbordsikon HCL Notes
    [switch]$SkipShortcutCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Mindre mojibake i Windows PowerShell 5.1-konsol
try {
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = $utf8
    $OutputEncoding = $utf8
    chcp 65001 | Out-Null
} catch {}

# Lokal staging for exe fran natverk (Y:\, UNC) - undviker Access denied / MOTW
$script:LocalStageDir = Join-Path $env:TEMP 'HCL_Notes_MediaStage'

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function ConvertTo-Win32Path {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.Trim()
    # Resolve-Path .Path pa UNC blir Microsoft.PowerShell.Core\FileSystem::\\server\share
    # Win32 Start-Process / setup.exe hittar inte den formen.
    $marker = 'FileSystem::'
    $idx = $p.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
    if ($idx -ge 0) {
        $p = $p.Substring($idx + $marker.Length)
    }
    return $p
}

function Get-ProviderPath {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-Path -LiteralPath $Path
    if ($resolved.ProviderPath) {
        return $resolved.ProviderPath
    }
    return (ConvertTo-Win32Path -Path $resolved.Path)
}

function Test-IsNetworkPath {
    param([Parameter(Mandatory)][string]$Path)
    $p = ConvertTo-Win32Path -Path $Path
    if ($p.StartsWith('\\')) { return $true }
    $root = [System.IO.Path]::GetPathRoot($p)
    if ([string]::IsNullOrEmpty($root) -or $root.Length -lt 2) { return $false }
    $letter = $root.Substring(0, 1)
    $drive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    if ($null -eq $drive) { return $false }
    # Mapped network drives have DisplayRoot like \\server\share
    return -not [string]::IsNullOrEmpty($drive.DisplayRoot)
}

function Get-MediaPath {
    param([string]$FileName)
    $path = Join-Path $MediaRoot $FileName
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Saknar mediafil: $path"
    }
    return (Get-ProviderPath -Path $path)
}

function Sync-MediaRootToLocal {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Write-Step "Speglar media fran natverk till lokal disk"
    Write-Host "Fran: $Source"
    Write-Host "Till: $Destination"

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    # robocopy: exit 0-7 = OK (filer kopierade/skipped), >=8 = fel
    $rcArgs = @(
        $Source.TrimEnd('\'),
        $Destination.TrimEnd('\'),
        '/E',      # inkl. undermappar
        '/R:2',
        '/W:2',
        '/XO',     # hoppa over aldre/samma destination
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
    )
    $rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rcArgs -Wait -PassThru -NoNewWindow
    if ($rc.ExitCode -ge 8) {
        throw "robocopy misslyckades med exit code $($rc.ExitCode)"
    }

    Write-Host "Tar bort Mark of the Web (Unblock) pa lokala filer..."
    Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {}
        }

    return (Get-ProviderPath -Path $Destination)
}

function Get-RunnablePath {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [switch]$StageLocally
    )

    try { Unblock-File -LiteralPath $FilePath -ErrorAction SilentlyContinue } catch {}

    # Stage bara nar det efterfragas (NICE/FP1). setup.exe maste ligga kvar bredvid MSI/MST.
    if (-not $StageLocally) {
        return $FilePath
    }

    New-Item -ItemType Directory -Path $script:LocalStageDir -Force | Out-Null
    $dest = Join-Path $script:LocalStageDir (Split-Path -Leaf $FilePath)
    Write-Host "Kopierar till lokal temp (natverkskorning): $dest"
    Copy-Item -LiteralPath $FilePath -Destination $dest -Force
    try { Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue } catch {}
    return $dest
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$DisplayName = $FilePath,
        [switch]$StageLocally
    )

    $runPath = ConvertTo-Win32Path -Path (Get-RunnablePath -FilePath $FilePath -StageLocally:$StageLocally)
    $workDir = ConvertTo-Win32Path -Path (Split-Path -Parent $runPath)

    Write-Host "Kor: $DisplayName"
    Write-Host "     $runPath $($ArgumentList -join ' ')"

    try {
        $p = Start-Process -FilePath $runPath -ArgumentList $ArgumentList `
            -WorkingDirectory $workDir -Wait -PassThru -NoNewWindow
    }
    catch {
        throw @"
Kunde inte starta $DisplayName ($runPath).
$($_.Exception.Message)

Vanliga orsaker fran Y:\ / natverk:
- PowerShell inte elevated (Kor som administratör)
- EXE blockerad: Unblock-File .\fil.exe
- Kopiera media till t.ex. C:\install och kor -MediaRoot 'C:\install'
"@
    }

    if ($null -eq $p) {
        throw "$DisplayName returnerade ingen processinformation."
    }
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        # 3010 = lyckad, omstart kravs
        throw "$DisplayName misslyckades med exit code $($p.ExitCode)"
    }
    if ($p.ExitCode -eq 3010) {
        Write-Warning "$DisplayName rapporterade att omstart kravs (3010)."
    }
    return $p.ExitCode
}

function Resolve-FixPackSetup {
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$FixPackDir
    )

    $candidates = @(
        (Join-Path $MediaRoot (Join-Path $FixPackDir 'setup.exe')),
        (Join-Path $MediaRoot 'SupportFiles\Notes_1451FP1_x64\setup.exe'),
        (Join-Path $MediaRoot 'Notes_1451FP1_x64\setup.exe'),
        (Join-Path $MediaRoot 'FP1\setup.exe')
    )

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            return (Get-ProviderPath -Path $c)
        }
    }
    return $null
}

function Resolve-NotesEditionPaths {
    param(
        [Parameter(Mandatory)][string]$Edition,
        [string]$KitRel,
        [string]$MsiName
    )

    if ([string]::IsNullOrWhiteSpace($KitRel) -or [string]::IsNullOrWhiteSpace($MsiName)) {
        switch ($Edition) {
            'English' {
                if ([string]::IsNullOrWhiteSpace($KitRel)) { $KitRel = 'Notes_1451_Win64_English' }
                if ([string]::IsNullOrWhiteSpace($MsiName)) { $MsiName = 'HCL Notes 14.5.1 x64.msi' }
            }
            default {
                if ([string]::IsNullOrWhiteSpace($KitRel)) { $KitRel = 'Notes_1451_Win64_Swedish' }
                if ([string]::IsNullOrWhiteSpace($MsiName)) { $MsiName = 'HCL Notes 14.5.1 x64.msi' }
            }
        }
    }

    return [pscustomobject]@{
        KitRel  = $KitRel
        MsiName = $MsiName
    }
}

function Invoke-ProcessArguments {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $FilePath = ConvertTo-Win32Path -Path $FilePath
    $WorkingDirectory = ConvertTo-Win32Path -Path $WorkingDirectory

    Write-Host "Kor: $DisplayName"
    Write-Host "     $FilePath $Arguments"
    Write-Host "     cwd: $WorkingDirectory"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $proc.WaitForExit()
    return $proc.ExitCode
}

function Write-InstallLogNote {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message
    )

    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Invoke-NotesBaseInstall {
    param(
        [Parameter(Mandatory)][string]$KitDir,
        [Parameter(Mandatory)][string]$MsiPath,
        [Parameter(Mandatory)][string]$SetupPath,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$MsiProps,
        [Parameter(Mandatory)][string]$ScriptLogPath,
        [string]$MstPath = '',
        [switch]$PreferMsiexec
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
    # Skapa filen direkt sa det alltid finns nagot att oppna vid felsokning
    Write-InstallLogNote -Path $ScriptLogPath -Message "Base install start. MSI=$MsiPath"
    Write-InstallLogNote -Path $ScriptLogPath -Message "MSI log target: $LogPath"
    if (-not (Test-Path -LiteralPath $LogPath)) {
        Set-Content -LiteralPath $LogPath -Value "MSI log created by install_notes.ps1 $(Get-Date -Format o)`r`n" -Encoding ASCII
    }

    # InstallShield /v: undvik * i /l*v (kan tolkas fel) - anvand /lv
    # Inga nasta citat. Loggsokvag utan mellanslag rekommenderas.
    $vInner = if ($MstPath) {
        "TRANSFORMS=`"$MstPath`" $MsiProps /qn /lv `"$LogPath`""
    }
    else {
        "$MsiProps /qn /lv `"$LogPath`""
    }

    if (-not $PreferMsiexec) {
        # En argumentstrang via ProcessStartInfo (mindre PS ArgumentList-strul)
        $setupArgs = "/s /v`"$vInner`""
        Write-InstallLogNote -Path $ScriptLogPath -Message "setup.exe args: $setupArgs"
        $code = Invoke-ProcessArguments -FilePath $SetupPath -Arguments $setupArgs `
            -WorkingDirectory $KitDir -DisplayName 'Notes setup.exe'

        Write-InstallLogNote -Path $ScriptLogPath -Message "setup.exe exit=$code; msiLogBytes=$((Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue).Length)"
        Write-Host "setup.exe exit=$code"
        Write-Host "MSI-logg: $LogPath (finns=$(Test-Path -LiteralPath $LogPath), size=$((Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue).Length))"

        if ($code -eq 0 -or $code -eq 3010) {
            if ($code -eq 3010) {
                Write-Warning 'Notes setup.exe rapporterade omstart (3010).'
            }
            return $code
        }

        Write-Warning "setup.exe exit $code - faller tillbaka till msiexec /i"
        Write-InstallLogNote -Path $ScriptLogPath -Message "Fallback to msiexec after setup exit $code"
    }

    # msiexec: en argumentstrang - /l*v fungerar har nar det inte gar via InstallShield /v
    $msiArgs = if ($MstPath) {
        "/i `"$MsiPath`" TRANSFORMS=`"$MstPath`" /qn REBOOT=ReallySuppress /l*v `"$LogPath`""
    }
    else {
        "/i `"$MsiPath`" /qn ALLUSERS=1 SETMULTIUSER=1 USENOTESFOREMAIL=0 USENOTESFORCALENDAR=0 USENOTESFORCONTACTS=0 REBOOT=ReallySuppress /l*v `"$LogPath`""
    }

    Write-InstallLogNote -Path $ScriptLogPath -Message "msiexec args: $msiArgs"
    $code2 = Invoke-ProcessArguments -FilePath 'msiexec.exe' -Arguments $msiArgs `
        -WorkingDirectory $KitDir -DisplayName 'Notes msiexec'

    Write-InstallLogNote -Path $ScriptLogPath -Message "msiexec exit=$code2; msiLogBytes=$((Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue).Length)"
    Write-Host "msiexec exit=$code2"
    Write-Host "MSI-logg: $LogPath (finns=$(Test-Path -LiteralPath $LogPath), size=$((Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue).Length))"

    if ($code2 -ne 0 -and $code2 -ne 3010) {
        throw @"
Notes-basinstall misslyckades (msiexec exit $code2).
MSI:
  $MsiPath
Script-logg (finns alltid):
  $ScriptLogPath
MSI-logg:
  $LogPath
"@
    }
    if ($code2 -eq 3010) {
        Write-Warning 'Notes msiexec rapporterade omstart (3010).'
    }
    return $code2
}

function Invoke-NotesFixPackSilent {
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$FixPackDir,
        [Parameter(Mandatory)][string]$LogPath
    )

    $notesRunning = @(Get-Process -Name 'notes','nlnotes','notes2' -ErrorAction SilentlyContinue)
    if ($notesRunning.Count -gt 0) {
        Write-Warning 'Notes kor fortfarande. Stang klienten innan FP1 - annars kan en dialog visas trots /qn.'
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null

    $setup = Resolve-FixPackSetup -MediaRoot $MediaRoot -FixPackDir $FixPackDir
    if (-not $setup) {
        throw @"
Hittar inte uppackat FP1-kit (setup.exe).
Forvantar t.ex.:
  $(Join-Path $MediaRoot (Join-Path $FixPackDir 'setup.exe'))

Packa upp Notes_1451FP1_x64.exe manuellt en gang och distribuera mappen
Notes_1451FP1_x64\ (med setup.exe) i mediakitet.
"@
    }

    $setupDir = Split-Path -Parent $setup
    Write-Host "Uppackat FP1: $setupDir"

    # HCL: setup.exe /s /v"/qn ..."  - kor exe direkt (undvik cmd-citatfel)
    # Loggsokvag utan egna citat inuti /v (annars blir det /l*v "path"")
    $vArgs = "/qn REBOOT=ReallySuppress /l*v $LogPath"
    Write-Host "Kor: Notes FP1 (setup.exe /s /v`"$vArgs`")"
    Write-Host "     $setup"

    $p = Start-Process -FilePath $setup `
        -ArgumentList @('/s', "/v`"$vArgs`"") `
        -WorkingDirectory $setupDir `
        -Wait -PassThru -NoNewWindow

    if ($null -eq $p) {
        throw 'Notes FP1 returnerade ingen processinformation.'
    }

    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Write-Warning "setup.exe /v`"/qn...`" exit $($p.ExitCode) - provar /s /v/qn"
        $p = Start-Process -FilePath $setup `
            -ArgumentList @('/s', '/v/qn') `
            -WorkingDirectory $setupDir `
            -Wait -PassThru -NoNewWindow
    }

    if ($null -eq $p -or ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010)) {
        $code = if ($p) { $p.ExitCode } else { 'null' }
        throw @"
Notes FP1 misslyckades (exit $code).
Testa manuellt i elevated CMD:

  cd /d $setupDir
  setup.exe /s /v"/qn REBOOT=ReallySuppress /l*v $LogPath"
"@
    }

    if ($p.ExitCode -eq 3010) {
        Write-Warning 'Notes FP1 rapporterade att omstart kravs (3010).'
    }
    return $p.ExitCode
}

function Stop-NotesProcesses {
    foreach ($name in @('notes', 'nlnotes', 'notes2', 'ntaskldr', 'nminder')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "Stoppar process: $($_.Name) (PID $($_.Id))"
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
    }
}

function Get-LnkTargetPath {
    param([Parameter(Mandatory)][string]$LnkPath)
    $shell = New-Object -ComObject WScript.Shell
    try {
        $lnk = $shell.CreateShortcut($LnkPath)
        return [string]$lnk.TargetPath
    }
    catch {
        return ''
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

function Remove-NotesUnwantedItem {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    Write-Host "Tar bort: $Path"
    try {
        if ($Recurse) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        else {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-Warning "Kunde inte ta bort ${Path}: $($_.Exception.Message)"
        return $false
    }
}

function Test-UnwantedNotesShortcut {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Lnk,
        [switch]$IncludeNotesClient
    )
    if ($Lnk.BaseName -match '(?i)notes\s*minder') { return $true }
    if ($IncludeNotesClient -and $Lnk.BaseName -match '(?i)^(hcl\s+)?(lotus\s+)?notes$') { return $true }
    $target = Get-LnkTargetPath -LnkPath $Lnk.FullName
    if ($target -match '(?i)\\(nminder|nsd)\.exe$') { return $true }
    if ($IncludeNotesClient -and $target -match '(?i)\\(notes|nlnotes)\.exe$') { return $true }
    return $false
}

function Remove-NotesUnwantedShortcuts {
    Write-Step 'Tar bort genvagar (Notes Minder, NSD Support, skrivbord HCL Notes)'

    $programRoots = New-Object System.Collections.Generic.List[string]
    $desktopRoots = New-Object System.Collections.Generic.List[string]
    $programRoots.Add((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))
    $desktopRoots.Add('C:\Users\Public\Desktop')
    if ($env:PUBLIC) {
        $pubDesk = Join-Path $env:PUBLIC 'Desktop'
        if ($pubDesk -ne 'C:\Users\Public\Desktop') {
            $desktopRoots.Add($pubDesk)
        }
    }

    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (Test-Path -LiteralPath $usersRoot) {
        Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('All Users', 'Default User') } |
            ForEach-Object {
                $programRoots.Add((Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'))
                $desktopRoots.Add((Join-Path $_.FullName 'Desktop'))
            }
    }

    $removed = 0
    foreach ($root in $programRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($appName in @('HCL Applications', 'Lotus Applications')) {
            $appDir = Join-Path $root $appName
            if (-not (Test-Path -LiteralPath $appDir)) { continue }

            $supportDir = Join-Path $appDir 'Support'
            if (Test-Path -LiteralPath $supportDir) {
                if (Remove-NotesUnwantedItem -Path $supportDir -Recurse) { $removed++ }
            }

            Get-ChildItem -LiteralPath $appDir -Filter '*.lnk' -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if (Test-UnwantedNotesShortcut -Lnk $_) {
                        if (Remove-NotesUnwantedItem -Path $_.FullName) { $removed++ }
                    }
                }
        }
    }

    foreach ($desk in $desktopRoots) {
        if (-not (Test-Path -LiteralPath $desk)) { continue }
        foreach ($name in @('HCL Notes.lnk', 'Notes.lnk', 'Lotus Notes.lnk')) {
            $exact = Join-Path $desk $name
            if (Test-Path -LiteralPath $exact) {
                if (Remove-NotesUnwantedItem -Path $exact) { $removed++ }
            }
        }
        Get-ChildItem -LiteralPath $desk -Filter '*.lnk' -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                if (Test-UnwantedNotesShortcut -Lnk $_ -IncludeNotesClient) {
                    if (Remove-NotesUnwantedItem -Path $_.FullName) { $removed++ }
                }
            }
    }

    Write-Host "Tog bort $removed genvag(ar)/mapp(ar). notes.exe/nminder.exe/nsd.exe lamnas kvar."
}

function Remove-RcpInstallerTempProperties {
    <#
      Notes 14.5.1: kvarlamnad rcpInstallerTemp.properties i TEMP for kontot som kor
      installen kan fa MSI att lyckas men ta bort optional RCP-komponenter (t.ex. Sametime),
      eller sabontera uppgradering. Rensa innan setup.exe/msiexec.
      Se HCL KB0132505 / panagenda.
    #>
    Write-Step 'Rensar rcpInstallerTemp.properties i TEMP'

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
            $env:TEMP,
            $env:TMP,
            $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Temp' } else { $null }),
            $(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'Temp' } else { $null }),
            'C:\Windows\Temp'
        )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $roots.Add($candidate)
        }
    }

    # Andra anvandarprofiler (viktigt om tidigare install korde som annan admin/SYSTEM)
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (Test-Path -LiteralPath $usersRoot) {
        Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $roots.Add((Join-Path $_.FullName 'AppData\Local\Temp'))
            }
    }

    $uniqueRoots = $roots | Where-Object { $_ } | Select-Object -Unique
    $removed = 0

    foreach ($root in $uniqueRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        # Snabb trad: fil direkt i TEMP + en niva ned (GUID-mappar), undvik djup recurse
        $hits = @()
        $direct = Join-Path $root 'rcpInstallerTemp.properties'
        if (Test-Path -LiteralPath $direct) {
            $hits += Get-Item -LiteralPath $direct -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $nested = Join-Path $_.FullName 'rcpInstallerTemp.properties'
                if (Test-Path -LiteralPath $nested) {
                    $hits += Get-Item -LiteralPath $nested -Force -ErrorAction SilentlyContinue
                }
            }

        foreach ($file in $hits) {
            if (-not $file) { continue }
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-Host "Tog bort: $($file.FullName)"
                $removed++
            }
            catch {
                Write-Warning "Kunde inte ta bort $($file.FullName): $($_.Exception.Message)"
            }
        }
    }

    if ($removed -eq 0) {
        Write-Host 'Ingen rcpInstallerTemp.properties hittades (OK).'
    }
    else {
        Write-Host "Tog bort $removed rcpInstallerTemp.properties."
    }
}

function Remove-PathIfExists {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Finns ej: $Path"
        return
    }

    Write-Host "Tar bort: $Path"
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        # Lasta filer / ACL - forsok ta agandeskap och radera igen
        Write-Warning "Forsta forsoket misslyckades: $($_.Exception.Message)"
        try {
            $null = cmd.exe /c "takeown /f `"$Path`" /r /d y >nul 2>&1"
            $null = cmd.exe /c "icacls `"$Path`" /grant administrators:F /t /c /q >nul 2>&1"
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Host "Borttaget efter takeown/icacls: $Path"
        }
        catch {
            Write-Warning "Kunde inte ta bort: $Path - $($_.Exception.Message)"
        }
    }
}

function Clear-NotesResiduals {
    # NICE i multi-user: "Remove data files" ar avstangt.
    # Shared templates/notes.ini under ProgramData blir kvar - rensa explicit.
    Write-Step 'Rensar kvarvarande Notes-kataloger (ProgramData Shared m.m.)'
    Stop-NotesProcesses

    $paths = @(
        'C:\ProgramData\HCL\Notes',
        'C:\ProgramData\IBM\Notes',
        'C:\ProgramData\Lotus\Notes',
        (Join-Path ${env:ProgramFiles} 'HCL\Notes'),
        (Join-Path ${env:ProgramFiles} 'IBM\Notes'),
        (Join-Path ${env:ProgramFiles} 'Lotus\Notes')
    )
    if (${env:ProgramFiles(x86)}) {
        $paths += @(
            (Join-Path ${env:ProgramFiles(x86)} 'HCL\Notes'),
            (Join-Path ${env:ProgramFiles(x86)} 'IBM\Notes'),
            (Join-Path ${env:ProgramFiles(x86)} 'Lotus\Notes')
        )
    }

    foreach ($p in $paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        Remove-PathIfExists -Path $p
    }
}

function Ensure-HostsEntry {
    param(
        [string]$Ip,
        [string]$HostName
    )

    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $content = Get-Content -LiteralPath $hostsPath -ErrorAction Stop
    $pattern = "^\s*$([regex]::Escape($Ip))\s+$([regex]::Escape($HostName))(\s|$)"

    if ($content | Where-Object { $_ -match $pattern }) {
        Write-Host "Hosts innehaller redan $Ip $HostName"
        return
    }

    Write-Host "Lagger till $Ip`t$HostName i hosts"
    Add-Content -LiteralPath $hostsPath -Value "`r`n$Ip`t$HostName" -Encoding ascii
}

function Set-FlatConfigValue {
    # SetupNotes.txt = platta Key=Value-rader (ingen [section])
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Saknar fil att uppdatera: $Path"
    }

    $lines = Get-Content -LiteralPath $Path
    $out = New-Object System.Collections.Generic.List[string]
    $keyWritten = $false

    foreach ($line in $lines) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=") {
            $out.Add("$Key=$Value")
            $keyWritten = $true
        }
        else {
            $out.Add($line)
        }
    }

    if (-not $keyWritten) {
        $out.Add("$Key=$Value")
    }

    Set-Content -LiteralPath $Path -Value $out -Encoding ascii
    Write-Host "  $Key=$Value"
}

function Update-SetupNotesDominoSettings {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$DominoName,
        [string]$DominoAddress,
        [string]$HostsName
    )

    $address = $DominoAddress
    if ([string]::IsNullOrWhiteSpace($address) -and -not [string]::IsNullOrWhiteSpace($HostsName)) {
        $address = $HostsName
    }

    $changed = $false
    if (-not [string]::IsNullOrWhiteSpace($DominoName)) {
        Set-FlatConfigValue -Path $Path -Key 'Domino.Name' -Value $DominoName
        $changed = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($address)) {
        Set-FlatConfigValue -Path $Path -Key 'Domino.Address' -Value $address
        $changed = $true
    }

    if (-not $changed) {
        Write-Host 'SetupNotes Domino.Name/Address andrades inte (ange -DominoName / -DominoAddress eller -HostsName).'
    }
    elseif ([string]::IsNullOrWhiteSpace($DominoName)) {
        Write-Warning 'Domino.Address uppdaterad men Domino.Name saknas - ange t.ex. -DominoName ''Zeus/TUVAN''.'
    }
}

function Get-NotesIniPath {
    # Multi-user: NotesIniPath ligger typiskt under HKCU efter forsta anvandarsetup,
    # men shared notes.ini skapas under ProgramData vid installation.
    # StrictMode: testa property via PSObject - saknad NotesIniPath far inte kasta.
    $candidates = @(
        'HKCU:\Software\HCL\Notes',
        'HKCU:\Software\Lotus\Notes',
        'HKLM:\SOFTWARE\WOW6432Node\HCL\Notes',
        'HKLM:\SOFTWARE\WOW6432Node\Lotus\Notes',
        'HKLM:\SOFTWARE\HCL\Notes',
        'HKLM:\SOFTWARE\Lotus\Notes'
    )

    foreach ($key in $candidates) {
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        $prop = $item.PSObject.Properties['NotesIniPath']
        if ($prop -and $prop.Value -and (Test-Path -LiteralPath ([string]$prop.Value))) {
            return [string]$prop.Value
        }
    }

    $sharedIni = Join-Path $SharedDataDir 'notes.ini'
    if (Test-Path -LiteralPath $sharedIni) {
        return $sharedIni
    }

    return $null
}

function Get-IniValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    $inSection = $false
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]$') {
            $inSection = ($Matches[1] -ieq $Section)
            continue
        }
        if (-not $inSection) { continue }
        if ($trim -match '^\s*[;#]') { continue }
        if ($trim -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Set-IniValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Saknar notes.ini att uppdatera: $Path"
    }

    $lines = Get-Content -LiteralPath $Path
    $out = New-Object System.Collections.Generic.List[string]
    $inSection = $false
    $sectionFound = $false
    $keyWritten = $false

    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim -match '^\[(.+)\]$') {
            if ($inSection -and -not $keyWritten) {
                $out.Add("$Key=$Value")
                $keyWritten = $true
            }
            $inSection = ($Matches[1] -ieq $Section)
            if ($inSection) { $sectionFound = $true }
            $out.Add($line)
            continue
        }

        if ($inSection -and $trim -match "^\s*$([regex]::Escape($Key))\s*=") {
            $out.Add("$Key=$Value")
            $keyWritten = $true
            continue
        }

        $out.Add($line)
    }

    if ($inSection -and -not $keyWritten) {
        $out.Add("$Key=$Value")
        $keyWritten = $true
    }

    if (-not $sectionFound) {
        $out.Add("[$Section]")
        $out.Add("$Key=$Value")
    }

    Set-Content -LiteralPath $Path -Value $out -Encoding ascii
    Write-Host "  [$Section] $Key=$Value"
}

function Test-Vcruntime140_1 {
    param([Parameter(Mandatory)][ValidateSet('x64', 'x86')][string]$Arch)
    if ($Arch -eq 'x64') {
        return (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\vcruntime140_1.dll'))
    }
    return (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'SysWOW64\vcruntime140_1.dll'))
}

function Find-VcRedistSetup {
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$VcRedistDir,
        [Parameter(Mandatory)][string]$FileName
    )
    foreach ($c in @(
            (Join-Path $MediaRoot (Join-Path $VcRedistDir $FileName)),
            (Join-Path $MediaRoot "SupportFiles\$FileName")
        )) {
        if (Test-Path -LiteralPath $c) {
            return (Get-ProviderPath -Path $c)
        }
    }
    return $null
}

function Save-VcRedistFromWeb {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$FileName
    )
    $dest = Join-Path $env:TEMP $FileName
    Write-Host "Laddar ner $Url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing
    }
    catch {
        throw "Kunde inte ladda ner $FileName ($Url). $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $dest) -or ((Get-Item -LiteralPath $dest).Length -lt 1MB)) {
        throw "Nedladdning av $FileName blev for liten / saknas: $dest"
    }
    return $dest
}

function Install-OneVcRedist {
    param(
        [Parameter(Mandatory)][string]$SetupExe,
        [Parameter(Mandatory)][string]$DisplayName
    )
    $SetupExe = ConvertTo-Win32Path -Path $SetupExe
    Write-Host "Kor: $DisplayName"
    Write-Host "     $SetupExe /install /quiet /norestart"
    $p = Start-Process -FilePath $SetupExe -ArgumentList @('/install', '/quiet', '/norestart') `
        -Wait -PassThru -NoNewWindow
    $code = if ($p) { $p.ExitCode } else { $null }
    # 0 = ok, 1638 = nyare/samma redan installerad, 3010 = reboot
    if ($null -eq $code -or ($code -ne 0 -and $code -ne 1638 -and $code -ne 3010)) {
        throw "$DisplayName misslyckades (exit $code)"
    }
    if ($code -eq 3010) {
        Write-Warning "$DisplayName rapporterade omstart (3010)."
    }
}

function Install-NotesVcRedist {
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][string]$VcRedistDir
    )

    Write-Step 'Visual C++ Redistributable 2015-2022 (vcruntime140_1.dll)'
    $needX64 = -not (Test-Vcruntime140_1 -Arch 'x64')
    $needX86 = -not (Test-Vcruntime140_1 -Arch 'x86')
    if (-not $needX64 -and -not $needX86) {
        Write-Host 'vcruntime140_1.dll finns redan (x64 + x86). Hoppar over.'
        return
    }

    $jobs = @()
    if ($needX64) {
        $jobs += [pscustomobject]@{
            Arch    = 'x64'
            File    = 'vc_redist.x64.exe'
            Url     = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
            Display = 'VC++ Redistributable x64'
        }
    }
    if ($needX86) {
        $jobs += [pscustomobject]@{
            Arch    = 'x86'
            File    = 'vc_redist.x86.exe'
            Url     = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
            Display = 'VC++ Redistributable x86'
        }
    }

    foreach ($job in $jobs) {
        $setup = Find-VcRedistSetup -MediaRoot $MediaRoot -VcRedistDir $VcRedistDir -FileName $job.File
        if (-not $setup) {
            Write-Warning "Saknar $($job.File) i $VcRedistDir - provar Microsoft-nedladdning."
            $setup = Save-VcRedistFromWeb -Url $job.Url -FileName $job.File
        }
        Install-OneVcRedist -SetupExe $setup -DisplayName $job.Display
    }

    if (-not (Test-Vcruntime140_1 -Arch 'x64')) {
        throw @"
VCRUNTIME140_1.dll saknas fortfarande i System32 efter VC++-install.

Lagg vc_redist.x64.exe + vc_redist.x86.exe i:
  $(Join-Path $MediaRoot $VcRedistDir)

Ladda ner:
  https://aka.ms/vs/17/release/vc_redist.x64.exe
  https://aka.ms/vs/17/release/vc_redist.x86.exe

Kor elevated: vc_redist.x64.exe /install /quiet /norestart
"@
    }
    Write-Host 'VC++ Redistributable installerad / redan pa plats.'
}

function Resolve-KitMediaRoot {
    param([Parameter(Mandatory)][string]$Path)

    $raw = $Path.Trim()
    $expanded = [Environment]::ExpandEnvironmentVariables($raw)
    $userTempKit = Join-Path $env:TEMP 'Notes1451'
    $systemTempKit = Join-Path $env:SystemRoot 'Temp\Notes1451'

    # C:\Windows\%TEMP%\... blir C:\Windows\C:\Users\...\Temp\... efter expansion
    $concatenated = $expanded -match '^[A-Za-z]:\\Windows\\[A-Za-z]:\\'
    $windowsPctTemp = $raw -match '(?i)^[A-Za-z]:\\Windows\\%TEMP%'
    if ($concatenated -or $windowsPctTemp) {
        throw @"
MediaRoot ar en ogiltig hopklistrad sokvag: $raw

%TEMP% ar redan en hel katalog (just nu: $env:TEMP).
Skriv inte C:\Windows\%TEMP%\Notes1451

PowerShell:
  -MediaRoot `$env:TEMP\Notes1451
CMD:
  -MediaRoot "%TEMP%\Notes1451"
"@
    }

    if (-not (Test-Path -LiteralPath $expanded)) {
        throw @"
Hittar inte MediaRoot: $expanded
(angivet: $raw)

Konto-TEMP just nu: $env:TEMP
Forvantad kit-rot efter robocopy till %TEMP%: $userTempKit
PDQ som SYSTEM landar oftast har: $systemTempKit

I PowerShell expanderas inte %TEMP% - anvand `$env:TEMP.
Kontrollera: Test-Path `$env:TEMP\Notes1451
"@
    }

    return (Get-ProviderPath -Path $expanded)
}

# --- Start ---
Write-Step "HCL Notes 14.5.1 installationsflode"
Write-Host "Konto-TEMP = $env:TEMP"
$MediaRoot = Resolve-KitMediaRoot -Path $MediaRoot
Write-Host "MediaRoot (kit-rot) = $MediaRoot"

$editionPaths = Resolve-NotesEditionPaths -Edition $NotesEdition -KitRel $NotesKitRel -MsiName $NotesMsi
$NotesKitRel = $editionPaths.KitRel
$NotesMsi = $editionPaths.MsiName
$notesKitPath = Join-Path $MediaRoot $NotesKitRel
Write-Host "NotesEdition = $NotesEdition"
Write-Host "NotesKit = $notesKitPath"
Write-Host "NotesMsi = $NotesMsi"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Administrator = $isAdmin"
if (-not $isAdmin) {
    throw 'Skriptet maste koras som Administrator (hogerklicka PowerShell -> Kor som administratör).'
}

# setup.exe fran Z:\ / UNC ger Access denied - spegla hela kit-roten lokalt
if (-not $SkipLocalMirror -and (Test-IsNetworkPath -Path $MediaRoot)) {
    $MediaRoot = Sync-MediaRootToLocal -Source $MediaRoot -Destination $LocalMediaRoot
    $notesKitPath = Join-Path $MediaRoot $NotesKitRel
    Write-Host "MediaRoot (lokal) = $MediaRoot"
}

if (-not (Test-Path -LiteralPath $notesKitPath)) {
    throw "Saknar Notes-kitmapp: $notesKitPath"
}

$logDir = Join-Path $env:TEMP 'HCL_Notes_Install'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
New-Item -ItemType Directory -Path $script:LocalStageDir -Force | Out-Null

# Notes 14.5.1 Win64-kit kraver 64-bitars Windows (+ i praktiken Win10/11, inte Win7)
$os64 = [Environment]::Is64BitOperatingSystem
$osCaption = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
if (-not $osCaption) {
    $osCaption = (Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
}
Write-Host "OS = $osCaption ; 64-bit = $os64"
if (-not $os64) {
    throw 'Detta paket ar x64 (Notes_1451_Win64_* / FP1 x64) och kan inte installeras pa 32-bitars Windows.'
}
if ($osCaption -match 'Windows 7') {
    Write-Warning 'HCL Notes 14.5 stoder inte Windows 7. Installation kan misslyckas eller vara ospard.'
}

# 0) VC++ - Notes 14.x / nlnotes.exe kraver vcruntime140_1.dll (saknas pa naken Win10)
if (-not $SkipVcRedist) {
    Install-NotesVcRedist -MediaRoot $MediaRoot -VcRedistDir $VcRedistDir
}
else {
    Write-Host 'Hoppar over VC++ Redistributable (-SkipVcRedist)'
}

# NICE: valj x86-binar automatiskt om default-x64 angets pa (osannolik) 32-bitars host
if ($NiceExe -eq 'SupportFiles\x64\NICE_x64.exe' -and -not $os64) {
    $NiceExe = 'SupportFiles\x86\NICE_x86.exe'
}

# 1) NICE - SupportFiles\x64\NICE_x64.exe (eller x86)
if (-not $SkipNice) {
    Write-Step 'NICE: rensar tidigare Notes-installation'
    Stop-NotesProcesses
    $nice = Get-MediaPath $NiceExe
    # -rp = remove program files, /qn = quiet
    # Multi-user: NICE tar INTE bort ProgramData\...\Data\Shared (data-flaggan ar av).
    Invoke-External -FilePath $nice -ArgumentList @('-rp', '/qn') -DisplayName 'NICE'

    if (-not $SkipResidualCleanup) {
        Clear-NotesResiduals
    }
    else {
        Write-Host 'Hoppar over residual-rensning (-SkipResidualCleanup)'
    }
} else {
    Write-Host 'Hoppar over NICE (-SkipNice)'
}

# 2) Hosts - bara om -AddToHostsAsSetupServer (default: hoppa over)
if ($AddToHostsAsSetupServer) {
    Write-Step 'Lagger till setup-server i hosts [-AddToHostsAsSetupServer]'
    if ([string]::IsNullOrWhiteSpace($HostsIp) -or [string]::IsNullOrWhiteSpace($HostsName)) {
        throw '-AddToHostsAsSetupServer kraver -HostsIp och -HostsName'
    }
    Ensure-HostsEntry -Ip $HostsIp -HostName $HostsName
}
else {
    Write-Host 'Hoppar over hosts-fil (anvand -AddToHostsAsSetupServer -HostsIp ... -HostsName ... vid behov).'
}

# 2b) Notes 14.5.1: ta bort stale rcpInstallerTemp.properties innan setup/msiexec
if (-not $SkipRcpTempCleanup) {
    Remove-RcpInstallerTempProperties
}
else {
    Write-Host 'Hoppar over rcpInstallerTemp-rensning (-SkipRcpTempCleanup)'
}

# 3) Basinstallation Notes fran Notes_1451_Win64_Swedish|English
# Custom MST: ange -NotesMst 'SupportFiles\min.mst' (eller sokvag under kit-rot)
# Default: ingen custom MST - MSI public properties + notes.ini-patch
$useMst = -not $SkipMst -and -not [string]::IsNullOrWhiteSpace($NotesMst)

# MSI-filnamn maste matcha Setup.ini PackageName (standard: HCL Notes 14.5.1 x64.msi)
$msiRel = Join-Path $NotesKitRel $NotesMsi
$setupRel = Join-Path $NotesKitRel $NotesSetupExe
$msi = Get-MediaPath $msiRel
$setup = Get-MediaPath $setupRel
Write-Host "MSI for setup.exe = $NotesMsi"

# Loggar under SupportFiles\logs (skapas alltid)
$scriptLogDir = Join-Path $MediaRoot 'SupportFiles\logs'
New-Item -ItemType Directory -Path $scriptLogDir -Force | Out-Null
$msiLog = Join-Path $scriptLogDir 'HCL_Notes_1451.log'
$scriptLog = Join-Path $scriptLogDir 'install_notes_script.log'
Write-Host "Script-logg: $scriptLog"
Write-Host "MSI-logg:    $msiLog"
Write-InstallLogNote -Path $scriptLog -Message "=== install_notes.ps1 start MediaRoot=$MediaRoot Edition=$NotesEdition ==="

try {
    Start-Transcript -Path (Join-Path $scriptLogDir 'install_notes_transcript.log') -Append -ErrorAction SilentlyContinue | Out-Null
} catch {}

Write-Host "MSI = $msi"
Write-Host "setup.exe = $setup"
Get-ChildItem -LiteralPath $notesKitPath -Filter '*.msi' | ForEach-Object {
    Write-Host "  kit MSI: $($_.Name)"
    Write-InstallLogNote -Path $scriptLog -Message "kit MSI: $($_.FullName)"
}

$msiProps = @(
    'ALLUSERS=1',
    'SETMULTIUSER=1',
    'USENOTESFOREMAIL=0',
    'USENOTESFORCALENDAR=0',
    'USENOTESFORCONTACTS=0',
    'REBOOT=ReallySuppress'
) -join ' '

$mstPath = ''
if ($useMst) {
    Write-Step 'Installerar HCL Notes 14.5.1 (custom MST)'
    $mstPath = Get-MediaPath $NotesMst
}
else {
    Write-Step 'Installerar HCL Notes 14.5.1 (utan custom MST)'
    Write-Host "Properties: $msiProps"
}

try {
    Invoke-NotesBaseInstall `
        -KitDir $notesKitPath `
        -MsiPath $msi `
        -SetupPath $setup `
        -LogPath $msiLog `
        -ScriptLogPath $scriptLog `
        -MsiProps $msiProps `
        -MstPath $mstPath `
        -PreferMsiexec:$UseMsiexecDirect
}
catch {
    Write-InstallLogNote -Path $scriptLog -Message "ERROR: $($_.Exception.Message)"
    throw
}

# 4) SetupNotes.txt fran SupportFiles\ + ev. Domino.Name/Address fran parametrar
Write-Step 'Kopierar och uppdaterar SetupNotes.txt'
$setupSrc = Get-MediaPath $SetupNotesFile
New-Item -ItemType Directory -Path $SetupNotesTargetDir -Force | Out-Null
$setupDst = Join-Path $SetupNotesTargetDir 'SetupNotes.txt'
Copy-Item -LiteralPath $setupSrc -Destination $setupDst -Force
Write-Host "Kopierad till $setupDst"
# HostsName/Domino* uppdaterar SetupNotes oberoende av -AddToHostsAsSetupServer
Update-SetupNotesDominoSettings -Path $setupDst `
    -DominoName $DominoName `
    -DominoAddress $DominoAddress `
    -HostsName $HostsName

# 4b) notes.ini - default utan custom MST. Opt-in -PatchNotesIni med MST.
$doPatchIni = $PatchNotesIni -or (-not $useMst)
if ($doPatchIni) {
    Write-Step 'Patchar shared notes.ini (ProgramData)'
    $sharedIni = Join-Path $SharedDataDir 'notes.ini'

    # Om MSI inte skapat notes.ini an: seed fran SupportFiles\x64\Notes.ini
    if (-not (Test-Path -LiteralPath $sharedIni)) {
        $iniSeed = Join-Path $MediaRoot $SharedNotesIniSource
        if (Test-Path -LiteralPath $iniSeed) {
            New-Item -ItemType Directory -Path $SharedDataDir -Force | Out-Null
            Copy-Item -LiteralPath $iniSeed -Destination $sharedIni -Force
            Write-Host "Seedad notes.ini fran $iniSeed"
        }
    }

    if (-not (Test-Path -LiteralPath $sharedIni)) {
        Write-Warning "Hittar inte $sharedIni an - hoppar over ini-patch."
    }
    else {
        Set-IniValue -Path $sharedIni -Section 'Notes' -Key 'ConfigFile' -Value $setupDst
        Set-IniValue -Path $sharedIni -Section 'Notes' -Key 'Ports' -Value 'TCPIP'
        Set-IniValue -Path $sharedIni -Section 'Notes' -Key 'Disabled_Ports' -Value 'LAN0,COM1'
        Set-IniValue -Path $sharedIni -Section 'Notes' -Key 'ViewsCheckMarkSel' -Value '1'
        Set-IniValue -Path $sharedIni -Section 'Notes' -Key 'NoDelayedRemoteImages' -Value '1'
        Set-IniValue -Path $sharedIni -Section 'Notes' -Key 'DontCheckDefaultMail' -Value '1'
        Write-Host "Uppdaterad: $sharedIni"
    }
}
else {
    Write-Host 'Hoppar over notes.ini-patch (custom MST ansvarar). Anvand -PatchNotesIni vid behov.'
}

# 5) Fix Pack 1 - SupportFiles\Notes_1451FP1_x64\setup.exe
if (-not $SkipFixPack) {
    Write-Step 'Installerar Fix Pack 1 (tyst, uppackat kit)'
    $fpLogDir = Join-Path $MediaRoot 'SupportFiles\logs'
    New-Item -ItemType Directory -Path $fpLogDir -Force | Out-Null
    $fpLog = Join-Path $fpLogDir 'HCL_Notes_1451_FP1.log'
    Invoke-NotesFixPackSilent -MediaRoot $MediaRoot -FixPackDir $FixPackDir -LogPath $fpLog
} else {
    Write-Host 'Hoppar over FP1 (-SkipFixPack)'
}

# 6) MUI - uppackat Group2a (Swedish/Dutch). Cascaded .exe ar opalitlig; distribuera uppackat.
# Kor via cmd.exe. /L<lcid> undertrycker sprakval-dialog.
if ($InstallLanguagePack) {
    if ($NotesEdition -eq 'Swedish') {
        Write-Warning 'NotesEdition=Swedish inkluderar redan svenska. MUI behoovs normalt bara med -NotesEdition English.'
    }

    Write-Step "Installerar language pack (MUI $MuiLanguage)"
    $muiLog = Join-Path (Join-Path $MediaRoot 'SupportFiles\logs') 'HCL_Notes_1451_MUI.log'
    New-Item -ItemType Directory -Path (Split-Path -Parent $muiLog) -Force | Out-Null

    $muiLcid = switch ($MuiLanguage) {
        'Swedish' { '1053' }
        'Dutch'   { '1043' }
        default   { '1033' }
    }

    $muiCode = $null

    # 1) Uppackat Group2a: ...\MUI.msi.w64.nl2a\setup.exe
    $g2aDir = Join-Path $MediaRoot $MuiGroup2aDir
    $g2aSetup = Join-Path $g2aDir 'setup.exe'
    if (Test-Path -LiteralPath $g2aSetup) {
        $g2aCmd = "setup.exe /s /L$muiLcid /v`"/qn ADDLOCAL=$MuiLanguage REBOOT=ReallySuppress /l*v $muiLog`""
        Write-Host "Uppackat Group2a: $g2aDir"
        Write-Host "  $g2aCmd"
        $p = Start-Process -FilePath 'cmd.exe' `
            -ArgumentList @('/d', '/c', $g2aCmd) `
            -WorkingDirectory $g2aDir -Wait -PassThru -NoNewWindow
        $muiCode = if ($p) { $p.ExitCode } else { $null }
        Write-Host "Group2a setup.exe exit=$muiCode"

        # msiexec fallback pa MSI i samma mapp
        if ($null -eq $muiCode -or ($muiCode -ne 0 -and $muiCode -ne 3010)) {
            $g2aMsi = Get-ChildItem -LiteralPath $g2aDir -Filter '*.msi' -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($g2aMsi) {
                $msiCmd = "msiexec /i `"$($g2aMsi.FullName)`" /qn ADDLOCAL=$MuiLanguage REBOOT=ReallySuppress /l*v `"$muiLog`""
                Write-Host "Provar msiexec: $msiCmd"
                $p = Start-Process -FilePath 'cmd.exe' `
                    -ArgumentList @('/d', '/c', $msiCmd) `
                    -WorkingDirectory $g2aDir -Wait -PassThru -NoNewWindow
                $muiCode = if ($p) { $p.ExitCode } else { $null }
                Write-Host "Group2a msiexec exit=$muiCode"
            }
        }
    }

    # 2) Fallback: ouppackad Group2a .exe
    if ($null -eq $muiCode -or ($muiCode -ne 0 -and $muiCode -ne 3010)) {
        $g2aExe = Join-Path $MediaRoot $MuiGroup2aExe
        if (Test-Path -LiteralPath $g2aExe) {
            $exeDir = Split-Path -Parent $g2aExe
            $exeLeaf = Split-Path -Leaf $g2aExe
            $g2aCmd = "$exeLeaf /s /L$muiLcid /v`"/qn ADDLOCAL=$MuiLanguage REBOOT=ReallySuppress /l*v $muiLog`""
            Write-Host "Provar Group2a .exe via cmd: $g2aCmd"
            $p = Start-Process -FilePath 'cmd.exe' `
                -ArgumentList @('/d', '/c', $g2aCmd) `
                -WorkingDirectory $exeDir -Wait -PassThru -NoNewWindow
            $muiCode = if ($p) { $p.ExitCode } else { $null }
            Write-Host "Group2a .exe exit=$muiCode"
        }
    }

    if ($null -eq $muiCode -or ($muiCode -ne 0 -and $muiCode -ne 3010)) {
        throw @"
Notes MUI ($MuiLanguage) misslyckades (exit $muiCode).

Distribuera uppackat Group2a och testa i elevated CMD:

  cd /d $(Join-Path $MediaRoot $MuiGroup2aDir)
  setup.exe /s /L$muiLcid /v"/qn ADDLOCAL=$MuiLanguage REBOOT=ReallySuppress /l*v $muiLog"

Logg: $muiLog
"@
    }
    if ($muiCode -eq 3010) {
        Write-Warning 'Notes MUI rapporterade omstart (3010).'
    }
} else {
    Write-Host 'Hoppar over language pack (svenskt kit default - anvand -NotesEdition English -InstallLanguagePack)'
}

# 7) Genvagar: Notes Minder, NSD Support, skrivbord HCL Notes (exe lamnas kvar)
if (-not $SkipShortcutCleanup) {
    Remove-NotesUnwantedShortcuts
}
else {
    Write-Host 'Hoppar over genvagsrensning (-SkipShortcutCleanup).'
}

# 8) Valfri compact - opt-in (-RunCompact), ofta forst efter anvandarsetup
if ($RunCompact) {
    Write-Step 'Forsoker kora ncompact utifran notes.ini [-RunCompact]'
    $ini = Get-NotesIniPath
    if (-not $ini) {
        Write-Warning 'Hittade ingen notes.ini an - hoppar over compact.'
    }
    else {
        Write-Host "notes.ini = $ini"
        $dataDir = Get-IniValue -Path $ini -Section 'Notes' -Key 'Directory'
        $progDir = Get-IniValue -Path $ini -Section 'Notes' -Key 'NotesProgram'

        if (-not $dataDir -or -not $progDir) {
            Write-Warning 'Directory eller NotesProgram saknas i notes.ini - hoppar over compact.'
        }
        else {
            $ncompact = Join-Path $progDir 'ncompact.exe'
            if (-not (Test-Path -LiteralPath $ncompact)) {
                Write-Warning "Hittar inte $ncompact"
            }
            else {
                Push-Location $dataDir
                try {
                    Invoke-External -FilePath $ncompact -ArgumentList @(
                        '-C', '-ods', '-*', '-Client', '-UpdateIndexes'
                    ) -DisplayName 'ncompact'
                }
                finally {
                    Pop-Location
                }
            }
        }
    }
}
else {
    Write-Host 'Hoppar over ncompact (anvand -RunCompact vid behov).'
}

Write-Step 'Klar'
try { Stop-Transcript | Out-Null } catch {}
if (Get-Variable -Name scriptLog -ErrorAction SilentlyContinue) {
    Write-InstallLogNote -Path $scriptLog -Message '=== install_notes.ps1 klar ==='
    Write-Host "Loggar:"
    Write-Host "  $scriptLog"
    Write-Host "  $(Join-Path $scriptLogDir 'install_notes_transcript.log')"
    Write-Host "  $msiLog"
    Write-Host "  $(Join-Path $scriptLogDir 'HCL_Notes_1451_FP1.log')"
}
else {
    Write-Host "Loggar: $logDir"
}
if ($useMst) {
    Write-Host 'MST anvand: kontrollera ALLUSERS=1 / SETMULTIUSER=1 i transformen.'
}
else {
    Write-Host 'Ingen MST: ALLUSERS=1 SETMULTIUSER=1 sattes via kommandorad; notes.ini patchades i PS.'
}
Write-Host 'ConfigFile bor peka pa los SetupNotes.txt:'
Write-Host "  $setupDst"
