@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe" (
  set "PS=%SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe"
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-NotesIntune.ps1"
exit /b %ERRORLEVEL%
