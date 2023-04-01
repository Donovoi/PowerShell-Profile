function Import-RequiredModule {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$ModuleName
  )

  if ($PSVersionTable.psversion -lt '6.2') {
    Set-PSRepository -Name psgallery -InstallationPolicy Trusted
    Install-PackageProvider -Name NuGet -Force -ErrorAction SilentlyContinue | Out-Null
    if (-not (Get-Module -ListAvailable -Name PowerShellGet)) {
      Install-Module PowerShellGet -Force
      Update-Module PowerShellGet -Force
    }
  }

  foreach ($Module in $ModuleName) {
    try {

      if (-not (Get-Module -ListAvailable -Name $Module)) {
        Write-Output -Message "Installing $Module module"
        Install-Module -Name $Module -AllowClobber -SkipPublisherCheck -Force -AllowPrerelease
      }
      else {
        if (($Module -like '*psreadline*') -and ((Get-Module $Module).Version -lt '2.2.6')) {
          #Get-Module -ListAvailable $Module | Uninstall-Module -Force 
          Install-Module -Name $Module -AllowClobber -SkipPublisherCheck -Force -AllowPrerelease
        }
      }
      Import-Module -Name $Module -Force
    }
    catch {
      Write-Output "Can't install $Module. See Error Below:"
      Write-Output "$_"
    }

  }

}

