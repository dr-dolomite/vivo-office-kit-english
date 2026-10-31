@echo off
rem Opens the vivo English Kit window (Windows 11 style needs PowerShell 7.5 or later;
rem Windows PowerShell 5.1 shows the classic look).
setlocal
where pwsh >nul 2>nul && (set "PS=pwsh") || (set "PS=powershell")
set "ARGS=-NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0gui\VivoEnglishKit.ps1" %*"
set "BUILD=0"
for /f "tokens=3" %%b in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul') do set "BUILD=%%b"
rem Windows 11 may hand consoles to Windows Terminal, which ignores -WindowStyle Hidden;
rem a headless conhost keeps the window away entirely.
if %BUILD% GEQ 22000 if exist "%SystemRoot%\System32\conhost.exe" (
    start "" conhost.exe --headless %PS% %ARGS%
    exit /b
)
start "" /min %PS% -WindowStyle Hidden %ARGS%
