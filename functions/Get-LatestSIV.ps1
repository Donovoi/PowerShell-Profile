function Get-LatestSIV {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$url = 'https://delivery2.filecroco.com/kits_6/siv_v5.70.zip',
        
        [Parameter(Mandatory = $true)]
        [string]$destinationFolder = "$XWAYSUSB"
    )

    # Extract the base URL
    $uri = New-Object System.Uri($url)
    $baseURL = $uri.Scheme + '://' + $uri.Host + [System.String]::Join('', $uri.Segments[0..($uri.Segments.Length - 2)])
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($url)

    # Extract the program name and the version
    $programName, $version = $fileName -split '_v'

    # Convert the version to a decimal
    $currentVersion = [decimal]$version

    # Initialize the latest version to the current version
    $latestVersion = $currentVersion

    # Loop until we no longer find a newer version
    while ($true) {
        # Increment the version
        $nextVersion = $latestVersion + 0.01

        # Construct the next URL
        $nextURL = "$($baseURL)$programName`_v{0:N2}.zip" -f $nextVersion

        # Check if the next version exists
        try {
            $request = [System.Net.WebRequest]::Create($nextURL)
            $request.Method = 'HEAD'
            $response = $request.GetResponse()
            $response.Close()
        }
        catch {
            # If we get an error, the version probably doesn't exist, so break out of the loop
            break
        }

        # If we didn't get an error, the version exists, so set it as the latest version
        $latestVersion = $nextVersion
    }


    # Construct the download URL
    $downloadURL = "$($baseURL)$programName`_v{0:N2}.zip" -f $latestVersion

    # Construct the destination file path
    $destinationFile = Join-Path -Path $destinationFolder -ChildPath "$programName`_v$latestVersion.zip"

    # Check if the destination file already exists
    if (Test-Path $destinationFile) {
        Write-Output 'The latest version is already downloaded.'
        return
    }

    # Download the file using BITS
    Get-Service -Name BITS | Start-Service
    Start-BitsTransfer -Source $downloadURL -Destination $destinationFile
}