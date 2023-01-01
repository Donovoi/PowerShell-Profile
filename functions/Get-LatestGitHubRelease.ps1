function Get-LatestGitHubRelease {

    param (
        [Parameter(Mandatory = $true)]
        [string] $url
    )

    # extract the project name from the URL
    $projectName = $url -replace 'https://github.com/', '' -replace '/', '-'

    # create a directory to download the release to
    $downloadDirectory = "C:\temp\$projectName"
    New-Item -ItemType Directory -Path $downloadDirectory | Out-Null

    # get the latest release from the GitHub API
    $latestRelease = (Invoke-WebRequest -Uri "$($url)/releases/latest").Content | ConvertFrom-Json

    # check if there is a release asset to download
    if ($latestRelease.assets.Count -gt 0) {
        # download the first asset (there may be multiple assets per release)
        $asset = $latestRelease.assets[0]
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile "$($downloadDirectory)\$($asset.name)"
    }
    else {
        Write-Output "No release assets to download."
    }
}

