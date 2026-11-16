@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Tray.ps1" -CreateStartMenuShortcut
if errorlevel 1 pause
