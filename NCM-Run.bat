@echo off
setlocal
title Quest USB NCM Link

:: Administrator is required: assigning the PC's address on the USB network
:: adapter, creating the NAT, and adding the firewall rule are all privileged.
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo   Quest USB NCM Link needs administrator rights.
    echo   Please approve the UAC prompt...
    if "%~1"=="" (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0QuestNcmLink.ps1" %*

echo.
pause
endlocal
