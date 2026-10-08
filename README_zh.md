# Windows 网络残留污染排查（VPN / 游戏加速器 / 代理）

诊断并清理 Windows 上由 VPN、游戏加速器、代理等网络工具卸载或异常退出后留下的网络拦截层。

如果你**不使用** VPN/加速器时也断网，或者只有个别域名/整站打不开、其他站点正常，问题通常不在运营商或路由器，而在系统里残留的**内核驱动、WFP callout、NDIS 过滤驱动、Winsock LSP 或 hosts 屏蔽**。

本项目提供一套四层排查流程，以及诊断脚本和交互式清理脚本。

## 亮点

- 四层排查：**内核网络驱动 → Winsock LSP → hosts → 网卡电源管理**
- 检测 `ImagePath` 不在系统目录中的第三方内核驱动
- 可选 Authenticode 签名者查询，便于识别驱动归属
- 检查 Winsock 目录、hosts 注释、NDIS/WLAN 电源事件、VPN/加速器安装残留
- 交互式清理：自动提权 → 扫描候选 → 逐个询问 `K` / `D` / `R` / `S`
- 仍在用的软件不会被误删：改为按需启动，保留功能
- 可在 Windows PowerShell 或 WSL 中通过 `powershell.exe` 运行

## 核心判据

**「开一次软件就恢复」= 残留大概率发生在内核态。**

用户态残留（系统代理、缓存）通常不会因为重启软件而修复。如果开关一次 VPN/加速器就恢复，优先怀疑驱动、WFP callout、NDIS 过滤驱动或 LSP 层。

## 症状 → 病因

| 症状 | 病因 |
|---|---|
| 不定期断网，开一次任意网络工具再关就恢复 | 第三方 WFP callout / NDIS 过滤驱动常驻内核，内部激活状态与客户端不一致 |
| 特定域名或整站打不开，其他正常 | hosts 被写入 `127.0.0.1` 屏蔽 |
| 睡眠/唤醒后断网 | 网卡电源管理 → NDIS 电源转换失败，常见于 Wi-Fi Direct 虚拟适配器 |
| 所有程序都不能解析域名 | Winsock LSP 劫持 / DNS 残留 |

## 快速开始

```powershell
git clone https://github.com/<your-org>/windows-network-residue-fix.git
cd windows-network-residue-fix

# 诊断
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diag-windows-network.ps1

# 诊断并列出驱动签名者（较慢，便于归属识别）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diag-windows-network.ps1 -Signers

# 交互式清理（会弹 UAC）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup-network-residue.ps1
```

清理日志：

```text
%TEMP%\cleanup-network-residue.log
```

### 从 WSL 提权执行

```bash
powershell.exe -NoProfile -Command "Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\path\cleanup-network-residue.ps1' -Verb RunAs -Wait"
```

这种方式下子进程 stdout 不会回传。脚本会自己写日志文件，执行完再读取日志即可。

## 四层排查

### 1. 内核网络驱动

这是主战场。重点看 `ImagePath` 不在系统目录中的服务。

```powershell
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' | ForEach-Object {
  $k = Get-ItemProperty $_.PSPath
  if ($k.ImagePath -and $k.ImagePath -notmatch 'System32|SysWOW64|SystemRoot' -and $k.Type -in 1,2) {
    "{0,-30} Start={1} {2}" -f $_.PSChildName,$k.Start,$k.ImagePath
  }
}
```

`Start` 值：

- `0` = Boot
- `1` = System
- `2` = Auto
- `3` = Demand
- `4` = Disabled

### 2. Winsock LSP

```powershell
netsh winsock show catalog
```

查看 `Layered Service Provider` / `Chain Entry`，如果 Provider Path 不是 `mswsock.dll`，就要警惕。

重置：

```powershell
netsh winsock reset
```

必须重启才生效。

### 3. hosts 文件

```powershell
Get-Content "$env:SystemRoot\System32\drivers\etc\hosts"
```

必须读注释行。生成者签名一般在开头注释里。删除 VPN/加速器/代理工具写入的 `127.0.0.1` 映射。

```powershell
ipconfig /flushdns
```

### 4. 网卡电源管理

治 NDIS 电源转换失败：

```powershell
powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
powercfg /setactive SCHEME_CURRENT
```

关闭「允许计算机关闭此设备以节约电源」。Win11 的 `Set-NetAdapterPowerManagement` 没有这个参数，走注册表：

