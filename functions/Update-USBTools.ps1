function Update-USBTools {
  $firstcommand = { 
    $Global:XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter; `
      $env:ChocolateyInstall = $( Resolve-Path -Path $(Join-Path -Path "$XWAYSUSB" -ChildPath '\chocolatey apps\chocolatey\bin\')); `
      # $xml = Get-ChildItem $(Resolve-Path $(Join-Path -Path $XWAYSUSB -ChildPath "\chocolatey apps\chocolatey\bin\license\choco.xml")); `
      # Rename-Item $xml[0] choco.xml; `
    # chocolatey upgrade chocolatey.extension; `
    # Rename-Item $(Resolve-Path $XWAYSUSB + "\chocolatey apps\chocolatey\bin\license\choco.xml" -ErrorAction SilentlyContinue) chocolatey.license.xml; `
    # chocolatey upgrade chocolatey.extension; `
    cup all }
  $bytes = [System.Text.Encoding]::Unicode.GetBytes($firstcommand)
  $Encoded = [System.Convert]::ToBase64String($bytes)
  Start-Process pwsh -ArgumentList "-noexit -EncodedCommand $Encoded"
  # Start-Process -NoNewWindow $XWAYSUSB + "\wsusoffline120\wsusoffline\cmd\DownloadUpdates.cmd" -ArgumentList 'o2k13 enu /includedotnet /includewddefs /verify'
  # Start-Process -NoNewWindow $XWAYSUSB + "\wsusoffline120\wsusoffline\cmd\DownloadUpdates.cmd" -ArgumentList 'DownloadUpdates w62-x64 w63  w63-x64  w100  w100-x64  ofc  o2k16 /includedotnet /includewddefs /verify'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-VcRedist -Verbose"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "winget install JanDeDobbeleer.OhMyPosh -s winget --force"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-VisualStudio -Verbose"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-VSCode -Verbose"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Get-KapeAndTools -Verbose"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Get-GitPull -Verbose"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-PowerShell -Verbose"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Get-LatestSIV -Verbose"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "winget source reset --force"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "winget source update"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "winget upgrade --all --include-unknown --wait -h --force"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "DISM /Online /Cleanup-Image /RestoreHealth; sfc /scannow"'
  #  So we can get feed back on each install as it happens
  $commands = @"
`$versions = @(3,5,6,7,"Preview")
foreach (`$version in `$versions) {
    Write-Host "Installing .NET SDK version `$version"
    winget install Microsoft.DotNet.SDK.`$version --force
    Write-Host "Finished installing .NET SDK version `$version"
}
"@

  # Convert the commands to a Base64 string
  $encodedCommands = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commands))

  # Start a new PowerShell window to run the commands
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit', "-EncodedCommand $encodedCommands"

  cargo install cargo-update
  cargo install-update -a
}

