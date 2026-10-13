@echo off
:: ZAPRET AUTOPILOT - launcher for Flowseal zapret-discord-youtube
:: Usage:
::   zapret-autopilot.bat            - simple screen (first run: find/install, repair, tune, enable)
::   zapret-autopilot.bat auto       - do everything without questions
::   zapret-autopilot.bat menu       - advanced menu
::   zapret-autopilot.bat settings   - settings (AUTO/manual mode, install folder, shortcuts...)
::   zapret-autopilot.bat cycle      - diagnostics -> tests -> start best (update zapret if nothing works)
::   zapret-autopilot.bat start      - start remembered best strategy
::   zapret-autopilot.bat stop       - stop winws
::   zapret-autopilot.bat diag       - diagnostics only
::   zapret-autopilot.bat test       - tests only
::   zapret-autopilot.bat rollback   - restore previous zapret version from backup

:: English console output makes netsh/sc parsable, like service.bat does
chcp 437 > nul

if not exist "%~dp0autopilot.ps1" (
    echo.
    echo   autopilot.ps1 not found next to this file.
    echo   Extract the WHOLE archive into a folder first, then run zapret-autopilot.bat from there.
    echo.
    pause
    exit /b 1
)

:: Admin rights (fltmc works only elevated and does not depend on the Server service)
fltmc > nul 2>&1
if errorlevel 1 (
    echo Requesting admin rights...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

title Zapret
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autopilot.ps1" %*
