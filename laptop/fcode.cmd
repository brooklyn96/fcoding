@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fcode.ps1" %*
exit /b %errorlevel%
