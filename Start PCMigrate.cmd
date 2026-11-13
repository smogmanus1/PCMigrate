@echo off
rem ==========================================================================
rem  Start PCMigrate.cmd
rem  Starts PCMigrate.ahk with AutoHotkey v2 directly, so it works even when
rem  double-clicking .ahk files is broken ("This app can't run on your PC").
rem  Part of PCMigrate (MIT) - Brad Schrunk & Claude (Anthropic)
rem ==========================================================================
setlocal
set "SCRIPT=%~dp0PCMigrate.ahk"

rem 64-bit Windows (Intel/AMD or ARM) uses AutoHotkey64.exe; 32-bit Windows uses AutoHotkey32.exe
set "EXE=AutoHotkey64.exe"
if /i "%PROCESSOR_ARCHITECTURE%"=="x86" if not defined PROCESSOR_ARCHITEW6432 set "EXE=AutoHotkey32.exe"

set "AHK="
set "DIR="
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\AutoHotkey" /v InstallDir 2^>nul ^| find /i "InstallDir"') do set "DIR=%%B"
if defined DIR if exist "%DIR%\v2\%EXE%" set "AHK=%DIR%\v2\%EXE%"
set "DIR="
if not defined AHK for /f "tokens=2,*" %%A in ('reg query "HKCU\SOFTWARE\AutoHotkey" /v InstallDir 2^>nul ^| find /i "InstallDir"') do set "DIR=%%B"
if not defined AHK if defined DIR if exist "%DIR%\v2\%EXE%" set "AHK=%DIR%\v2\%EXE%"
if not defined AHK if exist "%ProgramFiles%\AutoHotkey\v2\%EXE%" set "AHK=%ProgramFiles%\AutoHotkey\v2\%EXE%"
if not defined AHK if exist "%LOCALAPPDATA%\Programs\AutoHotkey\v2\%EXE%" set "AHK=%LOCALAPPDATA%\Programs\AutoHotkey\v2\%EXE%"
if not defined AHK goto :missing

if not exist "%SCRIPT%" (
    echo Can't find PCMigrate.ahk next to this file:
    echo   %SCRIPT%
    echo Keep the PCMigrate folder together.
    pause
    exit /b 1
)
start "" "%AHK%" "%SCRIPT%"
exit /b 0

:missing
echo.
echo AutoHotkey v2 is not installed on this PC.
echo.
echo Install it from https://www.autohotkey.com
echo or open Command Prompt and type:   winget install AutoHotkey.AutoHotkey
echo.
echo PCMigrate also runs without AutoHotkey - see "Without AutoHotkey" in README.md.
echo.
pause
exit /b 1
