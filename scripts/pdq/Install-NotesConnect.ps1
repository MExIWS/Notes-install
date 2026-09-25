# PDQ Connect — litet script-steg (Importera den har filen, inte hela install_notes.ps1).
# Paketegenskaper: Timeout 120 minuter. Success codes: 0,3010. Run as: Local system.
$ErrorActionPreference = 'Stop'
$kit = '\\dc02\Install\Notes-1451'
& (Join-Path $kit 'SupportFiles\scripts\install_notes.ps1') `
    -MediaRoot $kit `
    -LocalMediaRoot 'C:\install\Notes-1451' `
    -DominoName 'Zeus/TUVAN' `
    -DominoAddress 'zeus.tuvan.local'
if ($null -eq $LASTEXITCODE) { exit 0 }
exit $LASTEXITCODE
