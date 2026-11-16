@echo off
setlocal
echo BetterIcon-Craft Apps - Windows installer
echo For apps installed for everyone, run this file as administrator
echo and choose option 2. Otherwise choose option 1.
echo.
echo 1. Current user's Desktop and Start menu
echo 2. All users' Desktop and Start menu (administrator required)
choice /c 12 /n /m "Choose scope [1/2]: "
if errorlevel 2 goto allusers
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
goto done
:allusers
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Scope AllUsers
:done
set "result=%errorlevel%"
echo.
pause
exit /b %result%
