<#
.SYNOPSIS
    Download the extra resources needed for xways forensics at the moment this is just Excire, Conditional Colouring, and All Templates
.PARAMETER XWaysRoot
    This should be set as your X-Ways Root Folder
.PARAMETER XWScriptsAndTemplatesFolder
    This is an optional parameter to set the scripts and templates folder. If left empty is will be "$XWaysRoot\..\XWScriptsAndTemplates"
.PARAMETER ResetCredentials
    This is a switch parameter, use this if you need to change the X-Ways credentials
.PARAMETER GetTemplates
    Use this if you would like to get all Templates that I could find on the internet.
.EXAMPLE
    Get-XwaysResources -XWaysRoot "C:\XwaysResources"
.EXAMPLE
    Get-XwaysResources -GetTemplates -XWaysRoot F:\xwfportable -ResetCredentials
.NOTES
Now depends on Invoke-AriaDownload and Get-FileDownload
#>
function Get-XwaysResources {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $XWaysRoot,
    [Parameter()]
    [string]
    $XWScriptsAndTemplatesFolder = $(Resolve-Path -Path "$XWaysRoot\..\XWScriptsAndTemplates"),
    [Parameter()]
    [switch]
    $ResetCredentials,
    [Parameter()]
    [switch]
    $GetTemplates

  )
  try {
    # For faster downloads
    $ProgressPreference = 'SilentlyContinue'

    # Import the required cmdlets
    $neededcmdlets = @('Install-Dependencies', 'Get-FileDownload', 'Invoke-AriaDownload', 'Get-LongName', 'Write-Logg', 'Get-Properties')
    $neededcmdlets | ForEach-Object {
      if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
          $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
          $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
          New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
        }
        Write-Verbose -Message "Importing cmdlet: $_"
        $Cmdletstoinvoke = Install-Cmdlet -RepositoryCmdlets $_
        $Cmdletstoinvoke | Import-Module -Force
      }
    }

    # if $resetCredentials is set to true then we will delete the credential files
    if ($ResetCredentials) {
      Remove-Item -Path "$ENV:USERPROFILE\Documents\XWAYSRESOURCESCREDENTIALFILES" -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Check if we have $XWAYSUSB set as a variable if $XWaysRoot is set to $XWAYSUSB\xwfportable
    if (-not (Resolve-Path -Path $XWaysRoot) -or (-not ({ [System.IO.Path]::IsPathRooted($XWaysRoot) }))) {
      Write-Warning "$XWAYSUSB `$XWaysRoot is empty or not an absolute path."
      $XWaysRoot = Out-Host -InputObject 'Please enter the Folder that is the root of your chosen X-Ways Installation'
      Out-Host -InputObject "Your Chosen Folder is $($XWaysRoot)"
    }

    #region Credentials
    #TODO Export the credential stuff to a function
    # THE Following CREDENTIAL STUFF IS MOSTLY WORK FROM https://gist.github.com/davefunkel THANK YOU DAVE and from
    # https://purple.telstra.com.au/blog/using-saved-credentials-securely-in-powershell-scripts Thank you purple Telstra
    if (-not (Test-Path "$ENV:USERPROFILE\Documents\XWAYSRESOURCESCREDENTIALFILES")) {
      # Root Folder
      $rootFolder = "$ENV:USERPROFILE\Documents\XWAYSRESOURCESCREDENTIALFILES"

      # Secure Credential File
      $credentialFileDir = $rootFolder
      $credentialFilePath = "$credentialFileDir\$scriptName-SecureStore.txt"

      # Path to store AES File (if using AES mode for PrepareCredentials)
      $AESKeyFileDir = $rootFolder
      $AESKeyFilePath = "$AESKeyFileDir\$scriptName-AES.key"

      $title = 'Prepare Credentials Encryption Method'
      $message = 'Which mode do you wish to use?'

      $DPAPI = New-Object System.Management.Automation.Host.ChoiceDescription '&DPAPI', `
        'Use Windows Data Protection API.  This uses your current user context and machine to create the encryption key.'

      $AES = New-Object System.Management.Automation.Host.ChoiceDescription '&AES', `
        'Use a randomly generated SecureKey for AES.  This will generate an AES.key file that you need to protect as it contains the encryption key.'

      $options = [System.Management.Automation.Host.ChoiceDescription[]]($DPAPI, $AES)

      $choice = $host.ui.PromptForChoice($title, $message, $options, 0)

      switch ($choice) {
        0 {
          $encryptMode = 'DPAPI'
        }
        1 {
          $encryptMode = 'AES'
        }
      }
      Out-Host -InputObject "Encryption mode $encryptMode was selected to prepare the credentials."

      Out-Host -InputObject 'Collecting XWAYS Credentials to create a secure credential file...'
      # Collect the credentials to be used.
      Out-Host -InputObject 'Please enter your X-Ways Credentials'
      $creds = Get-Credential

      # Store the details in a hashed format
      $userName = $creds.UserName
      $passwordSecureString = $creds.Password

      if ($encryptMode -eq 'DPAPI') {
        $password = $passwordSecureString | ConvertFrom-SecureString
      }
      elseif ($encryptMode -eq 'AES') {
        # Generate a random AES Encryption Key.
        $AESKey = New-Object Byte[] 32
        [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($AESKey)

        # Store the AESKey into a file. This file should be protected!  (e.g. ACL on the file to allow only select people to read)

        # Check if Credential File dir exists, if not, create it
        if (!(Test-Path $AESKeyFileDir)) {
          New-Item -Type Directory $AESKeyFileDir | Out-Null
        }
        Set-Content $AESKeyFilePath $AESKey # Any existing AES Key file will be overwritten
        $password = $passwordSecureString | ConvertFrom-SecureString -Key $AESKey
      }
      else {
        # Placeholder in case there are other EncryptModes
      }


      # Check if Credential File dir exists, if not, create it
      if (!(Test-Path $credentialFileDir)) {
        New-Item -Type Directory $credentialFileDir | Out-Null
      }

      # Contents in this file can only be read and decrypted if you have the encryption key
      # If using DPAPI mode, then this can only be ready by the user that ran this script on the same machine
      # If using AES mode, then the AES.key file contains the encryption key

      Set-Content $credentialFilePath $userName # Any existing credential file will be overwritten
      Add-Content $credentialFilePath $password

      if ($encryptMode -eq 'AES') {
        Write-Logg -Message 'IMPORTANT! Make sure you restrict read access, via ACLs, to the AES.Key file that has been generated to ensure stored credentials are secure.'
      }
      Write-Logg -Message 'Credentials collected and stored.'
    }
    else {
      # Root Folder
      $rootFolder = "$ENV:USERPROFILE\Documents\XWAYSRESOURCESCREDENTIALFILES"

      # Secure Credential File
      $credentialFileDir = $rootFolder
      $credentialFilePath = "$credentialFileDir\-SecureStore.txt"

      # Path to store AES File (if using AES mode for PrepareCredentials)
      $AESKeyFileDir = $rootFolder
      $AESKeyFilePath = "$AESKeyFileDir\-AES.key"
    }

    # Check to see if we have an AES Key file.  If so, then we will use it to decrypt the secure credential file
    if (Test-Path $AESKeyFilePath) {
      try {
        Out-Host -InputObject 'Found an AES Key File.  Using this to decrypt the secure credential file.'
        $decryptMode = 'AES'
        $AESKey = Get-Content $AESKeyFilePath
      }
      catch {
        $errText = $error[0]
        Write-Logg "AES Key file detected, but could not be read.  Error Message was: $errText" -Type ERROR
        exit -1
      }
    }
    else {
      Out-Host -InputObject 'No AES Key File found.  Using DPAPI method, which requires same user and machine to decrypt the secure credential file.'
      $decryptMode = 'DPAPI'
    }

    try {
      Out-Host -InputObject "Reading secure credential file at $credentialFilePath."
      $credFiles = Get-Content $credentialFilePath
      $userName = $credFiles[0]
      if ($decryptMode -eq 'DPAPI') {
        $password = $credFiles[1] | ConvertTo-SecureString
      }
      elseif ($decryptMode -eq 'AES') {
        $password = $credFiles[1] | ConvertTo-SecureString -Key $AESKey
      }
      else {
        # Placeholder in case there are other decrypt modes
      }

      Out-Host -InputObject 'Creating credential object...'
      $credObject = New-Object System.Management.Automation.PSCredential -ArgumentList $userName, $password
      $passwordClearText = $credObject.GetNetworkCredential().Password
      Out-Host -InputObject "Credential store read.  UserName is $userName and Password is $passwordClearText"

    }
    catch {
      $errText = $error[0]
      Out-Host -InputObject "Failed to Prepare Credentials.  Error Message was: $errText" -Type ERROR
      Write-Logg -Message 'Failed to Prepare Credentials.  Please check Log File.'
      exit -1
    }
    #endregion Credentials

    #  Then we need to convert the username and password to base64 for basic http authentication
    $AuthenticationPair = "$($userName)`:$($PasswordClearText)"
    $Bytes = [System.Text.Encoding]::ASCII.GetBytes($AuthenticationPair)
    $Base64AuthString = [System.Convert]::ToBase64String($Bytes)

    $headers = @{
      'Authorization' = "Basic $Base64AuthString"
      'User-Agent'    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.5414.120 Safari/537.36'
      'Referer'       = 'https://x-ways.net/res/'
    }

    Out-Host -InputObject 'Downloading Excire.zip, Conditional Coloring.cfg, and aff4-xways-2.1.1.zip'
    $urls = 'https://www.x-ways.net/res/Excire%20for%20v21.1%20and%20later.zip', 'https://x-ways.net/res/conditional%20coloring/Conditional%20Coloring.cfg', 'https://www.x-ways.net/res/aff4-xways-2.1.1.zip'

    Get-FileDownload -URL $urls -DestinationDirectory "$XWaysRoot" -Headers $headers -UseAria2 -NoRPCMode

    function Invoke-NormalizePath {
      param (
        [string]$path
      )
      return [System.IO.Path]::Combine($path, [System.IO.Path]::GetFileName($path))
    }

    function Expand-Zip {
      param (
        [string]$rootPath,
        [string]$pluginName
      )

      $pluginFolder = Join-Path -Path $rootPath -ChildPath $pluginName
      if (-not (Test-Path $pluginFolder)) {
        New-Item -Path $pluginFolder -ItemType Directory -Force
      }
      Expand-Archive -Path "$rootPath\$pluginName*.zip" -DestinationPath $pluginFolder -Force
      Remove-Item -Path "$rootPath\$pluginName*.zip" -Force
    }

    # Normalize the root path
    $XWaysRoot = Invoke-NormalizePath -path $XWaysRoot

    Out-Host -InputObject "Extracting zips to $($XWaysRoot)"
    Expand-Zip -rootPath $XWaysRoot -pluginName 'Excire'
    Expand-Zip -rootPath $XWaysRoot -pluginName 'aff4'

    if ($GetTemplates) {

      # Create the Scripts and Templates folder if it doesn't exist
      if (-not (Test-Path "$XWScriptsAndTemplatesFolder")) {
        New-Item -Path "$XWScriptsAndTemplatesFolder" -ItemType Directory -Force
      }

      # Now we copy all TPL files from x-ways.net/winhex/templates two other sites to the XWScriptsAndTemplates folder on $XWAYSUSB
      $UrlsToDownloadTemplates = @('https://res.jens-training.com/templates/', 'https://github.com/kacos2000/WinHex_Templates/archive/refs/heads/master.zip', 'https://x-ways.net/winhex/templates/')

      $UrlsToDownloadTemplates.ForEach{
        $url = $_
        switch -WildCard ($url) {
          '*.zip' {
            $ProgressPreference = 'SilentlyContinue'
            Out-Host -InputObject "Downloading kacos2000's Templates as a zip"
            Invoke-WebRequest -Uri $url -OutFile "$XWScriptsAndTemplatesFolder\$($($_).Split('/')[-1])"
            break
          }
          default {
            Out-Host -InputObject 'Parsing Templates from Jens and then from X-Ways'
            $XWAYSTemplateNames = (Invoke-WebRequest -Uri $url).Links.Where({ ($_.href -like '*.tpl') -or ($_.href -like '*.zip') })

            # provide a count of how many templates were found
            Out-Host -InputObject "There are $($($XWAYSTemplateNames.href).Count) templates available from $url"

            # then download each template and save it to the XWScriptsAndTemplates folder
            Out-Host -InputObject "Downloading templates to $XWScriptsAndTemplatesFolder"

            $XWAYSTemplateNames.href.ForEach{
              # remove any url encoding
              $newname = [System.Web.HttpUtility]::UrlDecode($_)
              # download tpl file from multiple sites. But make sure we download from x-ways as the last download.
              Invoke-WebRequest -Uri $( -join "$url" + "$_") -OutFile "$XWScriptsAndTemplatesFolder\$newname"
            }
          }
        }

      }

      # Finally we will expand and remove any remaing zip files
      $zipfiles = Get-ChildItem -Path "$XWScriptsAndTemplatesFolder" -Filter '*.zip'
      $zipfiles.ForEach{
        Expand-Archive -Path $_ -DestinationPath "$XWScriptsAndTemplatesFolder" -Force
        Remove-Item -Path $_ -Force
      }
    }
    #TODO Download all X-Tensions from X-Ways website and copy them to the $XWScriptsAndTemplatesFolder

  }
  catch {
    $errText = $_.Exception.Message
    Write-Error "$errText"
    Write-Warning "If you are getting 'Unauthorized' try using the -ResetCredentials switch and rerun the script`n Exiting"
    Exit-PSHostProcess
  }
  Finally {
    # Remove any aria2c files and folders
    $ariafiles = Get-ChildItem -Path "$XWaysRoot" -Filter '*aria2*'
    if (Test-Path $ariafiles -ErrorAction SilentlyContinue) {
      Remove-Item -Path $ariafiles -Force -Recurse -ErrorAction SilentlyContinue
    }
    Out-Host -InputObject 'All Done!'
  }

}