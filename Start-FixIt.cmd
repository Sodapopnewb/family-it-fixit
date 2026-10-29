@echo off
rem Family Fix-It launcher: double-click this. It opens the friendly window.
rem It starts the tool and then closes itself, so the tool can update this file safely.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0FamilyFixIt.ps1"
exit /b 0
