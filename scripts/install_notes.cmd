robocopy \\dc02\Install\Notes-1451 "%TEMP%\Notes1451" /E /R:2 /W:2
if %ERRORLEVEL% GEQ 8 exit /b %ERRORLEVEL%

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\Notes1451\SupportFiles\scripts\install_notes.ps1" -MediaRoot "%TEMP%\Notes1451" -DominoName "Zeus/Tuvan" -DominoAddress "zeus.tuvan.local" -HostsName zeus.tuvan.local