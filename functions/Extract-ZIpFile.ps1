<#
.SYNOPSIS
Extracts the contents of a zip file to a specified output folder.

.DESCRIPTION
The Extract-ZipFile function extracts the contents of a zip file to a specified output folder. It uses the System.IO.Compression.ZipFile class to open and read the zip file, and then iterates through each entry in the zip archive. For each entry, it creates the corresponding target path in the output folder, creates any necessary directories, and copies the entry's contents to the target file.

.PARAMETER zipFilePath
The path to the zip file that needs to be extracted..

.PARAMETER outputFolderPath
The path to the folder where the contents of the zip file should be extracted.

.EXAMPLE
Extract-ZipFile -zipFilePath "C:\path\to\archive.zip" -outputFolderPath "C:\path\to\output"

This example extracts the contents of the "archive.zip" file to the "output" folder.

.NOTES
Author: Your Name
Date:   Current Date
#>
function Extract-ZipFile {
    param (
        [string]$zipFilePath,
        [string]$outputFolderPath
    )
    Add-Type -AssemblyName System.Net.Http
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (-not (Test-Path $zipFilePath)) {
        Write-Error "Zip file does not exist: $zipFilePath"
        return
    }

    try {
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipFilePath)
        foreach ($entry in $zipArchive.Entries) {
            $targetPath = Join-Path $outputFolderPath $entry.FullName
            if (-not $entry.FullName.EndsWith('/')) {
                $dir = Split-Path $targetPath
                if (-not (Test-Path $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                $entryStream = $entry.Open()
                $fileStream = [System.IO.File]::Create($targetPath)
                $entryStream.CopyTo($fileStream)
                $fileStream.Dispose()
                $entryStream.Dispose()
            }
        }
    }
    catch {
        Write-Error "An error occurred while extracting the zip file: $_"
    }
    finally {
        if ($null -ne $zipArchive) {
            $zipArchive.Dispose()
        }
    }
}