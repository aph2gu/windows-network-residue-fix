---
name: windows-network-residue-fix
description: "Use when Windows loses network or specific sites fail after VPN/accelerator/proxy uninstall; suspect residual kernel drivers, Winsock LSP, or hosts blocking. Windows 断网/个别站点打不开，怀疑 VPN/加速器/代理卸载后残留内核驱动、LSP 或 hosts 屏蔽。四层排查 + 诊断与交互式清理脚本。"
version: 2.0.0
author: Hermes Agent
license: MIT
tags: [windows, network, vpn, proxy, troubleshooting]
metadata:
  hermes:
    tags: [windows, network, vpn, proxy, troubleshooting]
    related_skills: [windows-system-housekeeping, windows-disk-space-analysis]
---

# Windows 网络残留污染排查（VPN / 游戏加速器 / 代理）

## When to Use

- 不使用 VPN/加速器时也断网，开关一次该软件就恢复
- 特定域名或整站无法访问，其他站点正常
- 睡眠/唤醒后网络中断
- 卸载某 VPN/加速器后出现网络异常
- 怀疑第三方网络软件留下了内核驱动、Winsock LSP 或 hosts 屏蔽

这类问题几乎总是**软件卸载或异常退出后留在系统里的拦截层**，不是硬件或运营商问题。排查四层：**内核网络驱动 → Winsock LSP → hosts → 网卡电源管理**。全部可在 WSL 里通过 `powershell.exe` 完成。

## 症状 → 病因

| 症状 | 病因 |
|---|---|
| 不定期断网，开一次任意网络工具再关就恢复 | 第三方 WFP callout / NDIS 过滤驱动常驻内核，内部激活状态与客户端不一致 |
| 特定域名或整站打不开，其他正常 | hosts 被写入 `127.0.0.1` 屏蔽 |
| 睡眠/唤醒后断网 | 网卡电源管理 → NDIS 电源转换失败（常见于 Wi-Fi Direct 虚拟适配器） |
| 所有程序都不能解析域名 | Winsock LSP 劫持 / DNS 残留 |

**核心判据：「开一次软件就恢复」= 残留发生在内核态。** 用户态残留（系统代理、缓存）不会因为重启软件而修复，所以能靠开关软件治好的，一定是驱动/LSP 层。

## 一、诊断

一键：`scripts/diag-windows-network.ps1`（加 `-Signers` 额外列出每个第三方驱动的 Authenticode 签名者，便于归属识别，较慢）。手动逐项：

```powershell
# 1) 网卡 / DNS / 默认路由
Get-NetAdapter | Format-Table ifIndex,Name,InterfaceDescription,Status,MacAddress -AutoSize
Get-DnsClientServerAddress -AddressFamily IPv4 | ? {$_.ServerAddresses} | ft InterfaceIndex,InterfaceAlias,ServerAddresses
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | ft ifIndex,InterfaceAlias,NextHop,RouteMetric,Protocol

# 2) 第三方内核驱动（ImagePath 不在系统目录的）—— 主战场
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' | ForEach-Object {
  $k = Get-ItemProperty $_.PSPath
  if($k.ImagePath -and $k.ImagePath -notmatch 'System32|SysWOW64|SystemRoot' -and $k.Type -in 1,2){
    "{0,-30} Start={1} {2}" -f $_.PSChildName,$k.Start,$k.ImagePath } }
# Start: 0=Boot 1=System 2=Auto 3=Demand 4=Disabled

# 3) Winsock LSP 劫持
netsh winsock show catalog      # 看 Layered Service Provider / Chain Entry，Provider Path != mswsock.dll

# 4) hosts —— 必须读注释行，生成者签名在注释里
Get-Content "$env:SystemRoot\System32\drivers\etc\hosts"

# 5) NDIS / WLAN 电源错误
Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddDays(-3)} |
  ? { $_.ProviderName -match 'NDIS|Tcpip|Dhcp|WLAN|Netwtw' } |
  Select-Object -First 30 TimeCreated,ProviderName,Message

# 6) 加速器/VPN 安装项 + 常驻进程
$u='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $u | ? { $_.DisplayName -match 'VPN|Clash|Mihomo|V2ray|sing|Xray|加速|Netfilter|Sangfor|EasyConnect|WireGuard|OpenVPN' } |
  ft DisplayName,DisplayVersion,Publisher,UninstallString
Get-Process | ? { $_.ProcessName -match 'vpn|clash|verge|mihomo|v2ray|sing|xray|sangfor|leigod|thunder|booster|acc' }

# 7) 驱动归属识别（动手前必做，别删错）
(Get-AuthenticodeSignature C:\Windows\System32\drivers\XXX.sys).SignerCertificate.Subject
# WSL 侧：strings XXX.sys | grep -iaE 'https?://|\.com|\.cn'   → 内嵌域名常直接暴露厂商
# 软件自有数据目录：%APPDATA%\<name>\IndexedDB\https_<domain>_0.indexeddb.leveldb ← 最直接的归属证据
```

