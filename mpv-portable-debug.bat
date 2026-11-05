@echo off
setlocal
cd /d "%~dp0"
set "PATH=%~dp0;%~dp0python;%PATH%"
"%~dp0mpv.com" %*
