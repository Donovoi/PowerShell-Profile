function Update-DotNetSDK {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]
        $SearchPattern = 'Microsoft.DotNet.SDK'
    )

    # Search for available .NET SDKs using winget
    $availableSDKs = winget search $SearchPattern | Where-Object { $_ -match 'Microsoft\.DotNet\.SDK\.' }

    # Extract the version or identifier part of the SDK from the search results
    $DotNetVersions = $availableSDKs -replace '.*Microsoft\.DotNet\.SDK\.([^\s]+).*', '$1'

    foreach ($DotNetVersion in $DotNetVersions) {
        Write-Logg -Message "Installing .NET SDK version $DotNetVersion"
        winget install $("Microsoft.DotNet.SDK." + $DotNetVersion) --force --accept-source-agreements --accept-package-agreements
        Write-Logg -Message "Finished installing .NET SDK version $DotNetVersion"
    }
}