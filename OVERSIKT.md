# HCL Notes 14.5.1 – vad paketet gör

Tyst, per-maskin-install av **HCL Notes 14.5.1 FP1** (svenskt kit, multi-user) för Windows 10/11 x64.

Ett script gör hela kedjan: `SupportFiles\scripts\install_notes.ps1`.  
Samma script används från **LAN/PDQ** och (om ni vill senare) **Intune Win32**.

---

## Målet

- Notes installeras för **alla användare på datorn** (`ALLUSERS=1`, `SETMULTIUSER=1`).
- Första användarstart ska gå mot er Domino-server utan extra dialoger.
- Ingen custom MST krävs (default).
- Gammal klient städas bort före ny install.

---

## Vad som körs, i ordning

| # | Steg | Default |
|---|---|---|
| 0 | Avbryt om Notes kör (`notes`/`nlnotes`/…) — **exit 10**. `-ForceCloseNotes` dödar och fortsätter | På (avbryt) |
| 1 | Spegla kit från UNC/LAN till lokal disk (`C:\install\Notes-1451`, eller `-LocalMediaRoot`) | På om källan är nätverk |
| 2 | Visual C++ 2015–2022 om `vcruntime140_1.dll` saknas (naken Win10 / gammal 2017-redist) | På |
| 3 | **NICE** – avinstallera tidigare Notes | På |
| 4 | Rensa kvarvarande `ProgramData\HCL\Notes` m.m. (NICE lämnar shared data) | På |
| 5 | Ta bort `rcpInstallerTemp.properties` i TEMP (Notes 14.5.1-bugg) | På |
| 6 | `setup.exe` svenskt kit, tyst `/qn` | På |
| 6b | Hoppa över integrerad Sametime (`REMOVEFEATURES=SametimeUI`) | Av – `-SkipSametime` |
| 7 | Kopiera lös `SetupNotes.txt` till `C:\Program Files\HCL\Notes\license\` | På |
| 8 | Patcha shared `notes.ini` under ProgramData (`ConfigFile=`, Domino-fält) | På |
| 9 | Fix Pack 1 från uppackat kit | På |
| 10 | Ta bort Notes Minder, NSD Support, skrivbordsikon **HCL Notes** | På |
| 11 | Language pack (MUI Group 2a) | Av – behövs inte med svenskt kit |
| 12 | Hosts-fil | Av |
| 13 | `ncompact` | Av |

---

## Vad du skickar in vid körning

Typiskt LAN-kommando:

```powershell
& '\\dc02\Install\Notes-1451\SupportFiles\scripts\install_notes.ps1' `
  -MediaRoot '\\dc02\Install\Notes-1451' `
  -DominoName 'Zeus/TUVAN' `
  -DominoAddress 'zeus.tuvan.local'
```

| Parameter | Betydelse |
|---|---|
| `-MediaRoot` | Kit-roten (`Notes-1451\`) |
| `-LocalMediaRoot` | Vart kitet speglas lokalt (default `C:\install\Notes-1451`) |
| `-DominoName` | `Domino.Name` i SetupNotes, t.ex. `Zeus/TUVAN` |
| `-DominoAddress` | `Domino.Address`, t.ex. `zeus` eller `zeus.tuvan.local` |
| `-SkipLocalMirror` | Bara om kitet **redan** ligger lokalt |
| `-Uninstall` | Avinstallera (NICE + msiexec-fallback + residualer). Inte install. |
| `-SkipSametime` | Tyst: installera inte **Sametime (integrerad)** (`REMOVEFEATURES=SametimeUI`) |
| `-RemoveUserData` | Bara med `-Uninstall`: radera även per-användardata (ID/NSF). Default av. |
| `-AddToHostsAsSetupServer` | Opt-in: skriv IP/namn i `hosts` |

Avinstallera (samma script, ingen ny MSI-kedja):

```powershell
& '\\dc02\Install\Notes-1451\SupportFiles\scripts\install_notes.ps1' `
  -Uninstall `
  -MediaRoot '\\dc02\Install\Notes-1451'
```

NICE (`-rp /qn`) räcker inte ensamt: scriptet tar också kvarvarande MSI, ProgramData/Program Files och genvägar. Per-användardata (ID-fil, NSF) lämnas. Lab-wipe: `-RemoveUserData`. Notes öppet → exit **10**, samma som vid install (`-ForceCloseNotes` för att döda).

---

## Vad som **inte** görs (om du inte ber om det)

- Ingen custom MST.
- Ingen hosts-hack (DNS ska räcka).
- Inget separat MUI om baskitet är svenskt.
- `nminder.exe` / `nsd.exe` / `notes.exe` raderas inte – bara genvägar.
- Ingen ncompact vid första install (ingen användardata än).

---

## Media som ska finnas i kit-roten

```text
Notes-1451\
  Notes_1451_Win64_Swedish\     ← klient + setup.exe
  SupportFiles\
    SetupNotes.txt
    Notes_1451FP1_x64\          ← uppackat FP1
    vcredist\                   ← vc_redist.x64.exe + vc_redist.x86.exe (rekommenderas)
    x64\NICE_x64.exe
    x64\Notes.ini
    scripts\install_notes.ps1
```

MUI-mappar (`nl1`, `nl2b`, inbyggd Notes-klient i MUI-packen) kan tas bort om ni bara kör svenskt kit.

---

## Efteråt ska detta stämma

| Kontroll | Förväntat |
|---|---|
| `C:\Program Files\HCL\Notes\notes.exe` | Finns |
| Appar och funktioner | HCL Notes 14.5.1 x64 sv |
| `C:\Windows\System32\vcruntime140_1.dll` | Finns (`True`) |
| `C:\Program Files\HCL\Notes\license\SetupNotes.txt` | Er Domino-server, `Username=%UserName%` |
| `C:\ProgramData\HCL\Notes\Data\notes.ini` | `ConfigFile=` pekar på SetupNotes |
| Start-meny | Notes kvar; Minder / Support borta |
| `C:\Users\Public\Desktop\HCL Notes` | Borta |

---

## Felsökning i korthet

| Symptom | Orsak / åtgärd |
|---|---|
| `FileSystem::\\server\...` / “hittar inte filen” | Kör **ny** `install_notes.ps1`; UNC speglas lokalt |
| Access denied från share | Låt scriptet robocopy; kör inte `setup.exe` från UNC |
| `VCRUNTIME140_1.dll was not found` | VC++ 2017 14.12 räcker inte; senaste 2015–2022-redist |
| Dialoger vid första Notes-start | SetupNotes / `notes.ini` (`AdditionalServices=-1`, `ConfigFile=`) |

**PDQ Deploy:** två steg (robocopy + `install_notes.ps1`). Se README.  
**PSADT 4.1:** skiss i `psadt/` (välkomst + defer 3×, stänger Notes, anropar samma `install_notes.ps1`). Kör `psadt/New-NotesPsadtFolder.ps1` mot officiell mall.

Detaljer, PDQ, Intune, PSADT och MST: se **README.md**.
