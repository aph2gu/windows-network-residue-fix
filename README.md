# Windows Network Residue Fix

Diagnose and clean network interception left behind by VPNs, game accelerators, proxies, and other network tools on Windows.

If your network breaks when you are **not** using a VPN/accelerator, or only specific domains fail while everything else works, the problem is often not your ISP or router. It is usually a residual kernel driver, WFP callout, NDIS filter, Winsock LSP, or hosts entry left after uninstall or abnormal exit.

This project provides a four-layer troubleshooting workflow plus diagnostic and interactive cleanup scripts.

## Highlights

- Four-layer diagnosis: **kernel network drivers → Winsock LSP → hosts → NIC power management**
- Detects third-party kernel drivers whose `ImagePath` is outside system directories
- Optional Authenticode signer lookup to identify driver ownership
- Inspects Winsock catalog, hosts comments, NDIS/WLAN power events, and VPN/accelerator install artifacts
- Interactive cleanup: elevate, scan candidates, and ask `K` / `D` / `R` / `S` per driver
- Safe for software still in use: switch to demand start instead of deleting
- Runs from Windows PowerShell or from WSL via `powershell.exe`

## Core Rule

**If toggling the VPN/accelerator once restores connectivity, the residue is likely in kernel mode.**

User-mode residue such as system proxy settings or caches usually does not get fixed by restarting the client software. If restarting the software fixes it, suspect drivers, WFP callouts, NDIS filters, or LSP layers.

## Symptoms → Likely Cause

| Symptom | Likely cause |
|---|---|
| Intermittent disconnects; starting and stopping any network tool restores it | Third-party WFP callout / NDIS filter driver stays resident; internal activation state is out of sync with the client |
| Specific domains or entire sites fail, others work | hosts file contains `127.0.0.1` blocks |
| Network breaks after sleep/wake | NIC power management → NDIS power transition failure, often on Wi-Fi Direct virtual adapters |
| All programs fail DNS resolution | Winsock LSP hijack / DNS residue |

## Quick Start

```powershell
git clone https://github.com/<your-org>/windows-network-residue-fix.git
cd windows-network-residue-fix

# Diagnose
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diag-windows-network.ps1

# Diagnose with driver signers (slower, useful for ownership identification)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\diag-windows-network.ps1 -Signers

# Interactive cleanup (will request UAC)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup-network-residue.ps1
```

Cleanup log:

```text
%TEMP%\cleanup-network-residue.log
```

### Run from WSL with Elevation

```bash
powershell.exe -NoProfile -Command "Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','C:\path\cleanup-network-residue.ps1' -Verb RunAs -Wait"
```

Child process stdout is not returned through this path. The script writes its own log file; read that after execution.

## The Four Layers

### 1. Kernel Network Drivers

This is the main battlefield. Look for services whose `ImagePath` is not in system directories.

```powershell
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' | ForEach-Object {
  $k = Get-ItemProperty $_.PSPath
  if ($k.ImagePath -and $k.ImagePath -notmatch 'System32|SysWOW64|SystemRoot' -and $k.Type -in 1,2) {
    "{0,-30} Start={1} {2}" -f $_.PSChildName,$k.Start,$k.ImagePath
  }
}
```

`Start` values:

- `0` = Boot
- `1` = System
- `2` = Auto
- `3` = Demand
- `4` = Disabled

### 2. Winsock LSP

```powershell
netsh winsock show catalog
```

Look for `Layered Service Provider` / `Chain Entry` whose provider path is not `mswsock.dll`.

Reset:

```powershell
netsh winsock reset
```

A reboot is required.

### 3. hosts File

```powershell
Get-Content "$env:SystemRoot\System32\drivers\etc\hosts"
```

Read the comment lines. The generator's signature is often in the header comments. Remove `127.0.0.1` mappings written by VPN/accelerator/proxy tools.

```powershell
ipconfig /flushdns
```

### 4. NIC Power Management

Fix NDIS power transition failures:

