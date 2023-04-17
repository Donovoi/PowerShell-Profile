<#
.SYNOPSIS
    Download the extra resources needed for xways forensics at the moment this is just Excire and Conditional Coloring
.DESCRIPTION
    Download the extra resources needed for xways forensics at the moment this is just Excire and Conditional Coloring
.PARAMETER DestinationFolder
    The folder to download the resources to. I have set this to my preferred location of $XWAYSUSB\xwfportable (where $XWAYSUSB is the drive letter of my Xways USB and is a GLOBAL variable in my profile)
.EXAMPLE
    Get-XwaysResources -DestinationFolder "C:\XwaysResources"
#>
function Get-XwaysResources {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]
        $DestinationFolder = "$XWAYSUSB\xwfportable",
        # [Parameter()]
        # [string]
        # $XWScriptsAndTemplatesFolder = $(Resolve-PAth -Path "$XWAYSUSB\xwfportable\..\XWScriptsAndTemplates")
        [Parameter()]
        [switch]
        $ResetCredentials = $false
        
    )    
    try {
        # if $resetCredentials is set to true then we will delete the credential files
        if ($ResetCredentials) {
            Remove-Item -Path "$ENV:USERPROFILE\Documents\XWAYSRESOURCESCREDENTIALFILES" -Recurse -Force -ErrorAction SilentlyContinue
        }
    
        # Check if we have $XWAYSUSB set as a variable if $DestinationFolder is set to $XWAYSUSB\xwfportable
        if ($DestinationFolder -eq "$XWAYSUSB\xwfportable" -and [String]::IsNullOrWhiteSpace($XWAYSUSB) ) {
            Write-Warning "$XWAYSUSB `$XWAYUSB is empty or not set."
            Write-Warning "Setting Now.."
            $SCRIPT:XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter 
        }
        
        #region Credentials
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
        
            $title = "Prepare Credentials Encryption Method"
            $message = "Which mode do you wish to use?"
    
            $DPAPI = New-Object System.Management.Automation.Host.ChoiceDescription "&DPAPI", `
                "Use Windows Data Protection API.  This uses your current user context and machine to create the encryption key."
    
            $AES = New-Object System.Management.Automation.Host.ChoiceDescription "&AES", `
                "Use a randomly generated SecureKey for AES.  This will generate an AES.key file that you need to protect as it contains the encryption key."
    
            $options = [System.Management.Automation.Host.ChoiceDescription[]]($DPAPI, $AES)
    
            $choice = $host.ui.PromptForChoice($title, $message, $options, 0) 
    
            switch ($choice) {
                0 { $encryptMode = "DPAPI" }
                1 { $encryptMode = "AES" }
            }
            Out-Host -inputobject "Encryption mode $encryptMode was selected to prepare the credentials."
                
            Out-Host -InputObject "Collecting XWAYS Credentials to create a secure credential file..." 
            # Collect the credentials to be used.
            $creds = Get-Credential
            
            # Store the details in a hashed format
            $userName = $creds.UserName
            $passwordSecureString = $creds.Password
    
            if ($encryptMode -eq "DPAPI") {
                $password = $passwordSecureString | ConvertFrom-SecureString
            }
            elseif ($encryptMode -eq "AES") {
                # Generate a random AES Encryption Key.
                $AESKey = New-Object Byte[] 32
                [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($AESKey)
                
                # Store the AESKey into a file. This file should be protected!  (e.g. ACL on the file to allow only select people to read)
    
                # Check if Credential File dir exists, if not, create it
                if (!(Test-Path $AESKeyFileDir)) {
                    New-Item -type Directory $AESKeyFileDir | out-null
                }
                Set-Content $AESKeyFilePath $AESKey   # Any existing AES Key file will be overwritten		
                $password = $passwordSecureString | ConvertFrom-SecureString -Key $AESKey
            }
            else {
                # Placeholder in case there are other EncryptModes
            }
            
            
            # Check if Credential File dir exists, if not, create it
            if (!(Test-Path $credentialFileDir)) {
                New-Item -type Directory $credentialFileDir | out-null
            }
            
            # Contents in this file can only be read and decrypted if you have the encryption key
            # If using DPAPI mode, then this can only be ready by the user that ran this script on the same machine
            # If using AES mode, then the AES.key file contains the encryption key
            
            Set-Content $credentialFilePath $userName   # Any existing credential file will be overwritten
            Add-Content $credentialFilePath $password
    
            if ($encryptMode -eq "AES") {
                Write-Host -foreground Yellow "IMPORTANT! Make sure you restrict read access, via ACLs, to the AES.Key file that has been generated to ensure stored credentials are secure."
            }
    
            Out-Host -InputObject "Credentials collected and stored." 
            Write-Host -foreground Green "Credentials collected and stored."
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
        if ( Test-Path $AESKeyFilePath) {
            try {
                Out-Host -inputobject "Found an AES Key File.  Using this to decrypt the secure credential file."
                $decryptMode = "AES"
                $AESKey = Get-Content $AESKeyFilePath
            }
            catch {
                $errText = $error[0]
                Write-Log "AES Key file detected, but could not be read.  Error Message was: $errText" -type ERROR
                exit -1
            }
        }
        else {
            Out-Host -inputobject "No AES Key File found.  Using DPAPI method, which requires same user and machine to decrypt the secure credential file."
            $decryptMode = "DPAPI"
        }

        try {	
            Out-Host -inputobject "Reading secure credential file at $credentialFilePath."
            $credFiles = Get-Content $credentialFilePath
            $userName = $credFiles[0]
            if ($decryptMode -eq "DPAPI") {
                $password = $credFiles[1] | ConvertTo-SecureString 
            }
            elseif ($decryptMode -eq "AES") {
                $password = $credFiles[1] | ConvertTo-SecureString -Key $AESKey
            }
            else {
                # Placeholder in case there are other decrypt modes
            }
    
            Out-Host -inputobject "Creating credential object..."
            $credObject = New-Object System.Management.Automation.PSCredential -ArgumentList $userName, $password
            $passwordClearText = $credObject.GetNetworkCredential().Password
            Out-Host -inputobject "Credential store read.  UserName is $userName and Password is $passwordClearText"
            
        }
        catch {
            $errText = $error[0]
            Out-Host -InputObject "Failed to Prepare Credentials.  Error Message was: $errText" -type ERROR
            Write-Host -foreground red "Failed to Prepare Credentials.  Please check Log File."
            Exit -1
        }
        #endregion Credentials

        #  Then we need to convert the username and password to base64 for basic http authentication
        $AuthenticationPair = "$($userName)`:$($PasswordClearText)"
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($authenticationPair)
        $Base64AuthString = [System.Convert]::ToBase64String($bytes)


        # headers for xways website - can possibly remove some of these
        $method = [Microsoft.PowerShell.Commands.WebRequestMethod]::"GET"
        $URI = [System.Uri]::new("https://x-ways.net:443/res/Excire.zip")
        $maximumRedirection = [System.Int32] 0
        $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
        $headers.Add("Host", "x-ways.net")
        $headers.Add("Authorization", "Basic $Base64AuthString")
        $headers.Add("Sec-Ch-Ua", "`"Chromium`";v=`"111`", `"Not_A Brand`";v=`"99`"")
        $headers.Add("Sec-Ch-Ua-Mobile", "?0")
        $headers.Add("Sec-Ch-Ua-Platform", "`"Windows`"")
        $headers.Add("Upgrade-Insecure-Requests", "1")
        $userAgent = [System.String]::new("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.5414.120 Safari/537.36")
        $headers.Add("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9")
        $headers.Add("Sec-Fetch-Site", "same-origin")
        $headers.Add("Sec-Fetch-Mode", "navigate")
        $headers.Add("Sec-Fetch-User", "?1")
        $headers.Add("Sec-Fetch-Dest", "document")
        $headers.Add("Referer", "https://x-ways.net/res/")
        $headers.Add("Accept-Encoding", "gzip, deflate")
        $headers.Add("Accept-Language", "en-US,en;q=0.9")
        $response = (Invoke-WebRequest -Method $method -Uri $URI -MaximumRedirection $maximumRedirection -Headers $headers -UserAgent $userAgent -OutFile "$ENV:TEMP\Excire.zip")
        $response

        # Extract zip to destination folder in the Excire folder
        Out-Host -InputObject "Extracting Excire.zip to $DestinationFolder\Excire"
        Expand-Archive -Path "$ENV:TEMP\Excire.zip" -DestinationPath "$DestinationFolder\Excire" -Force

        # headers for xways website - can possibly remove some of these
        $method = [Microsoft.PowerShell.Commands.WebRequestMethod]::"GET"
        $URI = [System.Uri]::new("https://x-ways.net/res/conditional%20coloring/Conditional%20Coloring.cfg")
        $maximumRedirection = [System.Int32] 0
        $headers = [System.Collections.Generic.Dictionary[string, string]]::new()
        $headers.Add("Host", "x-ways.net")
        $headers.Add("Authorization", "Basic $Base64AuthString")
        $headers.Add("Sec-Ch-Ua", "`"Chromium`";v=`"109`", `"Not_A Brand`";v=`"99`"")
        $headers.Add("Sec-Ch-Ua-Mobile", "?0")
        $headers.Add("Sec-Ch-Ua-Platform", "`"Windows`"")
        $headers.Add("Upgrade-Insecure-Requests", "1")
        $userAgent = [System.String]::new("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.5414.120 Safari/537.36")
        $headers.Add("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9")
        $headers.Add("Sec-Fetch-Site", "same-origin")
        $headers.Add("Sec-Fetch-Mode", "navigate")
        $headers.Add("Sec-Fetch-User", "?1")
        $headers.Add("Sec-Fetch-Dest", "document")
        $headers.Add("Referer", "https://x-ways.net/res/")
        $headers.Add("Accept-Encoding", "gzip, deflate")
        $headers.Add("Accept-Language", "en-US,en;q=0.9")
        $response = (Invoke-WebRequest -Method $method -Uri $URI -MaximumRedirection $maximumRedirection -Headers $headers -UserAgent $userAgent -OutFile "$ENV:TEMP\Conditional Coloring.cfg")
        $response


        # Copy Conditional Coloring.cfg to destination folder
        Out-Host -InputObject "Copying Conditional Coloring.cfg to $DestinationFolder"
        Copy-Item -Path "$ENV:TEMP\Conditional Coloring.cfg" -Destination $DestinationFolder -Force

        # Now we copy all TPL files from x-ways.net/winhex/templates to the XWScriptsAndTemplates folder on $XWAYSUSB
        # First we need to load the page and find all links that end in .tpl
        # load the x-ways.net/winhex/templates page
        $XWAYSTemplateNames = (Invoke-WebRequest -Uri "https://x-ways.net/winhex/templates/").Links.Where({ ($_.href -like "*.tpl") -or ($_.href -like "*.zip") })

        # provide a count of how many templates were found
        Out-Host -InputObject "There are $($($XWAYSTemplateNames.href).Count) templates available"

        # then download each template and save it to the XWScriptsAndTemplates folder
        out-host -InputObject "Downloading templates to $XWScriptsAndTemplatesFolder"


        if (-not (Test-Path "$DestinationFolder\XWScriptsAndTemplates")) {
            New-Item -Path "$DestinationFolder\XWScriptsAndTemplates" -ItemType Directory -Force
        }
        $XWAYSTemplateNames.href.foreach{
            # remove any url encoding
            $newname = [System.Web.HttpUtility]::UrlDecode($_)
            # download tpl file
            Invoke-WebRequest -Uri $("https://x-ways.net/winhex/templates/$newname") -OutFile "$DestinationFolder\XWScriptsAndTemplates\$newname"
        }

        # Finally we will expand and remove any remaing zip files
        $zipfiles = Get-ChildItem -Path "$DestinationFolder\XWScriptsAndTemplates" -Include "*.zip"
        $zipfiles.foreach{ 
            Expand-Archive -Path $_ -DestinationPath "$DestinationFolder\XWScriptsAndTemplates" -Force 
            
        }
        Remove-Item -Path $zipfiles -Force
    }
    catch {
        $errText = $_.Exception.Message
        Write-Warning "Exiting"
        Exit-PSHostProcess -Verbose
    }

}