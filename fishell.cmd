@echo off
rem Launcher que roda fishell.ps1 sem precisar ajustar ExecutionPolicy.
rem Uso: fishell.cmd [setup|login|test|upload|download|status|help]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fishell.ps1" %*
