@echo off
chcp 65001 >nul
setlocal
rem ============================================================
rem  Google Chrome Portable updater - double-click launcher
rem  Copy this file and Update-ChromePortable.ps1 together into
rem  your GoogleChromePortable folder, then double-click this.
rem  Extra arguments are passed through to the PowerShell script,
rem  e.g. Update-ChromePortable.bat -CloseChrome -Launch
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-ChromePortable.ps1" %*
echo.
pause
endlocal
