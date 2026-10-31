@echo off
chcp 65001 >nul
title DSH 手机遥控 - 启动服务
echo ==========================================
echo   DSH 手机遥控 - 启动服务
echo ==========================================
echo.

rem 1. 检查 cpolar 是否就位
if not exist "D:\tools\cpolar\bin\cpolar.exe" (
  echo [错误] 找不到 cpolar，请先下载到 D:\tools\cpolar\bin\
  pause
  exit /b 1
)

rem 2. 检查 DSH 是否运行（57575 监听）
powershell -NoProfile -Command "$l = netstat -ano | Select-String ':57575 ' | Select-String 'LISTENING'; if ($l) { Write-Host 'DSH 正常（57575 监听中）。' } else { Write-Host '[警告] 57575 没在监听！请先启动 DSH NEXT。' -ForegroundColor Yellow }"

rem 3. 检查反代是否已在运行
for /f %%i in ('powershell -NoProfile -Command "(Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | Where-Object { $_.CommandLine -like '*dsh-ws-proxy*' } | Measure-Object).Count"') do set PROXY_COUNT=%%i
if "%PROXY_COUNT%"=="0" (
  echo 正在启动反代（57590 -^> 57575）...
  start "DSH反代" /min "D:\dsh_next\DSH NEXT\resources\runtime\x64\primary-runtime\dependencies\node\bin\node.exe" "%~dp0dsh-ws-proxy.js"
) else (
  echo 反代已在运行，跳过。
)

rem 4. 检查 cpolar 是否已在运行
tasklist /fi "imagename eq cpolar.exe" 2>nul | findstr /i "cpolar.exe" >nul
if not errorlevel 1 (
  echo cpolar 已在运行，跳过启动。
  echo.
  echo 查看当前隧道地址：浏览器打开 http://127.0.0.1:4040
  echo.
  goto done
)

rem 5. 检查 cpolar 登录
if not exist "%USERPROFILE%\.cpolar\cpolar.yml" (
  echo [提示] cpolar 还没登录。执行一次：
  echo        D:\tools\cpolar\bin\cpolar.exe authtoken 你的token
  pause
  exit /b 1
)

rem 6. 显示认证密钥（手机 App 要填的）
if exist "%USERPROFILE%\.dsh\.credentials.yaml" (
  echo ---- 手机 App 的「认证密钥」是下面这行 ----
  powershell -NoProfile -Command "$c = Get-Content \"$env:USERPROFILE\.dsh\.credentials.yaml\" -Raw; $m = [regex]::Match($c, 'browser-session[\s\S]*?secret:\s*(\S+)'); if ($m.Success) { $m.Groups[1].Value } else { '未找到' }"
  echo --------------------------------------------------
  echo.
)

echo 正在启动 cpolar 隧道...
echo.
echo ==========================================================
echo  手机 App 的「服务器地址」= 下面显示的 https://xxx.cpolar.top
echo  关闭方法：双击《关闭手机遥控.bat》，或直接关掉本窗口
echo ==========================================================
echo.
"D:\tools\cpolar\bin\cpolar.exe" http -host-header=127.0.0.1:57590 -inspect-addr 127.0.0.1:4040 57590

:done
echo.
echo 服务已就绪。要关闭：双击《关闭手机遥控.bat》。
pause
