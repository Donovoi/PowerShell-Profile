<#
.SYNOPSIS
   Sets a secret as a named secret in the secret store.

.DESCRIPTION
   The Set-StoredSecret function stores a provided secret as a named secret in the secret store. 
   If a secret with the same name already exists, it will be overwritten.

.PARAMETER Secret
   The secret to store in the secret store. Can be a plain text or a SecureString.

.PARAMETER SecretName
   The name to assign to the stored secret.

.EXAMPLE
   Set-StoredSecret -Secret 'your_plain_text_secret_here' -SecretName 'MySecret'

.EXAMPLE
   $SecureSecret = ConvertTo-SecureString -String 'your_plain_text_secret_here' -AsPlainText -Force
   Set-StoredSecret -Secret $SecureSecret -SecretName 'MySecret'

.NOTES
   Ensure to handle secret security appropriately. Avoid exposing secrets in plain text.
#>
function Set-StoredSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]
        $Secret,

        [Parameter(Mandatory = $true)]
        [string]
        $SecretName
    )

    # run my profile to import the functions
    $myDocuments = [Environment]::GetFolderPath('MyDocuments')
    $myProfile = Join-Path -Path $myDocuments -ChildPath 'PowerShell\Microsoft.PowerShell_profile.ps1'
    if (Test-Path -Path $myProfile) {
        . $myProfile
    }
    else {
        Write-Log -NoConsoleOutput -Message "No PowerShell profile found at $myProfile"
    }

    # Install and import secret management modules if not already installed
    $modulestoinstall = @('Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')
    $modulestoinstall | ForEach-Object {
        if (-not (Get-Module -ListAvailable -Name $_)) {
            Install-Module -Name $_ -Scope CurrentUser -Force
        }
        Import-Module -Name $_ -Force
    }

    # Check the current configuration
    $currentConfig = Get-SecretStoreConfiguration

    if ($currentConfig.Authentication -ne 'None') {
        try {
            # Attempt to unlock the secret store
            Write-Log -Message "You will now be asked to enter the password for the current store: " -Level WARNING
            Unlock-SecretStore -Password $(Read-Host -Prompt "Enter the password for the secret store" -AsSecureString)
        }
        catch {
            # If unlocking fails, reconfigure the secret store to not require authentication
            Set-SecretStoreConfiguration -Scope CurrentUser -Authentication None -Interaction None -Confirm:$false
        }
    }
    else {
        # if there is no secret store, create one
        try {
            Write-Log -Message "Initializing the secret store..." -Level INFO
            Write-Log -Message "You will now be asked to enter a password for the secret store: " -Level WARNING
            Set-SecretStoreConfiguration -Scope CurrentUser -Authentication None -Interaction None -Confirm:$false
        }
        catch {
            Write-Log -Message "An error occurred while initializing the secret store: $_" -Level ERROR
            throw
        }
    }

    # Check if the secret is a SecureString and convert it to plain text if necessary
    if ($Secret -is [System.Security.SecureString]) {
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        $Secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }

    try {
        # Check if the secret already exists
        $existingSecret = Get-Secret -Name $SecretName -ErrorAction SilentlyContinue

        # Store the provided secret as a named secret in the secret store
        Set-Secret -Name $SecretName -Secret $Secret

        if ($null -ne $existingSecret) {
            Write-Host "The secret '$SecretName' already existed and has been overwritten." -ForegroundColor Yellow
        }
        else {
            Write-Host "The secret '$SecretName' has been created successfully." -ForegroundColor Green
        }
    }
    catch {
        Write-Host "An error occurred while setting the secret: $_" -ForegroundColor Red
        throw
    }

    # Return the name of the secret
    return $SecretName
}