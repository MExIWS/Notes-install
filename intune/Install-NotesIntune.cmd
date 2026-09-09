@echo off
setlocal
rem Intune IME is 32-bit. SysNative forces 64-bit PowerShell so x64 Notes MSI/setup.exe works.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe" (
  set "PS=%SystemRoot%\SysNative\WindowsPowerShell\v1.0\powershell.exe"
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-NotesIntune.ps1"
exit /b %ERRORLEVEL%
