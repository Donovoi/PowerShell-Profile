function Unprotect-ExcelSheet {
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
        $ExcelBackup = Join-Path -Path $ExcelFilePath -ChildPath ($ExcelName + '_backup.xlsx')

        Copy-Item $Excel $ExcelBackup -Force

        if (Test-Path $ExcelTempDir) {
            Remove-Item $ExcelTempDir -Force -Recurse
        }

        if (Test-Path $ExcelFileSaved) {
            Remove-Item $ExcelFileSaved -Force
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($Excel, $ExcelTempDir)

        $Sheets = Get-ChildItem -Path $ExcelTempDir\xl\worksheets -Filter *.xml

        foreach ($Sheet in $Sheets) {
            $Doc = ([xml](Get-Content $Sheet.FullName -Force))

            # Create a hashtable for the namespace
            $ns = @{
                x = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
            }

            # Use the hashtable with the XPath query
            $NodesToRemove = Select-Xml -Xml $Doc -XPath '//x:sheetProtection' -Namespace $ns | Select-Object -ExpandProperty Node

            foreach ($Node in $NodesToRemove) {
                $Node.ParentNode.RemoveChild($Node)
            }

            $Doc.Save($Sheet.FullName)
        }

        [System.IO.Compression.ZipFile]::CreateFromDirectory($ExcelTempDir, $ExcelFileSaved)

        Remove-Item $ExcelTempDir -Force -Recurse

        Write-Output 'Success'
    }
    catch {
        Write-Output 'Failed'
        throw "An error occurred: $_"
    }
    finally {
        if (Test-Path $ExcelTempDir) {
            Remove-Item $ExcelTempDir -Force -Recurse
        }
    }
}