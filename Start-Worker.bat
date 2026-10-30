@echo off
cd /d "%~dp0"
if not exist G:\ if exist C:\ListingBots subst G: C:\ListingBots
set "PATH=%LOCALAPPDATA%\Programs\Python\Python312;%LOCALAPPDATA%\Programs\Python\Python312\Scripts;%PATH%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Worker.ps1"
echo.
pause
