function Get-LatestSIV {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$url = 'https://www.filecroco.com/download-system-information-viewer/download/',

        [Parameter(Mandatory = $false)]
        [string]$destinationFolder = $XWAYSUSB ? $XWAYSUSB : "$ENV:USERPROFILE\Downloads"
    )

    # read the text on the page, there will be a line like this:
    # HomeSystem UtilitiesSystem InfoSystem Information Viewer 5.79 Downloading
    # Extract the version from this line
    $programName = 'System Information Viewer'
    $latestVersion = 0
    $pageContent = Invoke-WebRequest -Uri $url -UseBasicParsing
    $versionLine = $pageContent.Content -match "$programName\s+(\d+\.\d+)"
    if ($versionLine) {
        $latestVersion = [float]$matches[1]
    }
    Write-Output "Latest version found: $latestVersion"

    # Download using the Download button on the page, button will have the text 'Download now'
    $downloadButton = $pageContent.Links | Where-Object { $_ -like '*Download now*' }
    if ($downloadButton) {
        $downloadURL = $downloadButton.href
        Write-Output "Download URL found: $downloadURL"
    }
    else {
        Write-Output 'Download button not found'
        return
    }

    # Download the file using httpclient
    $client = New-Object System.Net.Http.HttpClient
    $response = $client.GetAsync($downloadURL).Result
    $response.EnsureSuccessStatusCode()
    $content = $response.Content.ReadAsByteArrayAsync().Result
    $finalfile = "$destinationFolder\$programName.zip"

    Write-Output "Saving to $finalfile"
    if (Test-Path $finalfile) {
        Remove-Item -Path $finalfile
    }
    [System.IO.File]::WriteAllBytes("$finalfile", $content)

    # Copy and extract to xwaysusb
    $XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
    $extractedsivPath = "$XWAYSUSB\siv"
    if (Test-Path $extractedsivPath) {
        Remove-Item -Path $extractedsivPath -Recurse -Force
    }
    Expand-Archive -Path $finalfile -DestinationPath $extractedsivPath -Force
    Write-Output "Extraction completed to $extractedsivPath"

}