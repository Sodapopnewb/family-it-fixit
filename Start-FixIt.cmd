@echo off
rem Family Fix-It launcher: double-click this. It opens the friendly window.
rem Windows asks for permission once, then the program is already an administrator.
rem It starts the tool and then closes itself, so the tool can update this file safely.
set "FIXIT_SCRIPT=%~dp0FamilyFixIt.ps1"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "try { $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $arg = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ""' + $env:FIXIT_SCRIPT + '""'; Start-Process -FilePath $ps -ArgumentList $arg -WindowStyle Hidden -Verb RunAs } catch { }"
exit /b 0
