# simple function to make sure any url is the highest number/ latest version
# Given a url check if there is a higher version of the same file

function Get-LatestVersion() {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $URL
    )
    # Make request to ensure given url is still valid
    $response = Invoke-RestMethod -Uri $URL -Method Get
    if ($response.StatusCode -eq 200) {
        # Cancel the download
        $response.Close()
        # Identify where the version number is in the url
        $version = $response.Headers.GetValues('Location').First().split('/').Last()
    } else {
        Write-Error 'CoPilot is not smart enough to create this function'
        exit
    }

    # Return the version number
    return $version
    
}
