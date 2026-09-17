@echo off
rem ============================================================
rem  Launch Claude Desktop via vpn-guard (consistent session)
rem  proxy + timezone + language aligned to the VPN exit country
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\app-vpn.ps1" claude-desktop -SystemTz
if errorlevel 1 pause
