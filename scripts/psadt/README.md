# PSADT v4.1-skal kring HCL Notes 14.5.1

Minimalt **PSAppDeployToolkit 4.1**-skal. All Notes-logik ligger kvar i `SupportFiles\scripts\install_notes.ps1`.

PSADT sköter bara:

- välkomst / stäng Notes / **defer 3 gånger** (inloggad användare)
- tyst läge när ingen är inloggad (`-DeployMode Auto` / `Silent`)
- samma `Invoke-AppDeployToolkit.exe` mot PDQ, Intune och LAN

Det här är **inte** ett komplett PSADT-paket i git. Modulen och `Invoke-AppDeployToolkit.exe` kommer från officiell mall (4.1.8 vid skrivande).

Fortsätt testa **nuvarande** tvåstegs-PDQ (`robocopy` + `install_notes.ps1`) tills det är grönt. PSADT är nästa lager.

## 1) Skapa mallen (en gång)

På en admin-PC med PowerShell 5.1:

```powershell
Install-Module PSAppDeployToolkit -Scope CurrentUser -Force
Import-Module PSAppDeployToolkit
New-ADTTemplate -Destination 'C:\Temp' -Name 'HCL-Notes-1451-PSADT'
```

Eller zip: [PSAppDeployToolkit releases](https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases) → **PSAppDeployToolkit_Template_v4.zip** (packa upp till `C:\Temp\HCL-Notes-1451-PSADT`).

Hjälpskript från den här repon (skapar mallen om den saknas, skriver sedan overlay):

```powershell
cd <denna-repo>
.\psadt\New-NotesPsadtFolder.ps1 -Destination 'C:\Temp\HCL-Notes-1451-PSADT'
```

Det skriver över `Invoke-AppDeployToolkit.ps1`, lägger `Files\install.parameters.json` och kopierar `install_notes.ps1` till `Files\` som fallback.

Krav efteråt: mappen ska innehålla `PSAppDeployToolkit\` och `Invoke-AppDeployToolkit.exe` från mallen.

`New-ADTTemplate -Destination X` **utan** `-Name` skapar `X\PSAppDeployToolkit_4.x\`. Använd `-Name` (som hjälpskriptet gör).

## 2) Parametrar

Kopiera och redigera:

```text
Files\install.parameters.json.example  →  Files\install.parameters.json
```

Ett steg (PSADT kör hela kedjan, `install_notes.ps1` speglar UNC → lokal disk):

```json
{
  "MediaRoot": "\\\\dc02\\Install\\Notes-1451",
  "LocalMediaRoot": "C:\\install\\Notes-1451",
  "DominoName": "Zeus/TUVAN",
  "DominoAddress": "zeus.tuvan.local",
  "SkipLocalMirror": false
}
```

Efter samma robocopy som i tvåstegs-Deploy (`C:\install\Notes-1451` finns redan):

```json
{
  "MediaRoot": "C:\\install\\Notes-1451",
  "LocalMediaRoot": "C:\\install\\Notes-1451",
  "DominoName": "Zeus/TUVAN",
  "DominoAddress": "zeus.tuvan.local",
  "SkipLocalMirror": true
}
```

Kitet ligger kvar på UNC / `C:\install`. Baka **inte** in hela Notes-media i `Files\` (för stort).

## 3) Kör

Elevated, från mall-roten:

```powershell
.\Invoke-AppDeployToolkit.exe -DeploymentType Install
.\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent
.\Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent
```

Install anropar `install_notes.ps1` med `-ForceCloseNotes` **efter** att PSADT redan stängt/deferat Notes.

Uninstall anropar samma script med `-Uninstall -ForceCloseNotes` (NICE, msiexec-fallback, residualer — inte bara `NICE -rp`).

## 4) PDQ Deploy

Ett steg, **Run as System**, timeout **120 min**.

| Exit | Betydelse | PDQ |
|------|-----------|-----|
| 0 | OK | success |
| 3010 | OK, omstart behövs | success |
| 1602 | defer (användaren sa inte nu) | **retry**, inte success |
| 10 | ska inte komma (PSADT stänger Notes först) | error |

```text
C:\PDQRepository\HCL-Notes-1451-PSADT\Invoke-AppDeployToolkit.exe -DeploymentType Install
```

PSADT 4.1 visar välkomst mot inloggad session från SYSTEM (ServiceUI behövs normalt inte). Natt / ingen inloggad: Auto blir tyst. Dagtid med Notes öppet: dialog (stäng / skjuta upp 3 gånger).

## 5) Intune (senare)

Win32: `-c` = mall-roten, `-s` = `Invoke-AppDeployToolkit.exe`.

```text
Invoke-AppDeployToolkit.exe -DeploymentType Install
Invoke-AppDeployToolkit.exe -DeploymentType Uninstall
```

Se [Deploy with Intune](https://psappdeploytoolkit.com/docs/how-to/deploy-with-intune).

## Mapp efter generate + overlay

```text
HCL-Notes-1451-PSADT\
  Invoke-AppDeployToolkit.exe      ← från officiell mall
  Invoke-AppDeployToolkit.ps1      ← vår overlay
  PSAppDeployToolkit\              ← från officiell mall
  Files\
    install.parameters.json
    install.parameters.json.example
    install_notes.ps1              ← fallback; kitets kopia används först
  Config\  Assets\  Strings\       ← från mall, orörda
```
