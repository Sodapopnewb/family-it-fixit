@echo off
rem Install Family Fix-It: double-click this file. No administrator needed.
rem If you opened this from inside the downloaded zip, it still works: it fetches the installer itself.
title Install Family Fix-It
echo.
echo   Installing Family Fix-It. Please wait - this takes about a minute.
echo.
if not exist "%~dp0Install-FixIt.ps1" goto web
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-FixIt.ps1"
goto finished
:web
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}; irm https://raw.githubusercontent.com/Sodapopnewb/family-it-fixit/main/Install-FixIt.ps1 | iex; exit $global:FixItInstallExitCode"
:finished
if errorlevel 1 goto failed
echo.
echo   This window closes by itself in a few seconds.
timeout /t 8 /nobreak >nul
exit /b 0
:failed
echo.
echo   The install did not finish. Nothing was damaged.
echo   Please tell Trey what you see above, then press any key to close this window.
pause >nul
exit /b 1
