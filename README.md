# HCL Notes 14.5.1 klientpaketering

**Kort vad paketet gör:** [OVERSIKT.md](OVERSIKT.md)

Hjälpskript och anteckningar för att paketera och installera **HCL Notes 14.5.1 FP1** (multi-user / per-machine) med Master Packager-MST, NICE, lös `SetupNotes.txt` och svenskt language pack.

Samma `install_notes.ps1` används i **PDQ Deploy** och **Microsoft Intune** (Win32). PDQ är enklast on-prem. Intune: se [Distribuera med Intune](#distribuera-med-intune-win32). PSADT 4.1 (välkomst/defer) är ett tunt skal runt samma script: [PSADT 4.1 (skiss)](#psadt-41-skiss).

## CMD eller PowerShell?

**Använd PowerShell** för det här flödet.

| | CMD (batch) | PowerShell |
|---|---|---|
| Enkel `msiexec`-rad | Bra | Bra |
| Felhantering / exit codes | Svagt | Bra (`$LASTEXITCODE`, `throw`) |
| Registry + INI-parsning | Tungt / felbenäget | Enkelt |
| Sökvägar med mellanslag | Citatfällor | Mindre risk |
| Loggning och steg | Echo-spagetti | Funktioner, `Write-Host`, transcript |
| SCCM / Intune / GPO | Fungerar | Fungerar (kör med `-ExecutionPolicy Bypass`) |
| Teamunderhåll | Svårare över tid | Lättare att läsa och ändra |

CMD duger om hela jobbet är tre rader `msiexec`. Så fort ni kedjar **NICE → hosts → MSI/MST → FP1 → MUI → SetupNotes → registry/INI**, vinner PowerShell.

## Förutsättningar

1. Kör alltid **som Administrator** (Master Packager, MSI per-machine, NICE, hosts).
2. Använd **Notes client only**-kit för multi-user (inte Allclient).
3. **Visual C++ 2015–2022 Redistributable (x64 + x86)** – Notes `nlnotes.exe` behöver `VCRUNTIME140_1.dll`. En naken Windows 10 har den inte. Lägg `vc_redist.x64.exe` och `vc_redist.x86.exe` i `SupportFiles\vcredist\` (scriptet installerar tyst; saknas filerna försöker det ladda ner från Microsoft).
4. MST ska innehålla minst:
   - `ALLUSERS=1`
   - `SETMULTIUSER=1` (om multi-user)
   - `ConfigFile=` som pekar på den **lösa** `SetupNotes.txt`
5. `SetupNotes.txt` ska **inte** bakas in i MST – den kopieras löst till filsystemet så ni kan ändra Domino-server m.m. utan ny transform.

## SetupNotes.txt – lös fil + `%UserName%`

### Varför lös fil

| I MST | Löst i filsystemet |
|---|---|
| `ConfigFile=C:\Program Files\HCL\Notes\license\SetupNotes.txt` | Själva `SetupNotes.txt` |
| Ports, Disabled_Ports, ViewsCheckMarkSel, … | Domino.Name, Domino.Address, Username, … |

Ändrar ni Domino-adress eller setup-parametrar räcker det att byta textfilen i media/på disk – **ingen ny MST**.

Målplats (samma som i er Master Packager-preview):

```text
C:\Program Files\HCL\Notes\license\SetupNotes.txt
```

### Username=%UserName%

Behåll Windows-inloggningen för oövervakad setup när Notes-/Domino-användarnamnet matchar Windows-kontot:

```text
Username=%UserName%
Domino.Name=<Change to Your Server(ex. Domino/Organisation)>
Domino.Address=<Change to Your Server(ex. Domino.domain.se)>
Domino.Port=TCPIP
Domino.Server=1
AdditionalServices=-1
AdditionalServices.NetworkDial=0
```

**`AdditionalServices=-1`** (inte `0`) hoppar över dialogen *Additional Services* (POP/IMAP, NNTP, LDAP, proxy, replication). `0` lämnar panelen kvar.

Det kräver att Domino-användarens short name / vanliga namn överensstämmer med `%UserName%` (Windows). Annars stannar setup och frågar.

Se även `scripts/SetupNotes.txt.example`.

## Undertryck dialoger vid första start

Efter att klienten kopplat till Domino (`Connected to server …`) kan två dialoger dyka upp. Så här slipper ni dem:

| Dialog | Åtgärd |
|---|---|
| **Additional Services** (POP/IMAP, NNTP, LDAP, …) | `AdditionalServices=-1` i lös `SetupNotes.txt` (ConfigFile). Måste finnas **innan** användarens setup körs. |
| **Default email program** (“Would you like to set it now?”) | `DontCheckDefaultMail=1` i shared `notes.ini` under ProgramData (**via MST**). Alternativt Domino desktop policy som stänger av “check default mail on startup”. |

### MST / MSI-egenskaper (rekommenderat)

I Master Packager, sätt även (så Notes inte registreras som default mail vid install):

| Property | Värde |
|---|---|
| `USENOTESFOREMAIL` | `0` |
| `USENOTESFORCALENDAR` | `0` (valfritt) |
| `USENOTESFORCONTACTS` | `0` (valfritt) |

### Manuell patch på redan installerad klient

```powershell
$ini = 'C:\ProgramData\HCL\Notes\Data\notes.ini'
# Lägg till under [Notes] om det saknas:
# DontCheckDefaultMail=1

# Additional Services: uppdatera lös SetupNotes.txt
notepad 'C:\Program Files\HCL\Notes\license\SetupNotes.txt'
# AdditionalServices=-1
```

Om användaren redan gått igenom setup hjälper **inte** `AdditionalServices=-1` i efterhand för den användaren (panelen har redan visats). Då gäller ny profil / omsetup, eller acceptera att befintliga klienter redan klickat Finish.

## Master Packager – notes.ini och `VDIR_INI`

### Varför era IniFile-rader inte syns i ProgramData

I Notes 12-MST:en pekade IniFile-raderna på:

| Kolumn | Värde |
|---|---|
| `FILENAME` | `Notes.ini` |
| `DIRPROPERTY` | **`VDIR_INI`** |
| `KEY` / `VALUE` | t.ex. `ConfigFile=C:\Program Files (x86)\HCL\Notes\license\SetupNotes.txt` |

`DIRPROPERTY` styr **vilken katalog** Windows Installer skriver `notes.ini` till.  
`VDIR_INI` är bara ett MSI Directory-id – det är **inte** samma sak som `C:\ProgramData\HCL\Notes\Data`.

I **multi-user 14.5.1 x64** är runtime-/shared-`notes.ini` typiskt:

```text
C:\ProgramData\HCL\Notes\Data\notes.ini
```

Om `VDIR_INI` i Directory-tabellen fortfarande pekar mot t.ex. programkatalog, License eller en gammal single-user data-väg, skrivs era nycklar till **en annan fil** (eller en fil Notes knappt använder). Då ser ni ingen förändring under ProgramData.

Det förklarar också er tidigare INI FILES-UI med Path = `[ProgramFiles64Folder]HCL\Notes\license`: den skapar/uppdaterar `Notes.ini` **under License**, inte under ProgramData.

### `VDIR_INI` finns inte i Directory – vad betyder det?

I 14.5.1-kitet är `VDIR_INI` ofta **inte** en statisk rad i Directory-tabellen. Den kan sättas dynamiskt av InstallShield/custom action under körning – eller saknas helt när *er* IniFile-rad körs.

Om `DIRPROPERTY=VDIR_INI` men egenskapen inte resolvar till ProgramData:

- IniFile kan skriva till **programkatalogen** `C:\Program Files\HCL\Notes\notes.ini`, eller
- inte träffa den `notes.ini` multi-user faktiskt använder.

Att flytta tillbaka från `...\license` till `HCL\Notes` (programkatalog) var rätt steg bort från misstaget — men för **multi-user** är programkatalogen fortfarande **fel mål**. Rätt fil är:

```text
C:\ProgramData\HCL\Notes\Data\notes.ini
```

`ConfigFile=`-värdet i skärmdumpen är däremot bra (x64):

```text
C:\Program Files\HCL\Notes\license\SetupNotes.txt
```

Det är **sökvägen till SetupNotes.txt**, inte platsen där `notes.ini` ska ligga.

### Hitta / skapa rätt mål i Master Packager

1. Öppna MSI + MST. Sök i **Directory** *och* **Property** efter `VDIR_INI`, `VDIR_DATA`, `VDIR_SHARED`, `VDIR_COMMON`.
2. Om `VDIR_INI` saknas i Directory: antingen  
   - peka IniFile `DIRPROPERTY` på en **befintlig** Directory som blir ProgramData-data (t.ex. kedja under `CommonAppDataFolder`), eller  
   - låt bli IniFile för dessa nycklar och använd `-PatchNotesIni` i install-scriptet (valfritt fallback).
3. Verifiera efter install:

```powershell
# Rätt fil (multi-user shared)
Select-String -Path 'C:\ProgramData\HCL\Notes\Data\notes.ini' -Pattern 'ConfigFile|Ports|Disabled_Ports'

# Fel/sidofil om den skapats
Test-Path 'C:\Program Files\HCL\Notes\notes.ini'
Select-String -Path 'C:\Program Files\HCL\Notes\notes.ini' -Pattern 'ConfigFile|Ports' -ErrorAction SilentlyContinue

Get-ItemProperty 'HKCU:\Software\HCL\Notes','HKCU:\Software\Lotus\Notes' -Name NotesIniPath -ErrorAction SilentlyContinue
```

### Dialog innan användaren är inne i klienten

Två vanliga orsaker:

| Dialog | Orsak | Åtgärd |
|---|---|---|
| MSI “Installation completed” / Setup avslutad | Ni kör `/qb+` — **`+` visar slutdialog** | Byt till `/qb` eller `/qn` |
| Notes Setup-guide (användare/server) | `ConfigFile=` finns inte i den `notes.ini` klienten läser | Se till att nyckeln finns i ProgramData-`notes.ini` (och att `SetupNotes.txt` ligger på ConfigFile-sökvägen) |

Silent utan slutdialog:

```bat
setup.exe /s /v"TRANSFORMS=HCL_Notes_1451_x64_sv.mst /l*v setup.log /qn"
```

eller med progress men **utan** completion-ruta: `/qb` (inte `/qb+`).

### Rekommenderad uppdelning

| Vad | Var | Via |
|---|---|---|
| `SetupNotes.txt` (lös) | `C:\Program Files\HCL\Notes\license\` | Installationsscript / kopia |
| `ConfigFile=` + Ports m.m. | Shared `notes.ini` under ProgramData | IniFile med rätt `DIRPROPERTY` i MST (default). Scriptet patchar **inte** notes.ini längre om du inte anger `-PatchNotesIni`. |
| License\`Notes.ini` | Undvik som enda mål | Lätt att tro att det är “riktiga” notes.ini |

### Bekräftat fungerande (14.5.1 multi-user)

I praktiken: lägg IniFile-raderna så `notes.ini` landar under **ProgramData** (varken `ProgramData` eller `VDIR_INI` syns i Directory förrän ni kopplar dem via IniFile). `ConfigFile=` pekar på lös `SetupNotes.txt` under `...\Notes\license\` — då blir server-setup oövervakad.

Låt MST sköta multi-user/`ALLUSERS` + dessa IniFile-rader. Scriptet kan fortfarande kopiera den lösa `SetupNotes.txt` och fungera som backup-patch om något saknas.

### Error 2254 Shortcut (igen) – lokalt kit

När media körs från `C:\install\Notes1451` försvinner Access denied / 1723. Om loggen ändå slutar med:

```text
Transforming table Shortcut.
Note: 1: 2254 2:  3: Shortcut
Error 2254. ... Cannot update row that does not exist. Table: Shortcut.
```

är det **MST:ens Shortcut-ändringar**, inte nätverket.

Viktigt från er logg:

| Observation | Betydelse |
|---|---|
| MSI = `HCL Notes 14.5.1 x64.msi` | Engelskt basfilnamn |
| TRANSFORMS = `HCL_Notes_1451_x64_sv.mst;1033.MST` | Er MST **plus** språktransform 1033 |
| `ProductLanguage = 1033` | Engelska efter transforms |
| `INSTALLCONFIGURATION = multiuser` | Multi-user i er MST OK |
| `CleanupDynamicFeatures` return 1 | Lokalt kit OK |

**Åtgärd:** bygg om MST mot **exakt samma MSI** som ni installerar (`HCL Notes 14.5.1 x64.msi`). Ta **inte** bort/ändra något i tabellen **Shortcut** tills bas+IniFile+multi-user är grönt. Testa:

```bat
cd /d C:\install\Notes1451
setup.exe /s /v"TRANSFORMS=HCL_Notes_1451_x64_sv.mst /l*v %TEMP%\notes-mst.log /qn"
```

Om det failar: skapa en minimal MST utan Shortcut-rader. Genvägar kan tas bort efteråt med script.

## Kör installationen

Lägg mediafilerna i samma mapp som scriptet (eller ange `-MediaRoot`), och justera filnamnen i `scripts/Install-HclNotes.ps1` vid behov:

### MediaRoot – var ligger MSI-filerna?

`MediaRoot` är katalogen med **installationsmedia** (MSI, MST, setup.exe, NICE, SetupNotes.txt) — inte nödvändigtvis samma mapp som scriptet.

Er layout (kit-rot `Notes-1451`):

```text
Z:\HCL\Paketering\Notes-1451\
  Notes_1451_Win64_Swedish\
    HCL Notes 14.5.1 x64.msi
    setup.exe
    ...
  Notes_1451_Win64_English\
    HCL Notes 14.5.1 x64.msi
    setup.exe
    ...
  SupportFiles\
    SetupNotes.txt
    Notes_1451FP1_x64\setup.exe
    Notes_1451_x64_MUI\
    vcredist\
      vc_redist.x64.exe            ← Microsoft VC++ 2015–2022 (lägg dit manuellt)
      vc_redist.x86.exe
    scripts\install_notes.ps1
    x64\NICE_x64.exe
    x64\Notes.ini
    x86\NICE_x86.exe
```

När scriptet ligger i `SupportFiles\scripts\` blir **default MediaRoot = kit-roten** (`Notes-1451\`).

```powershell
# Elevated PowerShell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Set-Location 'Z:\HCL\Paketering\Notes-1451\SupportFiles\scripts'
.\install_notes.ps1
# => MediaRoot = Z:\HCL\Paketering\Notes-1451
# => speglar till C:\install\Notes-1451, installerar svenskt kit + FP1 (ingen custom MST)
```

Eller explicit:

```powershell
.\install_notes.ps1 -MediaRoot 'Z:\HCL\Paketering\Notes-1451'
.\install_notes.ps1 -MediaRoot '\\10.0.1.100\mjukvara\HCL\Paketering\Notes-1451'
```

**Access denied från Z:\\ / UNC** är vanligt. Scriptet speglar därför hela kit-roten till `C:\install\Notes-1451` (robocopy) innan installationen körs.

```powershell
# Redan lokalt speglat:
.\install_notes.ps1 -MediaRoot 'C:\install\Notes-1451' -SkipLocalMirror
```

### Kopiera till `%TEMP%` (inte `C:\Windows\%TEMP%`)

`%TEMP%` är redan en **hel sökväg**. Den är inte mappnamnet `Temp` under `C:\Windows`.

| Konto som kör | `%TEMP%` blir typiskt |
|---|---|
| Inloggad användare / “Kör som administratör” | `C:\Users\<användare>\AppData\Local\Temp` |
| PDQ / uppgift som **SYSTEM** | `C:\Windows\Temp` |

Fel (hopklistrat, fungerar inte):

```text
C:\Windows\%TEMP%\Notes1451
```

I CMD blir det t.ex. `C:\Windows\C:\Users\...\Temp\Notes1451`. I PowerShell expanderas `%TEMP%` **inte alls** — använd `$env:TEMP`.

**CMD** (samma session för copy + install):

```bat
robocopy \\10.0.1.100\mjukvara\HCL\Paketering\Notes-1451 "%TEMP%\Notes1451" /E /R:2 /W:2
if %ERRORLEVEL% GEQ 8 exit /b %ERRORLEVEL%

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\Notes1451\SupportFiles\scripts\install_notes.ps1" -MediaRoot "%TEMP%\Notes1451" -SkipLocalMirror -DominoName "Zeus/Tuvan" -DominoAddress "zeus.tuvan.local" -AddToHostsAsSetupServer -HostsIp 10.0.7.95 -HostsName zeus.tuvan.local
```

**PowerShell** (elevated, samma konto som robocopy):

```powershell
$kit = Join-Path $env:TEMP 'Notes1451'
robocopy '\\10.0.1.100\mjukvara\HCL\Paketering\Notes-1451' $kit /E /R:2 /W:2
if ($LASTEXITCODE -ge 8) { throw "robocopy exit $LASTEXITCODE" }

Set-Location (Join-Path $kit 'SupportFiles\scripts')
.\install_notes.ps1 -MediaRoot $kit -SkipLocalMirror `
  -DominoName 'Zeus/Tuvan' `
  -DominoAddress 'zeus.tuvan.local' `
  -AddToHostsAsSetupServer -HostsIp 10.0.7.95 -HostsName zeus.tuvan.local
```

Kontrollera att kitet faktiskt landade där scriptet letar:

```powershell
Test-Path (Join-Path $env:TEMP 'Notes1451\SupportFiles\scripts\install_notes.ps1')
Write-Host $env:TEMP
```

Låt scriptet robocopy åt er (ingen separat copy, ingen `-SkipLocalMirror`):

```powershell
.\install_notes.ps1 `
  -MediaRoot '\\10.0.1.100\mjukvara\HCL\Paketering\Notes-1451' `
  -LocalMediaRoot (Join-Path $env:TEMP 'Notes1451') `
  -DominoName 'Zeus/Tuvan' -DominoAddress 'zeus.tuvan.local'
```

**PDQ:** föredra `C:\install\Notes-1451` framför `%TEMP%`. Notes `setup.exe` använder TEMP tungt; ett helt kit i samma katalog kan fylla disken. TEMP rensas också av Windows. `-RunCompact` hoppa över vid första install (ingen användardata än).

Scriptet skriver ut `MediaRoot = ...` och `Administrator = True/False` i början.

Scriptet är sparat som **UTF-8 med BOM**. Windows PowerShell 5.1 utan BOM kan misstolka svenska tecken och typografiska tankstreck (`–`) i strängar och ge vilseledande `Missing closing '}'` trots att klamrarna ser rätt ut.

Nyttiga switchar:

```powershell
.\install_notes.ps1
.\install_notes.ps1 -NotesEdition Swedish          # default
.\install_notes.ps1 -NotesEdition English -InstallLanguagePack
.\install_notes.ps1 -SkipNice
.\install_notes.ps1 -SkipFixPack
.\install_notes.ps1 -NotesMst 'SupportFiles\min_custom.mst'   # om ni behaller custom MST
.\install_notes.ps1 -PatchNotesIni                 # tvinga ini-patch aven med MST
.\install_notes.ps1 -RunCompact
# Behall Notes Minder / NSD / skrivbordsikon:
.\install_notes.ps1 -SkipShortcutCleanup
.\install_notes.ps1 -SkipSametime                 # REMOVEFEATURES=SametimeUI (integrerad Sametime)
.\install_notes.ps1 -SkipVcRedist                 # hoppa over VC++ (om GPO redan installerat den)
# SetupNotes Domino-server (oberoende av hosts):
.\install_notes.ps1 -MediaRoot C:\install -SkipLocalMirror `
  -DominoName 'Zeus/TUVAN' -DominoAddress zeus
# Eller: -HostsName zeus satter Domino.Address=zeus ( Domino.Name kraver -DominoName )
.\install_notes.ps1 -MediaRoot C:\install -SkipLocalMirror -HostsName zeus -DominoName 'Zeus/TUVAN'
# Opt-in hosts-fil:
.\install_notes.ps1 -AddToHostsAsSetupServer -HostsIp 10.0.7.95 -HostsName zeus
```

Loggar skrivs till `%TEMP%\HCL_Notes_Install\`.

## Utan custom MST (default)

HCL:s `1053.mst` m.fl. i kitmappen är **språktransformar**, inte er paketerings-MST. Scriptet använder som default **ingen** custom MST (`-NotesMst` tom). Multi-user och `notes.ini` sköts i PowerShell.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Set-Location 'Z:\HCL\Paketering\Notes-1451\SupportFiles\scripts'
.\install_notes.ps1 -MediaRoot 'Z:\HCL\Paketering\Notes-1451'
```

Flöde:

1. **Robosync** kit-rot → `C:\install\Notes-1451`  
2. NICE (`SupportFiles\x64\NICE_x64.exe`) + residual cleanup  
3. Ta bort `rcpInstallerTemp.properties` i TEMP (Notes 14.5.1 / KB0132505)  
4. `Notes_1451_Win64_Swedish\setup.exe` med `ALLUSERS=1 SETMULTIUSER=1 … /qn`  
5. Kopiera `SupportFiles\SetupNotes.txt`  
6. Patcha ProgramData-`notes.ini` (ev. seed från `SupportFiles\x64\Notes.ini`)  
7. FP1 från `SupportFiles\Notes_1451FP1_x64\setup.exe`  

Custom MST bara om ni anger t.ex. `-NotesMst 'SupportFiles\min.mst'`.

## Distribuera med PDQ Deploy (enklast / best practice)

**Gör inte** MST, hosts-hack eller många PDQ-steg. Låt `install_notes.ps1` sköta kedjan.

### Princip

1. En komplett kit-rot i PDQ Repository  
2. PDQ kopierar den **lokalt** till målmaskinen  
3. Ett PowerShell-steg kör scriptet med Domino-parametrar  
4. Klart  

Undvik att köra `setup.exe` direkt från UNC (Access denied). Undvik custom MST om ni inte måste.

### 1) Repository-layout

Spegla er paketeringsrot (samma som `Z:\HCL\Paketering\Notes-1451`):

```text
\\PDQ\Repository\Notes-1451\
  Notes_1451_Win64_Swedish\
    HCL Notes 14.5.1 x64.msi
    setup.exe
    ...
  SupportFiles\
    SetupNotes.txt                 ← mall; Domino fylls i via script-parametrar
    Notes_1451FP1_x64\setup.exe
    vcredist\vc_redist.x64.exe     ← VC++ 2015–2022 (x64 + x86)
    vcredist\vc_redist.x86.exe
    scripts\install_notes.ps1
    x64\NICE_x64.exe
    x64\Notes.ini
```

Valfritt i repository: `Notes_1451_Win64_English\` (behövs inte för svensk default).

### 2) PDQ-paket: två steg

#### Steg 1 – File Copy / Command (robocopy)

Kopiera hela `Notes-1451\` → `C:\install\Notes-1451`.

```bat
robocopy "%RepositoryPath%\Notes-1451" "C:\install\Notes-1451" /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
if %ERRORLEVEL% GEQ 8 exit /b %ERRORLEVEL%
exit /b 0
```

Success codes: `0–7` (eller wrap som ovan).

#### Steg 2 – PowerShell (install)

- **Run As:** Local System eller Deploy User (admin)  
- **Timeout:** 90–120 min  
- **Success codes:** `0`, `3010` (inte `10`)  
- **Error mode:** Stop  
- **Conditions (valfritt extra skydd):** Process `notes.exe` is **not** running  

Om Notes är öppet avbryter `install_notes.ps1` med **exit 10** innan NICE/setup. Sätt retry i schemat, eller `-ForceCloseNotes` bara när ni medvetet vill döda klienten.

```powershell
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
& 'C:\install\Notes-1451\SupportFiles\scripts\install_notes.ps1' `
  -MediaRoot 'C:\install\Notes-1451' `
  -SkipLocalMirror `
  -SkipSametime `
  -DominoName 'Zeus/TUVAN' `
  -DominoAddress 'zeus'
```

Det är **hela** best practice-kommandot. Scriptet gör NICE, residual cleanup, `rcpInstallerTemp.properties`, setup.exe (multi-user), SetupNotes, notes.ini, FP1 och tar bort Notes Minder / NSD-genvägar samt skrivbordsikonen HCL Notes.

`-SkipSametime` skickar `REMOVEFEATURES=SametimeUI` till tyst `setup.exe` så **Sametime (integrerad)** inte installeras (och tas bort vid uppgradering om den redan fanns). Utan switchen följer Sametime kitet (förvalt i GUI). Använd inte MSI-`ADDLOCAL`/`REMOVE` för den funktionen.

#### Avinstallera (samma script)

Samma paket, annat kommando. **Run As:** SYSTEM. Timeout 30–60 min räcker oftast. Success: `0`, `3010`. Inte `10`. Inte `1605`.

```powershell
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
& 'C:\install\Notes-1451\SupportFiles\scripts\install_notes.ps1' `
  -Uninstall `
  -MediaRoot 'C:\install\Notes-1451' `
  -SkipLocalMirror
```

Kedja: stäng-koll (exit 10 om Notes kör) → NICE `-rp /qn` → `msiexec /x` på kvarvarande HCL Notes → rensa ProgramData/Program Files → Start-meny och skrivbord. **Inte** per-användardata (ID/NSF) om du inte lägger till `-RemoveUserData`.

Om kitet redan är borta från `C:\install` men NICE ligger kvar på sharen: `-MediaRoot '\\dc02\Install\Notes-1451'` (scriptet kopierar bara NICE lokalt, inte hela kitet).

### PDQ Connect (`app.pdq.com`)

Connect är **inte** Deploy. Agenten kör ett PowerShell-steg. Notes + robocopy + FP1 tar ofta **längre än Connects default-timeout**, så paketet visar Error även när MSI redan skrivit `Installation success … status: 0`.

**Gör så här i Connect-paketet**

| Fält | Värde |
|---|---|
| Timeout (paketegenskaper) | **120** minuter |
| Success codes | `0,3010` (inte bara `0`) |
| Run as | Local system |
| Script | Importera **`scripts/pdq/Install-NotesConnect.ps1`** — inte hela `install_notes.ps1` |

Importerar ni hela `install_notes.ps1` och sätter Parameters `-MediaRoot '\\dc02\...'` fungerar det också, men Connect kopierar scriptet till `%ProgramData%\PDQ\PDQConnectAgent\Downloads\...` och räknar timeout på **hela** kedjan (spegling + MSI + FP1).

SYSTEM måste ha läsrätt på `\\dc02\Install`. Timeout-felet betyder “Connect slutade vänta”, inte “MSI failade”. Kolla ändå FP1 och `SetupNotes.txt` på mål-PC:n.

**Lägg inte till** som default:

- `-AddToHostsAsSetupServer` (bara om DNS saknas)  
- `-NotesMst` (ingen custom MST)  
- `-InstallLanguagePack` (svenskt kit)  
- `-RunCompact`  

### 3) PDQ-inställningar

| Inställning | Värde |
|---|---|
| Conditions | Valfritt: `notes.exe` saknas, eller kör alltid för upgrade/reinstall |
| Logged-on user | Behövs inte |
| Notes öppet | Undvik; scriptet dödar processer men utloggning är trevligare |
| Efter 3010 | Separat reboot-steg eller PDQ reboot-policy |
| Städa staging | Valfritt steg 3: `rmdir /s /q C:\install\Notes-1451` — behåll under utrullning för loggar |

### 4) Förbered en gång i media

Innan PDQ:

1. `SupportFiles\SetupNotes.txt` har `Username=%UserName%`, `AdditionalServices=-1`  
2. MSI heter `HCL Notes 14.5.1 x64.msi` (matchar Setup.ini)  
3. FP1 är **uppackat** under `SupportFiles\Notes_1451FP1_x64\`  
4. Domino-värden skickas i PDQ-steget (`-DominoName` / `-DominoAddress`) — behöver inte bakas in i filen  

### 5) Verifiering på en pilot-PC

```powershell
Test-Path 'C:\Program Files\HCL\Notes\notes.exe'
Get-Content 'C:\Program Files\HCL\Notes\license\SetupNotes.txt'
Select-String -Path 'C:\ProgramData\HCL\Notes\Data\notes.ini' -Pattern 'ConfigFile'
Get-Content 'C:\install\Notes-1451\SupportFiles\logs\install_notes_script.log' -Tail 40
```

### 5) Verifiering efter deploy

På målmaskin:

```powershell
# Version / FP1
Get-ItemProperty 'HKLM:\SOFTWARE\HCL\Notes\Installer' -ErrorAction SilentlyContinue |
  Select-Object Version, DominoVersion

Test-Path 'C:\Program Files\HCL\Notes\license\SetupNotes.txt'
Test-Path 'C:\ProgramData\HCL\Notes\Data\notes.ini'
Select-String -Path 'C:\ProgramData\HCL\Notes\Data\notes.ini' -Pattern 'ConfigFile' -ErrorAction SilentlyContinue
```

Loggar: `%TEMP%\HCL_Notes_Install\` och `C:\install\Notes1451\logs\HCL_Notes_1451_FP1.log` (om staging finns kvar).

### 6) Vanliga PDQ-fällor

| Problem | Åtgärd |
|---|---|
| Access denied / setup från UNC | Kör alltid från **lokal** kopia (`C:\install\Notes-1451`), inte direkt från `\\server\share` |
| `Det går inte att hitta filen` / `FileSystem::\\server\...` | PowerShell prefixade UNC. Uppdaterat script strippar det och speglar till `C:\install\Notes-1451`. Kopiera ny `install_notes.ps1` till sharen och kör om **utan** `-SkipLocalMirror`. |
| `C:\Windows\%TEMP%\Notes1451` hittas inte | `%TEMP%` är redan hel sökväg. PowerShell: `-MediaRoot $env:TEMP\Notes1451`. CMD: `-MediaRoot "%TEMP%\Notes1451"` |
| Scriptet säger inte Administrator | Byt **Run As** till SYSTEM eller Deploy User med admin |
| Timeout mid-install | Höj timeout; Notes+FP1 är tungt |
| FP1 visar UI | Kontrollera att repository innehåller **uppackat** `Notes_1451FP1_x64\setup.exe` |
| Användare har Notes öppet | Scriptet stoppar processer före NICE; be ändå användare logga ut Notes före deploy |
| Omstart 3010 | Markera 3010 som success och hantera reboot separat |

### PSADT 4.1 (skiss)

PSADT är **inte** nästa steg förrän tvåstegs-Deploy är grön. När det är dags: **PSADT 4.1** (inte 3.x) som tunt skal runt **samma** `install_notes.ps1`.

| Fil | Roll |
|-----|------|
| [`psadt/README.md`](psadt/README.md) | Hur du skapar mappen med `New-ADTTemplate` |
| `psadt/New-NotesPsadtFolder.ps1` | Genererar `HCL-Notes-1451-PSADT` och lägger in overlay |
| `psadt/overlay/Invoke-AppDeployToolkit.ps1` | Välkomst + defer **3**, stänger Notes, kör `install_notes.ps1 -ForceCloseNotes` |
| `psadt/Files/install.parameters.json.example` | MediaRoot / Domino / valfri `SkipLocalMirror` |

**Kopiera inte** hela Notes-kitet in i `Files\`. Låt `MediaRoot` peka på `C:\install\Notes-1451` (efter samma robocopy-steg) eller UNC.

**PDQ + PSADT:** ett steg `Invoke-AppDeployToolkit.exe -DeploymentType Install` (64-bit, SYSTEM). Success: **0, 3010**. Defer **1602** = retry, inte success. Timeout 120 min. Avinstallera: `-DeploymentType Uninstall` (anropar `install_notes.ps1 -Uninstall`).

## Distribuera med Intune (Win32)

PDQ-spåret är oförändrat. Intune kör **samma** `install_notes.ps1` via en tunn wrapper under `SupportFiles\scripts\intune\`.

Använd **Win32-app** (inte Line-of-business MSI). Notes-kitet är `setup.exe` + cab + FP1, inte en ensam MSI.

### Välj modell

| | **NetworkCopy** (närmast PDQ) | **FullPackage** |
|---|---|---|
| `.intunewin` | Bara `scripts\intune\` (några KB) | Hela kit-roten `Notes-1451\` |
| Media | Samma share som PDQ, t.ex. `\\10.0.1.100\mjukvara\HCL\Paketering\Notes-1451` | Inbakat i paketet |
| Klientbehov | Line-of-sight till share (kontor/VPN) | Fungerar på bärbara utan VPN |
| Nedladdning | Liten från Intune, stor från share | Stor från Intune (Delivery Optimization) |
| Max storlek | Irrelevant | 30 GB per Win32-app |
| När | Hybrid / samma nät som PDQ | Entra-joined laptops, hemmajobb |

**Rekommendation hos er:** börja med **NetworkCopy** — samma kit som PDQ, en källa. FullPackage när ni har klienter som inte når `\\10.0.1.100`.

IMECache raderas när install-kommandot är klart. Wrappern **robocopy:ar alltid** till `C:\install\Notes-1451` först (som PDQ steg 1), sedan:

```text
install_notes.ps1 -MediaRoot C:\install\Notes-1451 -SkipLocalMirror -DominoName ... -DominoAddress ...
```

### 1) Parametrar

```bat
copy SupportFiles\scripts\intune\intune.parameters.json.example SupportFiles\scripts\intune\intune.parameters.json
```

NetworkCopy (samma värden som PDQ):

```json
{
  "InstallMode": "NetworkCopy",
  "DominoName": "Zeus/TUVAN",
  "DominoAddress": "zeus",
  "LocalMediaRoot": "C:\\install\\Notes-1451",
  "NetworkMediaRoot": "\\\\10.0.1.100\\mjukvara\\HCL\\Paketering\\Notes-1451",
  "NotesEdition": "Swedish"
}
```

FullPackage: `"InstallMode": "FullPackage"` — `NetworkMediaRoot` ignoreras. Lägg json-filen **i kitet** innan ni wrappar.

SYSTEM (Intune) når UNC bara om datorn har rätt share-ACL (t.ex. Domain Computers). Testa som SYSTEM: `psexec -s` + `dir \\10.0.1.100\mjukvara\...`.

### 2) Bygg .intunewin

[Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) (`IntuneWinAppUtil.exe`). Wrap **lokalt**, inte från UNC.

```powershell
# NetworkCopy — bara wrappern
cd ...\Notes-1451\SupportFiles\scripts\intune
copy .\intune.parameters.json.example .\intune.parameters.json
# redigera json
.\New-NotesIntuneWin.ps1 -Mode NetworkCopy -OutputDir C:\intune-out

# FullPackage — hela kitet (skippa English + MUI om ni inte behover dem)
.\New-NotesIntuneWin.ps1 -Mode FullPackage -KitRoot 'C:\install\Notes-1451' -OutputDir C:\intune-out
```

Manuellt NetworkCopy:

```bat
IntuneWinAppUtil.exe -c C:\wrap\intune -s C:\wrap\intune\Install-NotesIntune.cmd -o C:\intune-out -q
```

Manuellt FullPackage (`-c` = kit-rot):

```bat
IntuneWinAppUtil.exe -c C:\install\Notes-1451 -s C:\install\Notes-1451\SupportFiles\scripts\intune\Install-NotesIntune.cmd -o C:\intune-out -q
```

### 3) Win32-app i Intune-portalen

**Apps → Windows → Add → Windows app (Win32)**

| Fält | Värde |
|---|---|
| Package file | `Install-NotesIntune.intunewin` |
| Name | HCL Notes 14.5.1 FP1 |
| Install command | `Install-NotesIntune.cmd` |
| Uninstall command | `Uninstall-NotesIntune.cmd` |
| Install behavior | **System** |
| Device restart | Determine behavior based on return codes (0 = success) |
| Return codes | `0` Success, `3010` Soft reboot (valfritt — wrappern avslutar normalt med 0) |
| Max run time | **120** minuter |
| Allow available uninstall | Ja om användare ska kunna ta bort |

**Requirements**

- OS: Windows 10/11 64-bit  
- Disk: minst ~8 GB ledigt (kit + install)

Kör inte 32-bit PowerShell. `Install-NotesIntune.cmd` använder `%SystemRoot%\SysNative\...` just därför. Skriv **inte** `powershell.exe -File ...` i install command — IME startar då 32-bit PS och x64 `setup.exe` failar.

**Detection rule** — *Use a custom detection script*, 64-bit (bocka **inte** “Run script in 32-bit PowerShell”). Klistra in `Detect-Notes1451.ps1`:

- `notes.exe` finns  
- versionssträng innehåller `14.5` (filversion och/eller `HKLM\SOFTWARE\HCL\Notes\Installer`)

Då uppgraderas Notes 12.x, och en lyckad 14.5.1 räknas som installerad.

**Assignments:** Required till en pilot-enhetsgrupp först. En app per dator (device assignment).

### 4) Uninstall

`Uninstall-NotesIntune.cmd` anropar `install_notes.ps1 -Uninstall` om scriptet finns (bredvid, eller `C:\install\Notes-1451\...`). Annars fallback:

1. NICE (`-rp /qn`) i samma mapp som wrappern (`NICE_x64.exe` — lägg dit den i **NetworkCopy**-paketet)  
2. `SupportFiles\x64\` i FullPackage-layout  
3. `C:\install\Notes-1451\SupportFiles\x64\NICE_x64.exe`

Saknas NICE: `msiexec /x {GUID} /qn` för produkter vars namn matchar `HCL Notes`, plus rensning av ProgramData-klienten. Samma kedja som `-Uninstall` i `install_notes.ps1`. Per-användardata raderas inte.

### 5) Verifiering

På klienten:

```powershell
Get-Content 'C:\Program Files\HCL\Notes\license\SetupNotes.txt'
Test-Path 'C:\Program Files\HCL\Notes\notes.exe'
Get-Content "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log" -Tail 80
Get-Content 'C:\install\Notes-1451\SupportFiles\logs\install_notes_script.log' -Tail 40
```

Company Portal / Intune: app status **Installed** när detection-scriptet skriver en rad till STDOUT.

### 6) Intune-fällor

| Problem | Åtgärd |
|---|---|
| `setup.exe` / MSI failar bara via Intune | 32-bit PowerShell. Använd `.cmd`-trampolinen, inte `powershell.exe` i install command |
| NetworkCopy timeout / Access denied | SYSTEM saknar share-rättighet, eller ingen VPN. Testa `Test-Path \\10.0.1.100\mjukvara\...` som SYSTEM |
| Detection fastnar på “installed” för Notes 12 | Scriptet kräver `14.5` i version |
| Detection aldrig grön | Scriptet måste **skriva till STDOUT** vid träff. Kör `Detect-Notes1451.ps1` lokalt som 64-bit |
| Timeout 60 min | Höj till 120. Notes + FP1 är tungt |
| FullPackage jättestort | Ta bort `Notes_1451_Win64_English` och MUI ur kitet ni wrappar |
| IMECache / “filen finns inte” efteråt | Wrappern speglar till `C:\install\Notes-1451` innan install |
| Uninstall gör inget | NetworkCopy: lägg `NICE_x64.exe` bredvid `Uninstall-NotesIntune.cmd` |

Intune **PowerShell-script** (Devices → Scripts) duger inte till det här: kort timeout, ingen kit-leverans. Win32 är rätt app-typ.

## `rcpInstallerTemp.properties` (Notes 14.5.1)

Kvarlämnad fil i TEMP (för kontot som kör installen) kan ge “lyckad” MSI men felaktig klient / saknade RCP-komponenter (HCL KB0132505).

Scriptet söker och tar bort `rcpInstallerTemp.properties` i:

- `%TEMP%` / `%TMP%` / `%LOCALAPPDATA%\Temp` (aktuellt konto)
- `C:\Windows\Temp`
- `C:\Users\*\AppData\Local\Temp` (+ en nivå undermappar)

Hoppa över med `-SkipRcpTempCleanup` om ni måste.

## Windows 7 / x86?

| | Windows 10/11 x64 | Windows 7 x64 | Windows 7/10 x86 |
|---|---|---|---|
| **HCL Notes 14.5.1 Win64-kit** | Ja (stödd plattform) | **Nej** – Notes 14.x stöder inte Windows 7 | **Nej** – x64-MSI/setup |
| **Detta script** | Ja (Windows PowerShell **5.1**) | Osäkert / nej i praktiken | Nej med detta kit |

Detaljer:

- Mediakitten `Notes_1451_Win64_*` och FP1 **x64** kräver **64-bitars Windows**.
- HCL Notes **14.5** listar inte Windows 7 som stödd klient-OS (7 är EOL).
- Scriptet använder konstruktioner för **PowerShell 5.x** (`#Requires -RunAsAdministrator`, m.m.). Win7 har ofta bara PS 2.0/3.0 utan WMF 5.1.
- `SupportFiles\x86\NICE_x86.exe` finns för 32-bitars NICE, men hjälper inte när själva Notes-kitet är x64.

**Slutsats:** räkna med **Windows 10/11 x64** (eller Server-klient-OS som HCL stöder). Win7 x86/x64 är inte ett realistiskt mål för detta paket.

## Föreslagen ordning

1. **VC++ Redistributable 2015–2022** (x64 + x86) – `vcruntime140_1.dll`  
2. **NICE** – rensa gammal klient, därefter explicit borttagning av `C:\ProgramData\HCL\Notes` (inkl. `Data\Shared`) — NICE i multi-user tar inte bort shared data  
3. **Hosts** – bara med `-AddToHostsAsSetupServer -HostsIp … -HostsName …` (default: orörd)  
4. **`rcpInstallerTemp.properties`** – rensa i TEMP innan setup  
5. **Notes 14.5.1** – multi-user via properties (eller custom MST)  
6. **Kopiera lös `SetupNotes.txt`** → `C:\Program Files\HCL\Notes\license\`  
7. **FP1** – ovanpå 14.5.1  
8. **Language pack Swedish** – bara om engelskt bas-kit  
9. **Genvägar** – tar bort Notes Minder, mappen Support (nsd) och skrivbordsikonen **HCL Notes** (`C:\Users\Public\Desktop`). Start-meny **Notes** lämnas. Hoppa över med `-SkipShortcutCleanup`.  
10. **ncompact** – valfritt (`-RunCompact`)  

### Genvägar som tas bort

Efter install rensar scriptet (alla användare + ProgramData):

| Genväg | Mål |
|---|---|
| `...\Start Menu\Programs\HCL Applications\Notes Minder` | `C:\Program Files\HCL\Notes\nminder.exe` |
| `...\Start Menu\Programs\HCL Applications\Support\` (hela mappen) | `nsd.exe -hang` och `nsd.exe -hang -kill` |
| `C:\Users\Public\Desktop\HCL Notes` | `C:\Program Files\HCL\Notes\notes.exe` |

Start-menygenvägen **Notes** lämnas. `notes.exe` / `nminder.exe` / `nsd.exe` i Program Files raderas **inte**. Hoppa över med `-SkipShortcutCleanup`.

Redan installerad PC, elevated PowerShell:

```powershell
$base = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\HCL Applications"
Remove-Item -LiteralPath "$base\Notes Minder.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$base\Support" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$env:PUBLIC\Desktop\HCL Notes.lnk" -Force -ErrorAction SilentlyContinue
```

### FP1 måste vara tyst (noll UI)

```text
C:\install\Notes1451\
  Notes_1451FP1_x64\
    setup.exe          <-- kravs
    *.msi
    ...
```

Packa upp attached kit **en gång** manuellt, lägg mappen `Notes_1451FP1_x64\` i mediakitet, och distribuera den.

Tyst install (elevated CMD):

```bat
cd /d C:\install\Notes1451
scripts\Install-NotesFP1-Silent.cmd
```

Eller manuellt:

```bat
cd /d C:\install\Notes1451\Notes_1451FP1_x64
setup.exe /s /v"/qn REBOOT=ReallySuppress /l*v C:\install\Notes1451\logs\HCL_Notes_1451_FP1.log"
```

`install_notes.ps1` letar efter `MediaRoot\Notes_1451FP1_x64\setup.exe` och kör samma sak. Auto-extract av `.exe` är borttagen (opålitlig / `The system cannot find the path specified`).

Stäng Notes innan FP1 — annars kan en “stäng klienten”-dialog visas trots `/qn`.

## Language pack (Swedish)

Om ni kör **svenskt kit** (`Notes_1451_Win64_Swedish` med `HCL Notes 14.5.1 x64.msi`) behövs **inget separat language pack** – `RCPLOCALE=sv` / `ProductLanguage=1053` sitter redan i MSI:n.

Separat cascaded MUI (`All_MUI_Notes_Client.exe`, Group 2a / `ADDLOCAL=Swedish`) behövs bara om basen är engelskt kit.

## Felsökning: `VCRUNTIME140_1.dll was not found`

`nlnotes.exe` (Notes-klienten) är byggd mot **Microsoft Visual C++ 2015–2022**. `vcruntime140_1.dll` är en senare del av samma runtime (x64 exception handling). Den ingår **inte** i Windows 10.

En helt ny Win10 utan Office/annan C++-mjukvara saknar DLL:en. Felmeddelandet kommer från Windows när Notes startas — inte från vårt script, och inte från en trasig MSI.

**Direktfix på den maskinen (elevated):**

```powershell
# x64 (det som nlnotes.exe saknar) + x86 (Notes Expeditor / vissa CA:er)
Start-Process 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
Start-Process 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
```

Eller tyst:

```bat
vc_redist.x64.exe /install /quiet /norestart
vc_redist.x86.exe /install /quiet /norestart
```

Kontroll:

```powershell
Test-Path C:\Windows\System32\vcruntime140_1.dll
Test-Path C:\Windows\SysWOW64\vcruntime140_1.dll
```

Starta Notes igen. Du behöver **inte** installera om Notes om klienten redan ligger på disk.

**I paketet:** lägg de två exe-filerna i `SupportFiles\vcredist\`. Nästa `install_notes.ps1` installerar dem före Notes.

## Felsökning: setup.exe exit **1155**

InstallShield **1155** = setup.exe hittar inte MSI-filen. Filnamnet måste matcha `Setup.ini`:

```ini
PackageName=HCL Notes 14.5.1 x64.msi
```

Använd det namnet i kitmappen (inte t.ex. `HCL_Notes_1451_x64_sv.msi`). Scriptet förväntar `HCL Notes 14.5.1 x64.msi` som default.

## Felsökning: Error 1723 / 1157 (`CleanupDynamicFeatures`)

Typiskt loggutdrag:

```text
CustomAction CleanupDynamicFeatures.... returned actual error code 1157
Fel 1723. ... A DLL required for this install to complete could not be run.
Action CleanupDynamicFeatures...., entry: CleanupDynamicFeatures
Installation success or error status: 1603
```

**Det betyder inte att MST:en är trasig.** I er logg hann transformen appliceras (`INSTALLCONFIGURATION=multiuser`, `ALLUSERS=1`) innan Expeditor-CA:n dog.

Error **1157** = custom action-DLL:en kunde inte laddas (saknad beroende-DLL), inte att själva CA-logiken failade.

### Kontrollera i denna ordning

1. **Manuell GUI-install utan MST**  
   Kör `setup.exe` från kitmappen. Fungerar GUI men inte silent → miljö/CA; failar GUI också → runtime/media.
2. **Installera Visual C++ Redistributable (x86 + x64)**  
   Notes Expeditor-CA:er (t.ex. `CleanupDynamicFeatures`) behöver ofta VC++ 2015–2022.
3. **Kör via `setup.exe`, inte bara `msiexec /i *.msi`**  
   ```bat
   setup.exe /s /v"TRANSFORMS=HCL_Notes_1451_x64_sv.mst /l*v setup.log /qn"
   ```
4. **Temp-rättigheter** – full control på `%TEMP%` / `C:\Users\<user>\AppData\Local\Temp` för kontot som installerar.
5. **AV/EDR** – tillåt tillfälligt eller exkludera `C:\Windows\Installer\` och kitmappen.
6. **Gamla profilspår** – loggen visar både `C:\Users\mikaekel\...` och `C:\Users\mikaekel.TUVAN\...`. Rensa gammal Notes/NICE och orphaned HCL/Lotus-nycklar om profilen bytt namn/domän.
7. **Komplett kit** – MSI + `setup.exe` + kab/supportfiler i samma mapp; kör inte en bortkopierad ensam MSI.

### Bra tecken i er logg (inte rotorsak)

| Loggrad | Betydelse |
|---|---|
| `Transforming table Property` | MST laddades |
| `INSTALLCONFIGURATION = multiuser` | Multi-user från MST/CA |
| `ALLUSERS = 1` | Per-machine / elevated OK |
| `Product is being installed per-machine` | Admin-context OK |

## Felsökning: Error 2254 (`Table: Shortcut`)

```text
Error 2254.Database: Transform: Cannot update row that does not exist. Table: Shortcut.
```

**Betydelse:** MST:en innehåller en **UPDATE** mot en rad i `Shortcut`-tabellen vars primärnyckel **inte finns** i bas-MSI:n (`HCL_Notes_1451_x64_sv.msi`).

Vanlig orsak i Master Packager: genvägar på skrivbord/startmeny “tas bort” eller ändras så att transformen sparar **modify/update** i stället för **delete** – eller så matchar Shortcut-ID:n inte det svenska kitet (Response Transform fångade fel nycklar).

Symptomtriangeln:

| Test | Resultat |
|---|---|
| `setup.exe` utan MST | Fungerar |
| `setup.exe` + MST | Error 2254 Shortcut |
| Slutsats | MST:ens Shortcut-ändringar är trasiga |

### Åtgärda i Master Packager

1. Öppna MSI + befintlig MST (eller skapa ny MST från samma `HCL_Notes_1451_x64_sv.msi`).
2. Gå till tabellen **Shortcut**.
3. Ta bort skrivbords-/startmenygenvägar som **Delete row** (radera raden), inte via UI-toggle som bara ändrar fält på en rad som inte finns.
4. Kontrollera att kvarvarande Shortcut-rader har samma **Shortcut**-primärnyckel som i bas-MSI:n (jämför med Orca / Master Packager utan transform).
5. Lämna gärna Notes huvudgenväg; ta bara bort det ni verkligen inte vill ha (t.ex. extra genvägar).
6. Spara ny MST och testa:

```bat
setup.exe /s /v"TRANSFORMS=HCL_Notes_1451_x64_sv.mst /l*v setup.log /qn"
```

### Snabb verifiering utan att gissa

Bygg tillfälligt en MST **utan** Shortcut-ändringar (bara `ALLUSERS`, `SETMULTIUSER` / multi-user, `notes.ini`/`ConfigFile`). Om den installerar rent är Shortcut-delen den enda boven — lägg tillbaka genvägsborttagning som rena deletes.

### Alternativ om delete krånglar

Dölj genvägar i stället för att radera: ta bort dem från Feature/Component, eller låt dem installeras och rensa med script efteråt (`Remove-Item` på Desktop/Start Menu). Mindre elegant, men stabilt i SCCM-flöden.
