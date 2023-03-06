function Update-USBTools {
    $firstcommand = { $env:ChocolateyInstall = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\chocolatey apps\chocolatey\bin\"; `
            $xml = Get-ChildItem (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\chocolatey apps\chocolatey\bin\license\*.xml"; `
            Rename-Item $xml[0] choco.xml; `
            chocolatey upgrade chocolatey.extension; `
            Rename-Item (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\chocolatey apps\chocolatey\bin\license\choco.xml" chocolatey.license.xml; `
            chocolatey upgrade chocolatey.extension; `
            cup all };
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($firstcommand)
    $Encoded = [System.Convert]::ToBase64String($bytes)
    Start-Process pwsh -ArgumentList "-noexit -EncodedCommand $Encoded"
    # Start-Process -NoNewWindow (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\wsusoffline120\wsusoffline\cmd\DownloadUpdates.cmd" -ArgumentList 'o2k13 enu /includedotnet /includewddefs /verify'
    # Start-Process -NoNewWindow (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\wsusoffline120\wsusoffline\cmd\DownloadUpdates.cmd" -ArgumentList 'DownloadUpdates w62-x64 w63  w63-x64  w100  w100-x64  ofc  o2k16 /includedotnet /includewddefs /verify'
    Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-VcRedist -verbose"'
    Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-VSCodes -verbose"'
    Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Get-Zimmer -verbose"'
    Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "winget install Microsoft.DotNet.SDK.Preview"'
    Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Git-Pull -verbose"'
    Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-PowerShell -verbose"'
cargo install cargo-update
cargo install-update -a
}