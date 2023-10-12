@echo off && @findstr /v "^@echo.*&" "%~f0" | powershell -noprofile -noexit - & pause

# The label is the name of your USB drive.
$XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
$ghidraBaseDir = Join-Path -Path $XWAYSUSB -ChildPath "\chocolatey apps\chocolatey\bin\lib\ghidra\tools" -Resolve
$ghidraDir = Get-ChildItem -Path $ghidraBaseDir -Directory | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
$ghidraRunPath = Join-Path -Path $ghidraDir.FullName -ChildPath "ghidraRun.bat" -Resolve
cmd.exe /c "$ghidraRunPath"