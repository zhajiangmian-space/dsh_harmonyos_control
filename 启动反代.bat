@echo off
chcp 65001 >nul
title DSH 反代（剥离 Origin）
echo DSH 反代运行中：127.0.0.1:57590 -> 127.0.0.1:57575
echo 保持窗口打开！关闭窗口手机端 WebSocket 就断。
echo.
"D:\dsh_next\DSH NEXT\resources\runtime\x64\primary-runtime\dependencies\node\bin\node.exe" "%~dp0dsh-ws-proxy.js"
pause
