@echo off
chcp 65001 >nul
title DSH 手机遥控 - 一键启动
echo ==========================================
echo   DSH 手机遥控 - 电脑端一键启动
echo ==========================================
echo.

rem 1. 检查 cpolar 是否就位
if not exist "D:\tools\cpolar\bin\cpolar.exe" (
  echo [错误] 找不到 cpolar，请先下载到 D:\tools\cpolar\bin\
  pause
  exit /b 1
)

rem 2. 显示认证密钥（手机 App 要填的）
if exist "%USERPROFILE%\.dsh\.credentials.yaml" (
  echo ---- 手机 App 的「认证密钥」是下面这行 ----
  powershell -NoProfile -Command "$c = Get-Content \"$env:USERPROFILE\.dsh\.credentials.yaml\" -Raw; $m = [regex]::Match($c, 'browser-session[\s\S]*?secret:\s*(\S+)'); if ($m.Success) { $m.Groups[1].Value } else { '未找到' }"
  echo --------------------------------------------------
  echo.
)

rem 3. 检查 DSH 是否运行（57575 监听）
echo 正在检查 DSH 端口 57575 ...
powershell -NoProfile -Command "$l = netstat -ano | Select-String ':57575 ' | Select-String 'LISTENING'; if ($l) { 'DSH 正常。' } else { '警告：57575 没在监听！请先启动 DSH NEXT。' }"

rem 4. 检查 cpolar 登录
if not exist "%USERPROFILE%\.cpolar\cpolar.yml" (
  echo [提示] cpolar 还没登录。执行一次：
  echo        D:\tools\cpolar\bin\cpolar.exe authtoken 你的token
  pause
  exit /b 1
)

rem 5. 启动反代（剥离 Origin，手机收消息必需）
echo 正在启动反代（57590 -^> 57575）...
start "DSH反代" /min "D:\dsh_next\DSH NEXT\resources\runtime\x64\primary-runtime\dependencies\node\bin\node.exe" "%~dp0dsh-ws-proxy.js"

rem 6. 启动 cpolar 隧道
echo 正在启动 cpolar 隧道...
echo 手机 App 的「服务器地址」在 cpolar 窗口里看（https://xxx.cpolar.top）
echo 两个窗口都要保持打开！
echo.
"D:\tools\cpolar\bin\cpolar.exe" http -host-header=127.0.0.1:57590 -inspect-addr 127.0.0.1:4040 57590
