function Update-DotNetSDK {
    [CmdletBinding()]    
    param(
        [Parameter(Mandatory=$false)]
        [string[]]
        $DotNetVersions = @(3,5,6,7,"Preview")
    )
    foreach($version in $DotNetVersions) {
        Write-Host "Installing .NET SDK version $version"
        winget install Microsoft.DotNet.SDK.$($version) --force --accept-source-agreements --accept-package-agreements
        Write-Host "Finished installing .NET SDK version $version"
    }

}
