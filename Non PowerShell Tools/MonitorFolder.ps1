

# Function to copy new images to the root
function Copy-NewImage {
    # Define the source and destination directories
    $copieditems = 0
    $sourceDir = Join-Path -Path $ENV:USERPROFILE -ChildPath 'Pictures'

    # Get all image file names in the root of the source directory
    $rootImageNames = (Get-ChildItem -Path $sourceDir -File -Include '*.jpg', '*.jpeg', '*.png', '*.gif', '*.bmp', '*.webp').Name

    # Get all images from subdirectories
    $images = Get-ChildItem -Path $sourceDir -Recurse -File -Include '*.jpg', '*.jpeg', '*.png', '*.gif', '*.bmp', '*.webp' | 
        Where-Object { $_.DirectoryName -ne $sourceDir -and $rootImageNames -notcontains $_.Name }

    foreach ($image in $images) {
        $destPath = Join-Path -Path $sourceDir -ChildPath $image.Name

        # Copy the file if it does not have the same name as an existing file in the root directory
        if (-not (Test-Path -Path $destPath)) {
            Copy-Item -Path $image.FullName -Destination $destPath
            if ($?) {
                $copieditems++
                Write-Output "Copied new image: $destPath"
            }
            else {
                Write-Warning "Failed to copy image: $destPath"
            }
        }
    }

    # Output the total number of copied images
    Write-Output "Total copied images: $copieditems"
}