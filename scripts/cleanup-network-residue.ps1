# ============================================================
#  cleanup-network-residue.ps1
#  交互式清理第三方 VPN / 游戏加速器 / 代理留下的网络内核驱动。
#
#  设计要点：
#    - 不硬编码驱动名：扫描注册表里 ImagePath 指向系统目录之外的内核驱动
#      (ServiceType 1/2)，附 Authenticode 签名者供归属识别；
#    - 逐个询问 [K]改按需 / [D]禁用 / [R]删除服务 / [S]跳过，避免误伤；
#    - 自动 UAC 提权；幂等，可重复运行（对不存在的服务 sc 报错被忽略）；
#    - 全程追加写日志 %TEMP%\cleanup-network-residue.log —— 提权子进程的 stdout
#      不回传，从 WSL 调用时读该文件取结果。
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File cleanup-network-residue.ps1
#    WSL（会弹 UAC，需用户在场）：
#      powershell.exe -NoProfile -Command "Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\path\cleanup-network-residue.ps1' -Verb RunAs -Wait"
#
#  前置：先关掉还在使用的加速器 / VPN 客户端（脚本会检查常见进程并提醒）。
#  提示：`sc config` 只改启动类型，不会卸载已加载的内核驱动；多数 WFP/NDIS 过滤驱动
#        支持 `sc stop` 立即从内核卸载，不支持的需重启。
#  本文件必须保留 UTF-8 BOM（PS 5.1 按 ANSI 读无 BOM 文件，中文会破坏引号配对）。
# ============================================================
[CmdletBinding()]
param()

$ErrorActionPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.Encoding]::UTF8

# ---------- 可配置 ----------
# 白名单：绝不触碰的驱动/服务名（按需增删）
$Whitelist = @(
  'hrwfpdrv','hrndis6','sysdiag',    # 火绒
  'VMSNPXY','VmsProxy','vmswitch',   # Hyper-V / WSL
  'ToDeskHubFlt',                    # ToDesk
  'INSECURE_NPCAP',                  # Npcap（Wireshark 抓包）
  'wintun'                           # WireGuard / 通用隧道（视情况删掉本行）
)
# 提示用的常见加速器/VPN 客户端进程
$ProcessPatterns = 'vpn|clash|verge|mihomo|v2ray|sing|xray|sangfor|easyconn|leigod|thunder|xunlei|booster|accel|acceler|netch|warp|proxy'

$LogFile = Join-Path $env:TEMP 'cleanup-network-residue.log'

