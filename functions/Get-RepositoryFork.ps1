function Get-RepositoryFork {
    [cmdletbinding()]
    param(
        [string]$Token,
        [string[]]$ReposToFork,
        [Parameter()]
        [switch]
        $ResetTokenCreds
    )
    try {
        # For faster downloads
        $ProgressPreference = 'SilentlyContinue'
        # if $resetCredentials is set to true then we will delete the credential files
        if ($ResetTokenCreds) {
            Remove-Item -Path "$ENV:USERPROFILE\Documents\GITHIBTOKEN" -Recurse -Force -ErrorAction SilentlyContinue
        }
        #region Credentials
        #TODO Export the credential stuff to a function
        # THE Following CREDENTIAL STUFF IS MOSTLY WORK FROM https://gist.github.com/davefunkel THANK YOU DAVE and from
        # https://purple.telstra.com.au/blog/using-saved-credentials-securely-in-powershell-scripts Thank you purple Telstra        
        $scriptName = $MyInvocation.MyCommand.Name
        if (-not (Test-Path "$ENV:USERPROFILE\Documents\GITHIBTOKEN")) {
            # Root Folder
            $rootFolder = "$ENV:USERPROFILE\Documents\GITHIBTOKEN"
  
            # Secure Credential File
            
            $credentialFileDir = $rootFolder
            $credentialFilePath = "$credentialFileDir\$scriptName-SecureStore"
  
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
            Write-Log -NoLogFile -Message "Encryption mode $encryptMode was selected to prepare the credentials." -Level INFO
  
            Write-Log -NoLogFile -Message 'Collecting XWAYS Credentials to create a secure credential file...' -Level INFO
            # Collect the credentials to be used.
            Write-Log -NoLogFile -Message 'Please enter your GitHub Token.  This will be stored securely-ish' -Level INFO
            $creds = Get-Credential -UserName $ENV:USERNAME
  
            # Store the details in a hashed format
            $userName = $creds.UserName
            $GitHubTokenSecureString = $creds.Password
  
            if ($encryptMode -eq 'DPAPI') {
                $GitHubToken = $GitHubTokenSecureString | ConvertFrom-SecureString
            }
            elseif ($encryptMode -eq 'AES') {
                # Generate a random AES Encryption Key.
                $AESKey = New-Object Byte[] 32
                [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($AESKey)
  
                # Store the AESKey into a file. This file should be protected-not   (e.g. ACL on the file to allow only select people to read)
  
                # Check if Credential File dir exists, if not, create it
                if (-not (Test-Path $AESKeyFileDir)) {
                    New-Item -Type Directory $AESKeyFileDir | Out-Null
                }
                Set-Content $AESKeyFilePath $AESKey # Any existing AES Key file will be overwritten		
                $GitHubToken = $GitHubTokenSecureString | ConvertFrom-SecureString -Key $AESKey
            }
            else {
                # Placeholder in case there are other EncryptModes
            }
  
  
            # Check if Credential File dir exists, if not, create it
            if (-not (Test-Path $credentialFileDir)) {
                New-Item -Type Directory $credentialFileDir | Out-Null
            }
  
            # Contents in this file can only be read and decrypted if you have the encryption key
            # If using DPAPI mode, then this can only be ready by the user that ran this script on the same machine
            # If using AES mode, then the AES.key file contains the encryption key
  
            Set-Content $credentialFilePath $userName # Any existing credential file will be overwritten
            Add-Content $credentialFilePath $GitHubToken
  
            if ($encryptMode -eq 'AES') {
                Write-Log -NoLogFile -Message 'IMPORTANT: Make sure you restrict read access, via ACLs, to the AES.Key file that has been generated to ensure stored credentials are secure.' -Level WARNING
            }
  
            Write-Log -NoLogFile -Message 'Credentials collected and stored.' -Level INFO
            Write-Log -NoLogFile -Message 'Credentials collected and stored.' -Level INFO
        }
        else {
            # Root Folder
            $rootFolder = "$ENV:USERPROFILE\Documents\GITHIBTOKEN"
  
            # Secure Credential File
            $credentialFileDir = $rootFolder
            $credentialFilePath = "$credentialFileDir\$scriptname-SecureStore"
  
            # Path to store AES File (if using AES mode for PrepareCredentials)
            $AESKeyFileDir = $rootFolder
            $AESKeyFilePath = "$AESKeyFileDir\$scriptname-AES.key"
        }
  
        # Check to see if we have an AES Key file.  If so, then we will use it to decrypt the secure credential file
        if (Test-Path $AESKeyFilePath) {
            try {
                Write-Log -NoLogFile -Message 'Found an AES Key File.  Using this to decrypt the secure credential file.' -Level INFO
                $decryptMode = 'AES'
                $AESKey = Get-Content $AESKeyFilePath
            }
            catch {
                $errText = $error[0]
                Write-Log -NoLogFile -Message "AES Key file detected, but could not be read.  Error Message was: $errText" -level ERROR
                exit -1
            }
        }
        else {
            Write-Log -NoLogFile -Message 'No AES Key File found.  Using DPAPI method, which requires same user and machine to decrypt the secure credential file.' -Level INFO
            $decryptMode = 'DPAPI'
        }
  
        try {
            Write-Log -NoLogFile -Message "Reading secure credential file at $credentialFilePath." -Level INFO
            $credFiles = Get-Content $credentialFilePath
            $userName = $credFiles[0]
            if ($decryptMode -eq 'DPAPI') {
                $GitHubToken = $credFiles[1] | ConvertTo-SecureString
            }
            elseif ($decryptMode -eq 'AES') {
                $GitHubToken = $credFiles[1] | ConvertTo-SecureString -Key $AESKey
            }
            else {
                # Placeholder in case there are other decrypt modes
            }
  
            Write-Log -NoLogFile -Message 'Creating credential object...' -Level INFO
            $credObject = New-Object System.Management.Automation.PSCredential -ArgumentList $userName, $GitHubToken
            $GitHubTokenClearText = $credObject.GetNetworkCredential().Password
            Write-Log -NoLogFile -Message "Token is $GitHubTokenClearText" -Level INFO
  
        }
        catch {
            $errText = $error[0]
            Write-Log -NoLogFile -Message "Failed to Prepare Credentials.  Error Message was: $errText" -Level ERROR
            Write-Log -NoLogFile -Message 'Failed to Prepare Credentials.  Please check Log File.' -Level ERROR
            exit -1
        }
        #endregion Credentials
      
        $APIBaseURL = 'https://api.github.com/repos'

        foreach ($Repo in $ReposToFork) {
            $URL = "$APIBaseURL/$Repo/forks"
            $Headers = @{
                'Authorization' = "token $Token"
                'Accept'        = 'application/vnd.github.v3+json'
            }

            $Response = Invoke-RestMethod -Uri $URL -Headers $Headers -Method Post

            if ($Response) {
                Write-Host "Successfully forked $Repo"
            }
            else {
                Write-Host "Failed to fork $Repo"
            }
        }
    }
    catch {
        Write-Host "Error: $_"
    }
}
