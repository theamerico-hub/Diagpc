@echo off
title DiagPC
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0DiagPC.ps1" %*
