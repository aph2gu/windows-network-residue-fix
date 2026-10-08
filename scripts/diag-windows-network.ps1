# ============================================================
#  diag-windows-network.ps1
#  Windows 网络残留污染诊断（只读脚本：不改动任何系统设置）
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File diag-windows-network.ps1
#    powershell ... -File diag-windows-network.ps1 -Signers      # 附驱动签名者（较慢）
#    WSL: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<此文件的 Windows 路径>"
#
#  本文件必须保留 UTF-8 BOM：PowerShell 5.1 按 ANSI 读取无 BOM 文件，
#  中文会破坏引号配对，报 TerminatorExpectedAtEndOfString 之类的假语法错误。
#  [Console]::OutputEncoding = UTF8 是为了从 WSL 调用时中文输出不乱码
#  （WSL 里的 Windows 控制台默认 gb2312）。
# ============================================================
[CmdletBinding()]
param(
  [switch]$Signers
)

$ErrorActionPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.Encoding]::UTF8

# ---------- 可配置匹配模式（按需增删，不要写死某个厂商名） ----------
# 进程名（RUNNING PROCESSES / 服务探测）
$VpnProcessPatterns   = 'vpn|clash|verge|mihomo|v2ray|sing|xray|sangfor|easyconn|leigod|thunder|xunlei|booster|accel|acceler|netch|warp|proxy'
# 卸载项 DisplayName（INSTALLED）
$VpnUninstallPatterns = 'VPN|Clash|Mihomo|V2ray|sing-box|Xray|Nekoray|WireGuard|OpenVPN|加速|Netfilter|Sangfor|EasyConnect|ToDesk|向日葵|代理'
# 服务/驱动服务名（SERVICES / AUTOSTART）
$VpnServicePatterns   = 'vpn|clash|mihomo|v2ray|sing-box|xray|sangfor|easyconn|netfilter|accel|wfp'

# 函数名不要用单字母（如 H）：PowerShell 的命令解析顺序是 别名 > 函数 > cmdlet，
# h 已是 Get-History 的别名，`H "xxx"` 会被静默吞掉（再叠加 $ErrorActionPreference='SilentlyContinue' 连报错都看不到）。
function Section($t){ Write-Output ""; Write-Output ("##### "+$t) }

function StartName($s){
  switch($s){ 0{'Boot'} 1{'System'} 2{'Auto'} 3{'Demand'} 4{'Disabled'} default{"($s)"} }
}

# ImagePath -> 真实文件路径（\??\C:\...、\SystemRoot\...、system32\...、裸文件名）
function Resolve-DriverImage($p){
  if(-not $p){ return '' }
  $x = $p -replace '^\\\?\?\\','' -replace '^\\SystemRoot\\', ($env:SystemRoot + '\')
  if($x -match '^[A-Za-z]:\\'){ return $x }
  if($x -match '^system32\\'){ return (Join-Path $env:SystemRoot $x) }
  if($x -match '^drivers\\'){ return (Join-Path ($env:SystemRoot + '\System32') $x) }
  return (Join-Path ($env:SystemRoot + '\System32\drivers') $x)
}

function SignerOf($f){
  if(-not $f -or -not (Test-Path -LiteralPath $f)){ return 'N/A' }
  $sig = Get-AuthenticodeSignature -LiteralPath $f
  if($sig -and $sig.SignerCertificate){ return $sig.SignerCertificate.Subject }
  return 'N/A (unsigned)'
}

Section "ADAPTERS"
Get-NetAdapter | Sort-Object ifIndex | % { "{0,-4} {1,-26} {2,-45} {3,-13} {4}" -f $_.ifIndex,$_.Name,$_.InterfaceDescription,$_.Status,$_.MacAddress }

Section "DNS PER ADAPTER"
Get-DnsClientServerAddress -AddressFamily IPv4 | Sort-Object InterfaceIndex | % { "if{0,-4} {1,-26} {2}" -f $_.InterfaceIndex,$_.InterfaceAlias,($_.ServerAddresses -join ', ') }

Section "DEFAULT ROUTES"
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | % { "if{0,-4} {1,-26} nexthop={2,-18} metric={3,-6} {4}" -f $_.ifIndex,$_.InterfaceAlias,$_.NextHop,$_.RouteMetric,$_.Protocol }

Section "THIRD-PARTY KERNEL DRIVERS (ImagePath outside system dirs)"
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' | ForEach-Object {
  $k = Get-ItemProperty $_.PSPath
  if($k.ImagePath -and $k.ImagePath -notmatch 'System32|SysWOW64|SystemRoot' -and $k.Type -in 1,2){
    $run = (Get-Service -Name $_.PSChildName -ErrorAction SilentlyContinue).Status
    "{0,-30} Start={1,-9} now={2,-9} {3}" -f $_.PSChildName,(StartName $k.Start),$run,$k.ImagePath
    if($Signers){ "     signer: " + (SignerOf (Resolve-DriverImage $k.ImagePath)) }
  }
}
# Start: 0=Boot 1=System 2=Auto 3=Demand 4=Disabled

