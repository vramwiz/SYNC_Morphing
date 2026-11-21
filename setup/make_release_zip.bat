@echo off
setlocal

echo Creating SYNC_Morphing v1.0.0 release package...
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0make_release_zip.ps1" %*
set "packageExitCode=%errorlevel%"
if not "%packageExitCode%"=="0" echo ERROR: Release package creation failed. Check the message above. 1>&2
exit /b %packageExitCode%
