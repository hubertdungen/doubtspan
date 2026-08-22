@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DoubtSpan.ps1" %*
set "DOUBTSPAN_EXIT=%ERRORLEVEL%"
echo.
if not "%DOUBTSPAN_EXIT%"=="0" echo DoubtSpan terminou com o codigo %DOUBTSPAN_EXIT%.
pause
exit /b %DOUBTSPAN_EXIT%
