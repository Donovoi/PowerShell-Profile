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
        $SecretName,

        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]
        $SecurePassword = $(ConvertTo-SecureString -String 'PrettyPassword' -AsPlainText -Force)
    )

    # Install and import secret management modules if not already installed
    $modulesToInstall = @('Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')
    $modulesToInstall | ForEach-Object {
        if (-not (Get-Module -ListAvailable -Name $_)) {
            Install-Module -Name $_ -Scope CurrentUser -Force -Confirm:$false -AllowClobber
        }
        Import-Module -Name $_ -Force
    }

    # Check if a vault is registered
    $vaults = Get-SecretVault
    if ($vaults) {
        $currentConfig = Get-SecretStoreConfiguration
        if ($currentConfig.Authentication -ne 'None') {

            try {
                # Use the provided SecureString password to unlock the secret store
                Unlock-SecretStore -Password $SecurePassword
            }
            catch {
                # If unlocking fails, reconfigure the secret store to not require authentication
                Set-SecretStoreConfiguration -Scope CurrentUser -Authentication None -Interaction None -Confirm:$false
            }
        }
    }
    else {
        try {
            Write-Logg -Message "Initializing the secret store..." -Level Warning
            Register-SecretVault -Name SecretStorePowershellrcloned -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault -AllowClobber -Confirm:$false
            Set-SecretStoreConfiguration -Scope CurrentUser -Authentication None -Interaction None -Confirm:$false -Password $SecurePassword
        }
        catch {
            Write-Logg -Message "An error occurred while initializing the secret store: $_" -Level Error
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
        Write-Logg -Message "An error occurred while setting the secret: $_" -Level Error
        throw
    }

    # Return the name of the secret
    return $SecretName
}