## 二、修复

**先与用户确认哪些软件还在用**，再分两类处理（用户偏好：改启动类型/禁用服务可直接动手，删文件/卸载软件要先列清单征得同意）。

交互式一键清理：`scripts/cleanup-network-residue.ps1` —— 自动提权 → 扫描候选内核驱动（附 Authenticode 签名者供归属识别）→ 逐个询问 `K`(改按需，仍在用) / `D`(禁用) / `R`(删除服务) / `S`(跳过)，日志写在 `%TEMP%\cleanup-network-residue.log`。下面 A~E 是它内部的等价手工步骤。

```powershell
# A) 不再用的 → 禁用 + 删服务（驱动文件被占用，重启后才解锁，可之后再删文件）
cmd /c "sc config <name> start= disabled"
cmd /c "sc stop <name>"
cmd /c "sc delete <name>"

# B) 还在用的 → 改按需（客户端启动时会自己加载驱动，功能保留）
cmd /c "sc config <name> start= demand"

# C) 清 Winsock LSP 劫持
netsh winsock reset                     # 必须重启才生效

# D) 网卡电源管理（治 NDIS 电源转换失败）
powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
powercfg /setactive SCHEME_CURRENT
# 关「允许计算机关闭此设备以节约电源」——Win11 的 Set-NetAdapterPowerManagement 没有这个参数，走注册表：
$cls='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$tg = Get-NetAdapter | ? { $_.Name -match 'WLAN|Ethernet|以太网' }
Get-ChildItem $cls | ForEach-Object { $k=Get-ItemProperty $_.PSPath
  if($k.NetCfgInstanceId){ foreach($a in $tg){ if($k.NetCfgInstanceId -eq $a.InterfaceGuid){
    Set-ItemProperty $_.PSPath -Name 'PnPCapabilities' -Value 24 -Type DWord } } } }   # 24=0x18
# 禁用反复报 NDIS 电源转换错误的虚拟适配器
Get-PnpDevice | ? { $_.FriendlyName -match 'Wi-Fi Direct' } | Disable-PnpDevice -Confirm:$false

# E) hosts：保留原始注释头，删掉所有 127.0.0.1 映射，然后刷新
ipconfig /flushdns
```

**有自保护的常驻服务**（名称常含 `Protect`、`Guard` 等）：`sc config` 可能返回 SUCCESS 但值立刻被改回。**先 `sc stop` 再 config** 即可成功。

## 三、坑（通用经验）

1. **`.ps1` 必须带 UTF-8 BOM。** PowerShell 5.1 按 ANSI 读无 BOM 文件，中文字节会破坏引号配对 → `TerminatorExpectedAtEndOfString` 之类的诡异语法错误。写完后加：
   ```bash
   printf '\xEF\xBB\xBF' > _b.tmp && cat x.ps1 >> _b.tmp && mv _b.tmp x.ps1
   ```
2. **从 WSL 提权执行**（会弹 UAC，需用户在场）：
   ```bash
   powershell.exe -NoProfile -Command "Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\path\x.ps1' -Verb RunAs -Wait"
   ```
   子进程 stdout **不回传** → 脚本内自己写日志文件，执行完再读。
