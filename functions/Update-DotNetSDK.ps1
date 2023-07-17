function Update-DotNetSDK {
    [CmdletBinding()]    
    param(
        [Parameter(Mandatory = $false)]
        [string[]]
        $DotNetVersions = @('3_1', '5', '6', '7', 'Preview')
    )
    foreach ($DotNetVersion in $DotNetVersions) {
        Write-Host "Installing .NET SDK version $DotNetVersion"
        winget install $('Microsoft.DotNet.SDK.' + $($DotNetVersion)) --force --accept-source-agreements --accept-package-agreements
        Write-Host "Finished installing .NET SDK version $DotNetVersion"
    }

}