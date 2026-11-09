@echo off
rem Installs our ARM64 qemu-ga build as the QEMU-GA service, with VSS.
rem Must run elevated (FirstLogonCommands are). Expects the package folder beside this script;
rem WindowsSetupMedia unpacks the versioned zip under this fixed name.
set SRC=%~dp0qemu-ga-windows-arm64
set DST=C:\Program Files\Qemu-ga
rem xcopy, not copy: copy reads the "+" in libc++.dll as "concatenate these files".
xcopy /e /i /y "%SRC%" "%DST%" >nul || exit /b 1
cd /d "%DST%"
rem -s install registers the VSS provider and the service, then sets it to auto-start.
qemu-ga.exe -s install || exit /b 2
sc start QEMU-GA
exit /b 0