```powershell
powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
powercfg /setactive SCHEME_CURRENT
```

Disable “Allow the computer to turn off this device to save power”. On Windows 11, `Set-NetAdapterPowerManagement` does not expose this parameter, so use the registry:

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

`24` = `0x18`.

Disable virtual adapters that repeatedly log NDIS power transition errors:

```powershell
Get-PnpDevice | Where-Object { $_.FriendlyName -match 'Wi-Fi Direct' } | Disable-PnpDevice -Confirm:$false
```

## Manual Cleanup Commands

```powershell
# Not using it anymore: disable + delete service
cmd /c "sc config <name> start= disabled"
cmd /c "sc stop <name>"
cmd /c "sc delete <name>"

# Still using it: set to demand start
cmd /c "sc config <name> start= demand"

# Winsock reset (reboot required)
netsh winsock reset
```

If a protected service immediately rewrites its start type, run `sc stop` first, then `sc config`.

## Safety and Pitfalls

- **Identify ownership first.** Use Authenticode signer, `strings` on the driver file, or the software's own app data directory.
- **Do not disable drivers you still need.** For software still in use, set `Start` to `demand`.
- **`sc config` in PowerShell needs `cmd /c`.** The `start=` syntax with spaces can break under PowerShell parsing.
- **Changing the start type does not unload an already loaded kernel driver.** `Get-Service` may still show `Running`. Use `sc stop` or reboot.
- **Some accelerators rewrite `Start` back to `System` when the client starts.** Clean up after the client exits.
- **Many WFP/NDIS filter drivers support dynamic stop.** `sc stop <name>` can unload them immediately without a reboot.
- **Do not disable known safe drivers.** Examples: 火绒 `hrwfpdrv` / `hrndis6` / `sysdiag`, Hyper-V/WSL `VMSNPXY` / `VmsProxy` / `vmswitch`, ToDesk `ToDeskHubFlt`, Npcap `INSECURE_NPCAP`, and `ms_*` Microsoft drivers.
- **Read hosts comments for ownership.** Do not only grep active lines.
- **A VPN can be uninstalled while its hosts blocks remain.** This is a common cause of “only some sites fail”.
- **`.ps1` files must be UTF-8 with BOM** if they contain non-ASCII characters and run under Windows PowerShell 5.1.
- **Avoid single-letter PowerShell function names.** Aliases take precedence over functions; for example, `h` is an alias for `Get-History`.

## Verification

```powershell
# hosts should no longer contain the blocked domain mapping
Resolve-DnsName <domain> -Type A

# Driver Start value and current status
foreach($n in '<names>'){
  "$n Start=$((Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$n").Start) now=$((Get-Service $n).Status)"
}

# LSP entries for the target vendor should be 0 after reboot
(netsh winsock show catalog) | Select-String '<vendor>'

# Connectivity should still work
Test-NetConnection 223.5.5.5 -InformationLevel Quiet
```

## Common Third-Party Network Driver Categories

| Category | Common driver name patterns | Typical sources |
|---|---|---|
| Game accelerators | `*wfp*`, `*acc*`, `*nf*` | 雷神, 迅游, UU, 奇游, etc. |
| Enterprise VPN | `*TcpDrv*`, `*DnsDrv*`, `*SP*`, `*PWEx*` | Sangfor EasyConnect, Ivanti, etc. |
| Proxy tools | `wintun`, `tap0901`, `*tun*` | WireGuard, OpenVPN, Clash, etc. |
| Download tools | `*accwfp*`, `*xl*` | Thunder, etc. |
| Generic filtering frameworks | `netfilter2`, `*wfp*` | Netfilter SDK, etc. |

## Using as an Agent Skill

This repository is also an agent skill. `SKILL.md` contains the agent-facing instructions.

## Repository Layout

```text
.
├── SKILL.md
├── README.md
├── README_zh.md
└── scripts
    ├── diag-windows-network.ps1
    └── cleanup-network-residue.ps1
```

## License

MIT