3. **`sc config` 的参数语法在 PowerShell 里会炸**（`start=` 与值之间的空格语义）。一律包一层：`cmd /c "sc config X start= demand"`。
4. **改 `Start` 类型不会卸载已加载的内核驱动。** 改完 `Get-Service` 仍显示 `Running` —— 这是正常的，**必须重启**。务必明确告知用户，否则他会以为没生效。`netsh winsock reset` 同理。
5. **`Disable-PnpDevice` 对动态创建的虚拟适配器可能报「常规故障」** —— 无妨，重启后自然消失。
6. **别误伤这些常驻驱动**：火绒 `hrwfpdrv`/`hrndis6`/`sysdiag`、Hyper-V+WSL `VMSNPXY`/`VmsProxy`/`vmswitch`、ToDesk `ToDeskHubFlt`、Npcap 的 `INSECURE_NPCAP` LWF（Wireshark 用）、`ms_*` 全是微软的。
7. **hosts 的归属看注释行**，别只 grep 有效行 —— 生成者签名一般在开头注释里。
8. **软件已卸载但 hosts 残留是常态**：VPN 卸载器只删自身文件，hosts 里它写的屏蔽会永久留下，表现为「个别站点打不开」这种最容易被误判成网络故障的现象。
9. **有些加速器会把自己的驱动启动类型改回去，而且客户端退出后不卸载驱动。** 实测模式：① 客户端一启动就把 `Start` 重写回 `1`(System) 并加载——「改按需」对它无效；② 客户端**完全退出后驱动仍留在内核里**（进程没了，驱动还 Running）。这就是「不用它也在拦截流量」的确切成因。
   **好消息：多数 WFP/NDIS 过滤驱动支持动态停止——`sc stop <name>` 立刻从内核卸载，不需要重启**（比走 `netsh winsock reset` + 重启快得多）。完整收尾：
   ```
   cmd /c "sc stop <name>"                    # 立即卸载，之后等 2 秒
   cmd /c "sc config <name> start= demand"    # 下次开机不再自动加载
   ```
   这类软件一律按同一模式处理：**等客户端退出后再收尾**，而不是指望改启动类型。
10. **脚本里别用单字母函数名。** PowerShell 的命令解析顺序是**别名 > 函数 > cmdlet**：`function H` 永远轮不到被调用（`h` 是 `Get-History` 的别名），再叠加 `$ErrorActionPreference='SilentlyContinue'` 就完全无声——现象是脚本能跑完、但所有段落标题凭空消失。用 `Section`/`Banner` 这类名字。

## 四、验证

```powershell
# hosts 是否真的清掉（不该再出现 127.0.0.1）
Resolve-DnsName <之前被屏蔽的域名> -Type A
# 驱动 Start 值 + 当前状态
foreach($n in '<names>'){ "$n Start=$((Get-ItemProperty \"HKLM:\SYSTEM\CurrentControlSet\Services\$n\").Start) now=$((Get-Service $n).Status)" }
# LSP 里目标厂商条目数（重启后应为 0）
(netsh winsock show catalog) | Select-String '<vendor>'
# 连通性没被改坏（改完必测）
powershell.exe -c "Test-NetConnection 223.5.5.5 -InformationLevel Quiet"
```

## 五、常见第三方网络驱动类别（用于归属识别参考）

| 类别 | 常见驱动名模式 | 典型来源 |
|---|---|---|
| 游戏加速器 | `*wfp*`, `*acc*`, `*nf*` | 雷神、迅游、UU、奇游等 |
| 企业 VPN | `*TcpDrv*`, `*DnsDrv*`, `*SP*`, `*PWEx*` | 深信服 EasyConnect、Ivanti 等 |
| 代理工具 | `wintun`, `tap0901`, `*tun*` | WireGuard、OpenVPN、Clash 等 |
| 下载工具 | `*accwfp*`, `*xl*` | 迅雷等 |
| 通用过滤框架 | `netfilter2`, `*wfp*` | Netfilter SDK 等 |

## 六、通用处理原则

1. **归属识别优先**：动手前用 Authenticode 签名 + `strings` 提取内嵌域名确认驱动来源。
2. **还在用的软件 → 改按需 (Demand)**：客户端启动时会自己加载驱动，功能保留。
3. **不再用的软件 → 禁用 + 删除服务**：驱动文件被占用，重启后再删文件。
4. **等客户端退出后再收尾**：不要指望改启动类型，很多加速器客户端启动时会改回去。
5. **`sc config` 在 PowerShell 里要包 `cmd /c`** ：`cmd /c "sc config X start= demand"`。
6. **改启动类型不会卸载已加载的驱动**：必须 `sc stop` 或重启。
7. **清理脚本 `scripts/cleanup-network-residue.ps1` 是交互式的**，会先扫描候选，再逐个询问保留/禁用/删除，避免误伤。
