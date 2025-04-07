# Helper function to determine the final output path
function Get-FinalOutputPath {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param (
        [string]$BasePath,
        [string]$FileName,
        [switch]$Force
    )

    # If the output path doesn't include a file name (ends with \ or /), append the file name
    if ($BasePath -match '[/\\]$' -or (Test-Path -Path $BasePath -PathType Container)) {
        $folderPath = $BasePath
        if (-not (Test-Path -Path $folderPath -PathType Container)) {
            New-Item -Path $folderPath -ItemType Directory -Force | Out-Null
            Write-Verbose "Created directory: $folderPath"
        }

        $fullPath = Join-Path -Path $folderPath -ChildPath $FileName
        Write-Verbose "Using generated full path: $fullPath"
    }
    else {
        # Ensure the directory exists
        $directory = Split-Path -Path $BasePath -Parent
        if (-not [string]::IsNullOrEmpty($directory) -and -not (Test-Path -Path $directory -PathType Container)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
            Write-Verbose "Created directory: $directory"
        }

        $fullPath = $BasePath
        Write-Verbose "Using specified path: $fullPath"
    }

    # Check if file exists and handle Force parameter
    if (Test-Path -Path $fullPath -PathType Leaf) {
        if (-not $Force -and -not $PSCmdlet.ShouldProcess($fullPath, 'Overwrite existing file')) {
            throw "File already exists: $fullPath. Use -Force to overwrite."
        }
        Write-Verbose "File exists, will be overwritten: $fullPath"
    }

    return $fullPath
}
