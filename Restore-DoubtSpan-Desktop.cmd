@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DoubtSpan.ps1" -RestorePreferences
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DoubtSpan.ps1" -RestoreDisplay
echo.
echo Recuperacao terminada. As operacoes sem estado guardado podem apresentar um aviso normal.
pause
