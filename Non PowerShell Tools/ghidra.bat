@echo off
setlocal
:: Find and strip the batch portion of the script, then pipe the rest to PowerShell which invokes pwsh to run the commands
@findstr /v "^@findstr.*&" "%~f0" | powershell -noprofile -noexit -Command "pwsh -noprofile -noexit -Command { $input | Invoke-Expression }" & goto:eof

:: The label is the name of your USB drive.
$XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
$ghidraBaseDir = Join-Path -Path $XWAYSUSB -ChildPath "chocolatey apps\chocolatey\bin\lib\ghidra\tools" -Resolve
$ghidraDir = Get-ChildItem -Path $ghidraBaseDir | Sort-Object -Property Name -Descending | Select-Object -First 1
$ghidraRunPath = Join-Path -Path $ghidraDir.FullName -ChildPath "ghidraRun.bat" -Resolve

if (Test-Path $ghidraRunPath) {
    Start-Process $ghidraRunPath
} else {
    Write-Host "ghidraRun.bat not found."
}
