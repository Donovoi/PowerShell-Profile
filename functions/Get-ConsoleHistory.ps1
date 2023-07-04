# This function will make sure this script is upto date by downloading
# https://raw.githubusercontent.com/gui-cs/F7History/main/F7History.ps1
#  and hashing as md5 and sha1, if the script is up-to-date we will dot source
#  The function to add it to the powershell profile

<#
.SYNOPSIS
    Short description
.DESCRIPTION
    Long description
.EXAMPLE
    Example of how to use this cmdlet
.EXAMPLE
    Another example of how to use this cmdlet
#>
function Get-ConsoleHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [switch]
        $update
    )
    $ps1file = '.\F7History.ps1'
    $jsonFile = '.\hashes.json'
        
    if ($update) {       
        
        $oldHashes = New-Object PSObject -Property @{'Filename' = ''; 'MD5' = ''; 'SHA1' = '' }

        if (Test-Path $jsonFile) {
            $oldHashes = Get-Content $jsonFile | ConvertFrom-Json
        }
        else {
            New-Item -Path $jsonFile -ItemType File -Force
        }

        if (Test-Path $ps1file) {
            $md5HashResult = Get-FileHash -Path $ps1file -Algorithm MD5
            $sha1HashResult = Get-FileHash -Path $ps1file -Algorithm SHA1
        }
      
        if (-not(Test-Path $ps1file) -or $($oldHashes.MD5 -ne $md5HashResult.Hash) -or $($oldHashes.SHA1 -ne $sha1HashResult.Hash)) {
            Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/gui-cs/F7History/main/F7History.ps1' -OutFile $ps1file
            
            # Add dot source to current PowerShell profile if it's not yet added.
            if ($null -eq (Get-Content -Path $PROFILE -ErrorAction SilentlyContinue | Select-String -Pattern ". $ps1file")) {
                Add-Content -Path $PROFILE -Value ". $ps1file"
                . $PROFILE
            }

            

            $md5HashResult = Get-FileHash -Path $ps1file -Algorithm MD5
            $sha1HashResult = Get-FileHash -Path $ps1file -Algorithm SHA1

            $newHashes = New-Object PSObject -Property @{
                Filename = $ps1file
                MD5      = $md5HashResult.Hash
                SHA1     = $sha1HashResult.Hash
            }

            $newHashes | ConvertTo-Json | Set-Content $jsonFile
        }
    }
}
