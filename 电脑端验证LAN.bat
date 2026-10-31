@echo off
chcp 65001 >nul
title DSH LAN 模式验证
echo 正在验证 DSH 局域网模式（需要已重启 DSH、已装 Tailscale）...
echo.
"D:\dsh_next\DSH NEXT\resources\runtime\x64\primary-runtime\dependencies\node\bin\node.exe" "%~dp0verify_lan.js" %*
echo.
pause
