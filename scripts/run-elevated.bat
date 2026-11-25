@echo off
rem Generic self-elevating launcher for the windows-bluetooth-repair skill.
rem Usage: double-click, or run-elevated.bat install-guard.ps1
rem NOTE: an AI agent cannot spawn an elevated process on this host (blocked by
rem       the shell security policy). Hand this .bat to the human instead.
setlocal
set "SCRIPT=%~1"
if "%SCRIPT%"=="" set "SCRIPT=diagnose-bluetooth.ps1"

net session >nul 2>&1
if %errorlevel%==0 goto run

echo Requesting administrator rights...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%SCRIPT%'"
exit /b

:run
echo Running %SCRIPT% ...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0%SCRIPT%"
echo.
echo Finished.
timeout /t 12 >nul
