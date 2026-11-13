@echo off
rem Repairs double-clicking .ahk files ("This app can't run on your PC").
rem Runs tools\Repair-AhkAssociation.ps1 for the signed-in user. No admin rights needed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Repair-AhkAssociation.ps1"
