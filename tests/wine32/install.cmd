@echo off
msiexec /i D:\probe.msi /qn /norestart
if errorlevel 1 exit /b 1
echo msi-installed-ok>D:\installer-result.txt
