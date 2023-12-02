function Unprotect-Excel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path $_ -PathType 'Leaf' })]
        [string]$Excel
    )

    try {
        $ExcelFilePath = Split-Path -Path $Excel
        $ExcelName = Split-Path -Path $Excel -Leaf
        $ExcelTempDir = Join-Path -Path $ExcelFilePath -ChildPath ($ExcelName + '_temp')
        $ExcelFileSaved = Join-Path -Path $ExcelFilePath -ChildPath ($ExcelName + '_unprotected.xlsx')

        if (Test-Path $ExcelTempDir) {
            Remove-Item $ExcelTempDir -Force -Recurse
        }

        if (Test-Path $ExcelFileSaved) {
            Remove-Item $ExcelFileSaved -Force
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Excel, $ExcelTempDir)

        $Input = Join-Path -Path $ExcelTempDir -ChildPath 'xl\worksheets\sheet1.xml'
        $Output = Join-Path -Path $ExcelTempDir -ChildPath 'xl\worksheets\sheet1.xml'

        # Load the existing document
        $Doc = [xml](Get-Content $Input)

        # Remove all tags with the name "sheetProtection"
        $DeleteNames = 'sheetProtection'
        $Doc.worksheet.ChildNodes | Where-Object { $DeleteNames -contains $_.Name } | ForEach-Object {
            # Remove each node from its parent
            [void]$_.ParentNode.RemoveChild($_)
        }

        # Save the modified document
        $Doc.Save($Output)

        [System.IO.Compression.ZipFile]::CreateFromDirectory($ExcelTempDir, $ExcelFileSaved)

        Write-Output 'Success'
        [Environment]::Exit(200)
    }
    catch {
        Write-Output 'Failed'
        throw "An error occurred: $_"
    }
}
