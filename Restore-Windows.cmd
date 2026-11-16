@echo off
setlocal
echo BetterIcon-Craft Apps - Restore original Windows icons
echo Select the same scope used during installation.
echo.
echo 1. Current user's Desktop and Start menu
echo 2. All users' Desktop and Start menu (administrator required)
choice /c 12 /n /m "Choose scope [1/2]: "
if errorlevel 2 goto allusers
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
goto done
:allusers
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" -Scope AllUsers
:done
set "result=%errorlevel%"
echo.
pause
exit /b %result%
