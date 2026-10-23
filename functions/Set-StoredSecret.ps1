function Set-StoredSecret {
    <#
    .SYNOPSIS
    Stores a secret in an explicitly registered vault without changing its policy.
    .DESCRIPTION
    Installs missing SecretManagement/SecretStore modules when invoked.
    SecureString and PSCredential values pass directly to Set-Secret. Other types
    supported by SecretManagement (string, byte[] and hashtable) are accepted.
    With no Vault, uses the default vault or the sole registered vault.
    Register a vault explicitly before first use; authentication is never weakened.
    SecurePassword unlocks a SecretStore vault only. No secret value is logged.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Secret,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SecretName,
        [Security.SecureString]$SecurePassword,
        [string]$Vault
    )
    if ($Secret -isnot [Security.SecureString] -and $Secret -isnot [pscredential] -and
        $Secret -isnot [string] -and $Secret -isnot [byte[]] -and $Secret -isnot [hashtable]) {
        throw 'Secret must be SecureString, PSCredential, string, byte[] or hashtable.'
    }
    if (-not $PSCmdlet.ShouldProcess($SecretName, 'Store secret using the registered vault policy')) { return }
    $ErrorActionPreference = 'Stop'
    foreach ($moduleName in 'Microsoft.PowerShell.SecretManagement','Microsoft.PowerShell.SecretStore') {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) { Install-Module -Name $moduleName -Scope CurrentUser -Force -ErrorAction Stop }
        Import-Module -Name $moduleName -ErrorAction Stop
    }
    $vaults = @(Get-SecretVault -ErrorAction Stop)
    if ($Vault) { $selected = @($vaults | Where-Object Name -EQ $Vault) }
    else {
        $selected = @($vaults | Where-Object IsDefault)
        if (-not $selected.Count -and $vaults.Count -eq 1) { $selected = $vaults }
    }
    if ($selected.Count -ne 1) { throw 'Select an existing vault with -Vault. For first use, explicitly register a vault with Register-SecretVault and configure its authentication.' }
    if ($SecurePassword) {
        if ($selected[0].ModuleName -ne 'Microsoft.PowerShell.SecretStore') { throw '-SecurePassword is only supported for a SecretStore vault.' }
        try { Unlock-SecretStore -Password $SecurePassword -ErrorAction Stop }
        catch { throw 'SecretStore unlock failed. Authentication settings were not changed.' }
    }
    try { Set-Secret -Name $SecretName -Secret $Secret -Vault $selected[0].Name -ErrorAction Stop }
    catch { throw 'The secret could not be stored. Check vault access and unlock it if needed; authentication settings were not changed.' }
    $SecretName
}