```powershell
$cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
$tg = Get-NetAdapter | Where-Object { $_.Name -match 'WLAN|Ethernet|以太网' }
Get-ChildItem $cls | ForEach-Object {
  $k = Get-ItemProperty $_.PSPath
  if ($k.NetCfgInstanceId) {
    foreach ($a in $tg) {
      if ($k.NetCfgInstanceId -eq $a.InterfaceGuid) {
        Set-ItemProperty $_.PSPath -Name 'PnPCapabilities' -Value 24 -Type DWord
      }
    }
  }
}
```

`24` = `0x18`。

禁用反复报 NDIS 电源转换错误的虚拟适配器：

```powershell
Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Wi-Fi Direct' } | Disable-PnpDevice -Confirm:$false
```

## 手工清理命令

```powershell
# 不再用的软件：禁用 + 删除服务
cmd /c "sc config <name> start= disabled"
cmd /c "sc stop <name>"
cmd /c "sc delete <name>"

# 仍在用的软件：改为按需启动
cmd /c "sc config <name> start= demand"

# 清 Winsock LSP 劫持（必须重启）
netsh winsock reset
```

如果有自保护的常驻服务会立刻改回启动类型，先 `sc stop`，再 `sc config`。

## 安全须知与坑

- **先做归属识别。** 用 Authenticode 签名、对驱动文件跑 `strings`、或查看软件自有数据目录。
- **不要禁用自己还在用的驱动。** 仍在用的软件改为 `demand`。
- **`sc config` 在 PowerShell 里要包 `cmd /c`。** `start=` 与值之间的空格语义在 PowerShell 下容易出错。
- **改启动类型不会卸载已加载的内核驱动。** `Get-Service` 可能仍显示 `Running`。要 `sc stop` 或重启。
- **有些加速器会在客户端启动时把 `Start` 改回 `System`。** 等客户端退出后再收尾。
- **多数 WFP/NDIS 过滤驱动支持动态停止。** `sc stop <name>` 可以立刻从内核卸载，不一定需要重启。
- **别误伤这些常驻驱动。** 例如：火绒 `hrwfpdrv` / `hrndis6` / `sysdiag`、Hyper-V/WSL `VMSNPXY` / `VmsProxy` / `vmswitch`、ToDesk `ToDeskHubFlt`、Npcap `INSECURE_NPCAP`、以及 `ms_*` 微软驱动。
- **hosts 的归属看注释行。** 别只 grep 有效行。
- **软件已卸载但 hosts 残留是常态。** 这是「个别站点打不开」最容易被误判成网络故障的原因之一。
- **`.ps1` 必须带 UTF-8 BOM。** 否则 Windows PowerShell 5.1 按 ANSI 读取，中文字节会破坏引号配对。
- **脚本里别用单字母函数名。** PowerShell 别名优先于函数，例如 `h` 是 `Get-History` 的别名，会导致函数永远不被调用。

## 验证

```powershell
# hosts 是否真的清掉（不该再出现 127.0.0.1 映射）
Resolve-DnsName <domain> -Type A

# 驱动 Start 值 + 当前状态
foreach($n in '<names>'){
  "$n Start=$((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$n").Start) now=$((Get-Service $n).Status)"
}

# LSP 里目标厂商条目数（重启后应为 0）
(netsh winsock show catalog) | Select-String '<vendor>'

# 连通性没被改坏
Test-NetConnection 223.5.5.5 -InformationLevel Quiet
```

## 常见第三方网络驱动类别

| 类别 | 常见驱动名模式 | 典型来源 |
|---|---|---|
| 游戏加速器 | `*wfp*`, `*acc*`, `*nf*` | 雷神、迅游、UU、奇游等 |
| 企业 VPN | `*TcpDrv*`, `*DnsDrv*`, `*SP*`, `*PWEx*` | 深信服 EasyConnect、Ivanti 等 |
| 代理工具 | `wintun`, `tap0901`, `*tun*` | WireGuard、OpenVPN、Clash 等 |
| 下载工具 | `*accwfp*`, `*xl*` | 迅雷等 |
| 通用过滤框架 | `netfilter2`, `*wfp*` | Netfilter SDK 等 |

## 作为 Agent Skill 使用

本仓库同时也是一个 agent skill。`SKILL.md` 是面向 Agent 的技能定义。

## 仓库结构

```text
.
├── SKILL.md
├── README.md
├── README_zh.md
└── scripts
    ├── diag-windows-network.ps1
    └── cleanup-network-residue.ps1
```

## 许可证

MIT