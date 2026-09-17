@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0WU-ON_OFF-Tools-1.5.ps1"
endlocal
