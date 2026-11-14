@echo off
rem SPDX-License-Identifier: GPL-2.0
rem Rago OS - micro-Windows (M5). Lance par Windows Setup (compte SYSTEM) a la fin
rem de l installation ; copie par compile_micro_engine.ps1 dans
rem C:\Windows\Setup\Scripts\SetupComplete.cmd. Meme travail que la passe specialize
rem de autounattend.xml (firstboot.ps1 est idempotent) : Windows ne lance pas
rem SetupComplete.cmd avec une cle OEM, sauf editions Enterprise (doc Microsoft).
rem Fichier en ASCII : cmd.exe lit la page de code OEM.
if not exist "%ProgramData%\Rago\logs" mkdir "%ProgramData%\Rago\logs"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SystemDrive%\Rago\setup\firstboot.ps1" -Phase setupcomplete >> "%ProgramData%\Rago\logs\setupcomplete.log" 2>&1
exit /b 0
