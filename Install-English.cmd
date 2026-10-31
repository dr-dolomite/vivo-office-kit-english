@echo off
rem One-click: add English to the Chinese vivo Office Kit (asks for admin).
where pwsh >nul 2>nul && (set "PS=pwsh") || (set "PS=powershell")
%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0Add-VivoEnglish.ps1" %*
pause
