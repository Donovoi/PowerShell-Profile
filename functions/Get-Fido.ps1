function Get-Fido {
  [CmdletBinding()]
  param()

  try {
    # import the powershell module to load our functions
    # Get all profile paths
    $profilePaths = Get-ChildItem -Path "$env:USERPROFILE\Documents" -Filter '*profile.ps1' -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName

    # Define the profile types and their respective paths
    $profileTypes = @{
      'Current User, Current Host'           = $PROFILE
      'CCurrent User, Current Host'          = $PROFILE.CurrentUserCurrentHost
      'Current User, All Hosts'              = $PROFILE.CurrentUserAllHosts
      'All Users, Current Host'              = $PROFILE.AllUsersCurrentHost
      'All Users, All Hosts'                 = $PROFILE.AllUsersAllHosts
      'All Users, All Hosts - Windows'       = "$PSHOME\Profile.ps1"
      'All Users, All Hosts - Linux'         = '/opt/microsoft/powershell/7/profile.ps1'
      'All Users, All Hosts - macOS'         = '/usr/local/microsoft/powershell/7/profile.ps1'
      'All Users, Current Host - Windows'    = "$PSHOME\Microsoft.PowerShell_profile.ps1"
      'All Users, Current Host - Linux'      = '/opt/microsoft/powershell/7/Microsoft.PowerShell_profile.ps1'
      'All Users, Current Host - macOS'      = '/usr/local/microsoft/powershell/7/Microsoft.PowerShell_profile.ps1'
      'Current User, All Hosts - Windows'    = "$HOME\Documents\PowerShell\Profile.ps1"
      'Current User, All Hosts - Linux'      = '/.config/powershell/profile.ps1'
      'Current User, All Hosts - macOS'      = '/.config/powershell/profile.ps1'
      'Current User, Current Host - Windows' = "$HOME\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
      'Current User, Current Host - Linux'   = '/.config/powershell/Microsoft.PowerShell_profile.ps1'
      'Current User, Current Host - macOS'   = '/.config/powershell/Microsoft.PowerShell_profile.ps1'
      'All Users, Current Host - VS Code'    = "$PSHOME\Microsoft.VSCode_profile.ps1"
      'Current User, Current Host - VS Code' = "$HOME\Documents\PowerShell\Microsoft.VSCode_profile.ps1"
    }

    # Create an array to store the profile information
    $profileInfoArray = @()

    # Iterate over the profile types and check if the script exists at the specified path
    foreach ($profileType in $profileTypes.Keys) {
      $profilePath = $profileTypes[$profileType]
    
      # Check if the profile script exists
      if ($profilePaths -contains $profilePath) {
        $profileScript = Get-Item $profilePath
        
        # Get the profile script's LastWriteTime
        $lastWriteTime = $profileScript.LastWriteTime
        
        # Add the profile information to the array
        $profileInfoArray += [PSCustomObject]@{
          ProfileType   = $profileType
          ProfilePath   = $profilePath
          LastWriteTime = $lastWriteTime
        }
      }
    }

    # Sort the profile information array based on the LastWriteTime in descending order
    $sortedProfileInfoArray = $profileInfoArray | Sort-Object -Property LastWriteTime -Descending

    if ($sortedProfileInfoArray) {
      # Get the profile with either the most recent LastWriteTime or the most used profile
      $selectedProfile = $sortedProfileInfoArray | Select-Object -First 1
    
      # Load the selected profile script into memory
      Write-Log -Message "Profile found: $($selectedProfile.ProfileType) - $($selectedProfile.ProfilePath)"
      . $selectedProfile.ProfilePath
    }
    else {
      Write-Output 'Profile not found.'
    }

    # Use Invoke-WebRequest to download the script
    $ZippedScriptContent = Get-latestGithubRelease -OwnerRepository pbatard/Fido -AssetName 'Fido.ps1.lzma' -ExtractZip -UseAria2
    
    #  Extract the zip using .net static method
    #if (-not(Get-Command 'Expand-7Zip' -ErrorAction SilentlyContinue)) {
    Install-ExternalDependencies -RemoveAllModules
    #}
    $scriptContent = Expand-7Zip -InputObject $ZippedScriptContent -OutputPath $env:TEMP -PassThru | Select-Object -ExpandProperty 'FullName'

    # Convert the script content to bytes using the UTF-8 encoding
    $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($scriptContent)
    
    # Use the default encoding on your machine
    $scriptBytesDefaultEncoding = [System.Text.Encoding]::Convert([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Default, $scriptBytes)    
    # Execute the script
    $FidoPath = [System.Text.Encoding]::Default.GetString($scriptBytesDefaultEncoding) | Out-File -Encoding ascii -FilePath $env:TEMP\Fido.ps1 -Force
    Get-Item $FidoPath | Invoke-Expression
  }
  catch {
    Write-Error "Failed to download or execute the Fido script: $($_.Exception.Message)"
  }
}