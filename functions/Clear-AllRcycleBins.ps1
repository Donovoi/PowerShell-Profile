function Clear-AllRecycleBins {
    [CmdletBinding()]
    param ()

    # Get a list of subst drive letters
    $substDrives = subst | Where-Object { $_ -match ':\\:\s+=>\s+' } | ForEach-Object { ($_.Split(' ')[0].Split('\')[0]) }

    # If no subst drives were found, initialize $substDrives to an empty array to prevent errors in the Where-Object cmdlet
    if (-not $substDrives) {
        $substDrives = @()
    }

    # Get a list of logical disks with DriveType=3 and filter out subst drives
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' |
        Where-Object { $substDrives -notcontains $_.DeviceID } |
            ForEach-Object {
                $driveLetter = ($_.DeviceID -replace ':', '')
                Write-Logg -Message "Attempting to clear recycle bin for drive: $driveLetter" -Level Info

                try {
                    Clear-RecycleBin -DriveLetter $driveLetter -Confirm:$false
                }
                catch {
                    Write-Host "Failed to clear recycle bin for drive $driveLetter`: $_"
                }
            }
}