# ---------- 工具函数 ----------
function Log([string]$t){
  if($null -eq $t){ $t = '' }
  Write-Host $t
  Add-Content -LiteralPath $LogFile -Value $t -Encoding UTF8
}
function StartName($s){
  switch($s){ 0{'Boot'} 1{'System'} 2{'Auto'} 3{'Demand'} 4{'Disabled'} default{"($s)"} }
}
# ImagePath -> 真实文件路径
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
# sc 的参数在 PowerShell 里会被解析坏（start= 后的空格语义），一律包 cmd /c
function ScRun([string]$cmd){ (cmd /c $cmd 2>&1) -join ' | ' }
function StartValue($n){ (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$n").Start }
function StateOf($n){
  $s = Get-Service -Name $n -ErrorAction SilentlyContinue
  if($s){ $s.Status } else { 'N/A(已删除/不存在)' }
}
function Act([string]$n,[string]$action){
  switch($action){
    'demand'   { Log ("    " + (ScRun "sc stop $n"));   Log ("    " + (ScRun "sc config $n start= demand")) }
    'disabled' { Log ("    " + (ScRun "sc stop $n"));   Log ("    " + (ScRun "sc config $n start= disabled")) }
    'delete'   { Log ("    " + (ScRun "sc stop $n"));   Log ("    " + (ScRun "sc delete $n")) }
  }
}

# ---------- 0. 自动提权（UAC） ----------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $isAdmin){
  Write-Host '需要管理员权限 —— 正在请求 UAC 提权（提权后的窗口自己跑完，结果写日志）。'
  Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

Log ("=" * 62)
Log ("cleanup-network-residue   " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Log ("log : $LogFile")

# ---------- 1. 还在跑的相关进程 ----------
Log ""
Log "----- [0] 仍在运行的加速器 / VPN 进程 -----"
$procs = @(Get-Process | Where-Object { $_.ProcessName -match $ProcessPatterns })
if($procs.Count -gt 0){
  Log "  检测到以下进程仍在运行，建议先关闭对应客户端再继续（否则 sc stop 可能失败，或客户端立刻把驱动装回去）："
  $procs | Sort-Object ProcessName | % { Log ("    {0,-26} pid={1,-8} {2}" -f $_.ProcessName,$_.Id,$_.Path) }
} else {
  Log "  无"
}

# ---------- 2. 扫描候选驱动 ----------
Log ""
Log "----- [1] 候选驱动（ImagePath 在系统目录之外、且不在白名单内） -----"
$all = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' | ForEach-Object {
  $k = Get-ItemProperty $_.PSPath
  [PSCustomObject]@{ Name=$_.PSChildName; Type=$k.Type; Start=$k.Start; ImagePath=$k.ImagePath }
})
$cand = @($all | Where-Object {
  $_.ImagePath -and ($_.Type -in 1,2) -and
  ($_.ImagePath -notmatch 'System32|SysWOW64|SystemRoot') -and
  ($_.Name -notin $Whitelist)
} | Sort-Object Name)

if($cand.Count -eq 0){
  Log "  无候选（或全部落在白名单内）。"
} else {
  Log ("  共 {0} 个候选，逐个处理：" -f $cand.Count)
}

# ---------- 3. 逐个交互 ----------
$touched = @{}
foreach($c in $cand){
  $file = Resolve-DriverImage $c.ImagePath
  $now  = StartValue $c.Name
  Log ""
  Log ("--- {0} ---" -f $c.Name)
  Log ("    ImagePath : {0}" -f $c.ImagePath)
  Log ("    Start     : {0} ({1})    State: {2}" -f (StartName $now), $now, (StateOf $c.Name))
  Log ("    Signer    : {0}" -f (SignerOf $file))
  $ans = [string](Read-Host "    [K]改按需(还在用) / [D]禁用 / [R]删除服务 / [S]跳过")
  switch -Regex ($ans.Trim().ToUpper()){
    '^K' {
      Act $c.Name 'demand'
      $touched[$c.Name] = 'demand'
    }
    '^D' {
      Act $c.Name 'disabled'
      Start-Sleep -Seconds 2
      if((StartValue $c.Name) -ne 4){
        Log "    检测到自保护（Start 被改回），先 sc stop 再 config 重试 ..."
        Act $c.Name 'disabled'
        Start-Sleep -Seconds 2
      }
      $touched[$c.Name] = 'disabled'
    }
    '^R' {
      $ok = [string](Read-Host "    确认删除服务 $($c.Name)？驱动文件仍在 System32\drivers 下（重启后可手动删）。输入 YES 确认")
      if($ok.Trim().ToUpper() -eq 'YES'){ Act $c.Name 'delete'; $touched[$c.Name] = 'delete' }
      else { Log "    -> 未确认，跳过" }
    }
    default { Log "    -> 跳过" }
  }
}

# ---------- 4. 结果（回读注册表 / 服务管理器，不靠 sc 的返回文本） ----------
Log ""
Log "----- [2] 结果 -----"
if($touched.Count -eq 0){
  Log "  本次未改动任何驱动。"
} else {
  foreach($n in ($touched.Keys | Sort-Object)){
    $v = StartValue $n
    Log ("  {0,-30} 请求={1,-9} 当前 Start={2,-10} State={3}" -f $n, $touched[$n], ("{0}({1})" -f $v, (StartName $v)), (StateOf $n))
  }
  Log "  说明：改 Start 不会卸载已加载的驱动。多数 WFP/NDIS 过滤驱动 sc stop 后已从内核卸载；仍显示 Running 的需重启才彻底释放。"
}

# ---------- 5. 连通性 ----------
Log ""
Log "----- [3] 连通性 -----"
$ok = $false
try { $ok = [bool](Test-NetConnection 223.5.5.5 -InformationLevel Quiet -WarningAction SilentlyContinue) }
catch { try { $ok = [bool](Test-Connection 223.5.5.5 -Count 2 -Quiet) } catch { $ok = $false } }
if($ok){ Log "  Test-NetConnection 223.5.5.5 : OK" }
else   { Log "  Test-NetConnection 223.5.5.5 : FAILED -- 检查网络 / 是否还有别的拦截层" }

Log ""
Log "完成。日志: $LogFile"
Log "（脚本末尾不 pause：从 WSL 用 Start-Process -Wait 提权调用时，等待输入会挂住调用方。）"
