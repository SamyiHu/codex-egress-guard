@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-CodexEgressPolicy.ps1" -State Status
pause
