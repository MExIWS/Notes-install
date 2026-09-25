@echo off
REM Silent install of HCL Notes 14.5.1 FP1 from unpacked kit
REM Run elevated from media root:
REM   cd /d C:\install\Notes1451
REM   scripts\Install-NotesFP1-Silent.cmd
REM
REM Forvantar: Notes_1451FP1_x64\setup.exe
REM (packa upp Notes_1451FP1_x64.exe manuellt en gang och distribuera mappen)

setlocal
set "KITDIR=%CD%"
if exist "%~dp0..\Notes_1451FP1_x64\setup.exe" set "KITDIR=%~dp0.."
if exist "%~dp0Notes_1451FP1_x64\setup.exe" set "KITDIR=%~dp0"

set "FPDIR=%KITDIR%\Notes_1451FP1_x64"
if not exist "%FPDIR%\setup.exe" (
  echo ERROR: Hittar inte %FPDIR%\setup.exe
  echo Packa upp Notes_1451FP1_x64.exe och lagg mappen under mediakitet.
  exit /b 1
)

cd /d "%KITDIR%"
if not exist "logs" mkdir logs
set "FPLOG=%CD%\logs\HCL_Notes_1451_FP1.log"

echo.
echo Installerar FP1 tyst fran:
echo   %FPDIR%\setup.exe
echo.

pushd "%FPDIR%"
setup.exe /s /v"/qn REBOOT=ReallySuppress /l*v %FPLOG%"
set RC=%ERRORLEVEL%
if %RC%==0 goto :done
if %RC%==3010 goto :done

echo setup.exe /v"/qn..." exit %RC% - provar /s /v/qn
setup.exe /s /v/qn
set RC=%ERRORLEVEL%

:done
popd
echo.
echo ExitCode=%RC%
echo Log: %FPLOG%
exit /b %RC%
