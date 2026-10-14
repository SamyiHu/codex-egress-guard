@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-CodexEgressPolicy.ps1" -State Blocked
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-CodexEgressPolicy.ps1" -State Status
echo.
echo Codex/ChatGPT external egress is now blocked.
pause
