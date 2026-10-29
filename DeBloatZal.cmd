@echo off
setlocal
title DeBloatZal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\gui.ps1" %*
if errorlevel 1 pause
