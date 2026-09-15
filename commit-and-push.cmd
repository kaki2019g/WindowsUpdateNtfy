@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "commit_and_push.ps1" %*
set "SCRIPT_EXIT=%ERRORLEVEL%"
if not "%SCRIPT_EXIT%"=="0" (
  echo.
  echo Commit and push failed. Review the error above.
)
echo.
pause
exit /b %SCRIPT_EXIT%
