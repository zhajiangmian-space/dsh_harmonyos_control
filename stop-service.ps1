# 关闭 DSH 手机遥控服务：停止反代 + cpolar 隧道（不影响 DSH NEXT）
$ErrorActionPreference = 'SilentlyContinue'

Write-Host "正在停止反代..." -ForegroundColor Cyan
$proxies = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*dsh-ws-proxy*' }
if ($proxies) {
  foreach ($p in $proxies) {
    Stop-Process -Id $p.ProcessId -Force
    Write-Host ("  已停止反代 PID=" + $p.ProcessId)
  }
} else {
  Write-Host "  反代未在运行"
}

Write-Host "正在停止 cpolar..." -ForegroundColor Cyan
$cpolars = Get-Process -Name cpolar
if ($cpolars) {
  foreach ($p in $cpolars) {
    Stop-Process -Id $p.Id -Force
    Write-Host ("  已停止 cpolar PID=" + $p.Id)
  }
} else {
  Write-Host "  cpolar 未在运行"
}

Start-Sleep -Seconds 2
Write-Host ""
Write-Host "端口检查：" -ForegroundColor Cyan
$port57590 = netstat -ano | Select-String ':57590 .*LISTENING'
$port4040 = netstat -ano | Select-String ':4040 .*LISTENING'
if ($port57590) { Write-Host "  反代端口 57590 仍被占用（稍等几秒再试）" -ForegroundColor Yellow } else { Write-Host "  反代端口 57590 已释放" -ForegroundColor Green }
if ($port4040) { Write-Host "  cpolar 端口 4040 仍被占用（稍等几秒再试）" -ForegroundColor Yellow } else { Write-Host "  cpolar 端口 4040 已释放" -ForegroundColor Green }
$dsh = netstat -ano | Select-String ':57575 .*LISTENING'
if ($dsh) { Write-Host "  DSH（57575）仍在运行，不受影响" -ForegroundColor Green }

Write-Host ""
Write-Host "手机端现在连不上了。要重新开启，双击「启动手机遥控」。" -ForegroundColor Cyan
