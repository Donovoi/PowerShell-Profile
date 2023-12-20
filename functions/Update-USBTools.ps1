function Update-USBTools {
  [cmdletbinding()]
  param(
  )
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "chocolatey upgrade all --ignore-dependencies"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-VcRedist"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "winget install JanDeDobbeleer.OhMyPosh -s winget --force --accept-source-agreements --accept-package-agreements"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-VisualStudio"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-VSCode"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Get-KapeAndTools"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Get-GitPull"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-PowerShell"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Get-LatestSIV"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "winget source reset --disable-interactivity --force"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "winget source update --disable-interactivity"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "winget upgrade --all --include-unknown --wait -h --force --accept-source-agreements --accept-package-agreements"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "DISM /Online /Cleanup-Image /RestoreHealth; sfc /scannow"'
  Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-DotNetSDK"'
  # Start-Process -FilePath pwsh.exe -ArgumentList '-noexit -command "Update-RustAndFriends"'

}

