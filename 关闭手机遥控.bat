@echo off
chcp 65001 >nul
title 关闭手机遥控服务
echo ==========================================
echo   关闭手机遥控服务
echo ==========================================
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-service.ps1"
echo.
pause
