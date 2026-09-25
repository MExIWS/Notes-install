# Intune Win32 detection (64-bit).
# Detected = exit 0 AND text on STDOUT.
# Not detected = exit 0 and no STDOUT, or non-zero exit.
$ErrorActionPreference = 'SilentlyContinue'

$exe = Join-Path ${env:ProgramFiles} 'HCL\Notes\notes.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    exit 1
}

$fileVer = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
$verText = $fileVer.ProductVersion
if ([string]::IsNullOrWhiteSpace($verText)) {
    $verText = $fileVer.FileVersion
}

$regVer = $null
foreach ($rp in @(
        'HKLM:\SOFTWARE\HCL\Notes\Installer',
        'HKLM:\SOFTWARE\Lotus\Notes\Installer'
    )) {
    if (Test-Path -LiteralPath $rp) {
        $regVer = [string](Get-ItemProperty -LiteralPath $rp).Version
        if ($regVer) { break }
    }
}

$combined = "$verText $regVer"
if ($combined -notmatch '14\.5') {
    exit 1
}

Write-Output "HCL Notes 14.5 detected file=$verText registry=$regVer"
exit 0
