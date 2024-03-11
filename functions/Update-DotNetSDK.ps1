function Update-DotNetSDK {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]
        $SearchPattern = 'Microsoft.DotNet.SDK'
    )
    $neededcmdlets = @('Write-Logg')
    $neededcmdlets | ForEach-Object {
        if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose -Message "Importing cmdlet: $_"
            $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
            $Cmdletstoinvoke | Import-Module -Force
        }
    }

    # Search for available .NET SDKs using winget
    $availableSDKs = winget search $SearchPattern | Where-Object { $_ -match 'Microsoft\.DotNet\.SDK\.' }

    # Extract the version or identifier part of the SDK from the search results
    $DotNetVersions = $availableSDKs -replace '.*Microsoft\.DotNet\.SDK\.([^\s]+).*', '$1'

    foreach ($DotNetVersion in $DotNetVersions) {
        Write-Logg -Message "Installing .NET SDK version $DotNetVersion"
        winget install $('Microsoft.DotNet.SDK.' + $DotNetVersion) --force --accept-source-agreements --accept-package-agreements
        Write-Logg -Message "Finished installing .NET SDK version $DotNetVersion"
    }
}