@echo off
setlocal
cd /d "%~dp0"
set "PATH=%~dp0;%~dp0python;%PATH%"
start "" "%~dp0mpv.exe" %*
