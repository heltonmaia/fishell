@echo off
rem Launcher que roda o fishell.ps1 sem precisar ajustar ExecutionPolicy.
rem Uso: bin\fishell.cmd [setup|login|test|upload|download|run|keygen|forget|status|help]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\src\powershell\fishell.ps1" %*