Section "VPN / ACCELERATOR SERVICES"
Get-CimInstance Win32_Service | Where-Object { $_.Name -match $VpnServicePatterns } | % { "{0,-26} state={1,-9} start={2,-9} {3}" -f $_.Name,$_.State,$_.StartMode,$_.PathName }

Section "WINSOCK LSP (catalog)"
(netsh winsock show catalog) | Select-String -Pattern 'Description:|Provider Path:' | % { $_.Line.Trim() }

Section "HOSTS FILE (raw, incl. comments)"
Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" | % { " | $_" }
$b = @(Get-Content "$env:SystemRoot\System32\drivers\etc\hosts")
Write-Output ("   >> blocked-to-127.0.0.1 entries: " + ($b | Where-Object { $_ -match '^\s*127\.0\.0\.1\s+\S' }).Count)

Section "NDIS / TCPIP / WLAN EVENTS (last 3 days)"
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddDays(-3)} -ErrorAction SilentlyContinue |
  Where-Object { $_.ProviderName -match 'NDIS|Tcpip|Dhcp|WLAN|Netwtw|Kernel-PnP' } | Select-Object -First 30 |
  % { $m = ($_.Message -replace "`r|`n",' '); "{0} [{1}] {2}" -f $_.TimeCreated.ToString('MM-dd HH:mm:ss'),$_.ProviderName,$m.Substring(0,[Math]::Min(150,$m.Length)) }

Section "VPN / ACCELERATOR INSTALLED"
$u='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $u | Where-Object { $_.DisplayName -match $VpnUninstallPatterns } |
  % { "{0,-40} | {1,-14} | {2}" -f $_.DisplayName,$_.DisplayVersion,$_.UninstallString }

Section "RUNNING VPN/ACCELERATOR PROCESSES"
Get-Process | Where-Object { $_.ProcessName -match $VpnProcessPatterns } | % { "{0,-26} pid={1,-8} {2}" -f $_.ProcessName,$_.Id,$_.Path }

Section "AUTOSTART ENTRIES"
'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' | % {
  Get-ItemProperty $_ | % { $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | % { "{0,-28} {1}" -f $_.Name,$_.Value } } }
Get-Service | Where-Object { $_.Status -eq 'Running' -and $_.Name -match $VpnServicePatterns } | % { "SVC {0,-26} start={1}" -f $_.Name,$_.StartType }

Section "NDIS LIGHTWEIGHT FILTERS (non-Microsoft = 3rd party)"
Get-NetAdapterBinding -AllBindings | Where-Object { $_.ComponentID -notmatch '^(ms_|vms_)' } | % { "{0,-16} {1,-24} {2,-46} enabled={3}" -f $_.Name,$_.ComponentID,$_.DisplayName,$_.Enabled } | Sort-Object -Unique

Section "DONE"
