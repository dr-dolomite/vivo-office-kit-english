@echo off
rem Undo: put the original Chinese-only files back (asks for admin).
where pwsh >nul 2>nul && (set "PS=pwsh") || (set "PS=powershell")
%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0Add-VivoEnglish.ps1" -Restore %*
pause
