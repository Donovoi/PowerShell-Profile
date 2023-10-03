<#
.SYNOPSIS
Tests whether a file is a valid ZIP archive.

.DESCRIPTION
The Test-ZipFile function tests whether a file is a valid ZIP archive by checking the first 4 bytes of the file for the ZIP magic number. The function returns $true if the file is a valid ZIP archive, and $false otherwise.

.PARAMETER FilePath
Specifies the path to the file to be tested.

.INPUTS
[string]
Accepts the path to the file to be tested as a string.

.OUTPUTS
[bool]
Returns $true if the file is a valid ZIP archive, and $false otherwise.

.EXAMPLE
PS C:\> Test-ZipFile -FilePath C:\Users\JohnDoe\Documents\example.zip
True

This example tests whether the file "example.zip" located in the "C:\Users\JohnDoe\Documents" directory is a valid ZIP archive.

.NOTES
Author: Unknown
Last Edit: Unknown
#>
function Test-ZipFile {
    [cmdletbinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
        [string]$FilePath
    )

    process {
        try {
            $zipMagicBytes = @(
                [byte[]] (0x50, 0x4B, 0x03, 0x04),
                [byte[]] (0x50, 0x4B, 0x05, 0x06),
                [byte[]] (0x50, 0x4B, 0x07, 0x08)
            )

            $bytes = New-Object -TypeName 'byte[]' -ArgumentList 4

            $fileStream = [System.IO.File]::OpenRead($FilePath)
            try {
                [void]$fileStream.Read($bytes, 0, 4)
            }
            finally {
                $fileStream.Close()
            }

            return ($null -ne ($zipMagicBytes | Where-Object { [System.BitConverter]::ToString($bytes) -eq [System.BitConverter]::ToString($_) }))
        }
        catch {
            Write-Warning "An error occurred: $_"
            return $false
        }
    }
}