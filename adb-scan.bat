@echo off
setlocal
title ADB Scan

:: Uses the adb.exe sitting next to this file - nothing needs to be installed
:: and nothing needs to be on your system PATH.

echo.
echo   Scanning for connected Android devices...
echo.

"%~dp0adb.exe" start-server >nul 2>&1
"%~dp0adb.exe" devices -l

echo.
echo   If the list above is empty, or your headset shows as "unauthorized":
echo     - Put the headset on and look for the "Allow USB debugging" prompt.
echo     - Tick "Always allow from this computer", then hit Allow.
echo     - If no prompt appears, unplug the cable and plug it back in.
echo.
pause
endlocal
