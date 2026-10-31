# 启动 DSH 手机遥控服务：启动反代 + cpolar 隧道（后台运行，窗口可关）
$ErrorActionPreference = 'SilentlyContinue'

$nodeExe = 'D:\dsh_next\DSH NEXT\resources\runtime\x64\primary-runtime\dependencies\node\bin\node.exe'
$proxyJs = Join-Path $PSScriptRoot 'dsh-ws-proxy.js'
$cpolarExe = 'D:\tools\cpolar\bin\cpolar.exe'
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# 1. DSH 检查
Write-Host "检查 DSH（57575）..." -ForegroundColor Cyan
$dsh = netstat -ano | Select-String ':57575 .*LISTENING'
if ($dsh) { Write-Host "  DSH 正常" -ForegroundColor Green } else { Write-Host "  [警告] 57575 没在监听，请先启动 DSH NEXT" -ForegroundColor Yellow }

# 2. 反代
Write-Host "检查反代（57590）..." -ForegroundColor Cyan
$proxyRunning = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*dsh-ws-proxy*' }
if ($proxyRunning) {
  Write-Host "  反代已在运行" -ForegroundColor Green
} else {
  Start-Process -FilePath $nodeExe -ArgumentList "`"$proxyJs`"" -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $logDir 'proxy.log') `
    -RedirectStandardError (Join-Path $logDir 'proxy.err')
  Start-Sleep -Seconds 2
  $ok = netstat -ano | Select-String ':57590 .*LISTENING'
  if ($ok) { Write-Host "  反代已启动（57590）" -ForegroundColor Green } else { Write-Host "  反代启动失败，看 logs\proxy.err" -ForegroundColor Red }
}

# 3. cpolar
Write-Host "检查 cpolar..." -ForegroundColor Cyan
$cpolarRunning = Get-Process -Name cpolar
if ($cpolarRunning) {
  Write-Host "  cpolar 已在运行" -ForegroundColor Green
} else {
  Start-Process -FilePath $cpolarExe -ArgumentList 'http','-host-header=127.0.0.1:57590','-inspect-addr','127.0.0.1:4040','57590' `
    -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $logDir 'cpolar.log') `
    -RedirectStandardError (Join-Path $logDir 'cpolar.err')
  Start-Sleep -Seconds 8
  $ok2 = netstat -ano | Select-String ':4040 .*LISTENING'
  if ($ok2) { Write-Host "  cpolar 已启动" -ForegroundColor Green } else { Write-Host "  cpolar 启动失败，看 logs\cpolar.err" -ForegroundColor Yellow }
}

# 4. 取隧道地址
Write-Host ""
Write-Host "获取隧道地址..." -ForegroundColor Cyan
$url = ''
for ($i = 0; $i -lt 10; $i++) {
  try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:4040/' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $content = $r.Content
    if ($content -is [byte[]]) {
      $html = [System.Text.Encoding]::UTF8.GetString($content)
    } else {
      $html = [string]$content
    }
    $m = [regex]::Match($html, 'https://([a-z0-9]+\.r\d+\.cpolar\.top)')
    if ($m.Success) {
      $url = 'https://' + $m.Groups[1].Value
      break
    }
  } catch { }
  Start-Sleep -Seconds 2
}

# 5. 显示密钥
Write-Host ""
if (Test-Path "$env:USERPROFILE\.dsh\.credentials.yaml") {
  $c = Get-Content "$env:USERPROFILE\.dsh\.credentials.yaml" -Raw
  $m = [regex]::Match($c, 'browser-session[\s\S]*?secret:\s*(\S+)')
  if ($m.Success) {
    Write-Host "手机 App 的「认证密钥」：" -ForegroundColor Cyan
    Write-Host ("  " + $m.Groups[1].Value) -ForegroundColor White
  }
}

Write-Host ""
if ($url -ne '') {
  Write-Host "手机 App 的「服务器地址」：" -ForegroundColor Cyan
  Write-Host ("  " + $url) -ForegroundColor Green
  Write-Host ""
  Write-Host "（若地址与 App 里填的不同，去 App 设置里改成上面的地址）" -ForegroundColor Gray
} else {
  Write-Host "隧道地址获取失败。浏览器打开 http://127.0.0.1:4040 手动查看" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "服务已在后台运行，本窗口可以关闭。" -ForegroundColor Green
Write-Host "要关闭服务：双击「关闭手机遥控」。"
