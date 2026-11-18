@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install_Mod.ps1" -Action Install
set "RESULT=%ERRORLEVEL%"
echo.
if not "%RESULT%"=="0" echo Setup returned error code %RESULT%. Please read any message above.
pause
exit /b %RESULT%
