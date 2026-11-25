@echo off
chcp 65001 >nul
title C ≈Ã¿©»›’Ô∂œ
set GB=%~1
if "%GB%"=="" set GB=10
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\check-partitions.ps1" -TakeGB %GB%
echo.
pause
