function Update-DotNetSDK {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]
        $DotNetVersions = @('3_1', '5', '6', '7', '8', 'Preview')
    )

    foreach ($DotNetVersion in $DotNetVersions) {
        Write-Logg -Message "Installing .NET SDK version $DotNetVersion"
        winget install $('Microsoft.DotNet.SDK.' + $($DotNetVersion)) --force --accept-source-agreements --accept-package-agreements
        Write-Logg -Message "Finished installing .NET SDK version $DotNetVersion"
    }

}