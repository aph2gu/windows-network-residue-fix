@echo off
rem ============================================================
rem  Deprecated launcher.
rem
rem  The old version hardcoded one machine's driver list
rem  (nfwfp / SangforTcpDrv / xlaccwfp / netfilter2 / zttap300 ...).
rem  That logic now lives in cleanup-network-residue.ps1, which scans
rem  the registry instead of hardcoding names and asks per driver.
rem
rem  Kept only so the old habit still works:
rem      close the accelerator / VPN client, then run this file.
rem  It simply hands over to the PowerShell script (which asks for UAC
rem  itself).
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup-network-residue.ps1"
