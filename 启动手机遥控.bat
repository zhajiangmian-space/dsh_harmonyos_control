@echo off
chcp 65001 >nul
title 启动手机遥控服务
echo ==========================================
echo   启动手机遥控服务
echo ==========================================
echo.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-service.ps1"
echo.
pause
