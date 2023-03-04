function Set-ACLs {
    [CmdletBinding()]
    param (
       
        [Parameter(Mandatory = $false)]
        [string]
        $FolderToScan = "$($(Get-Volume -FriendlyName 'X-Ways*').DriveLetter)`:\"       
        
    )
    $ErrorActionPreference = 'Continue'
    $NewOwner = New-Object System.Security.Principal.NTAccount("$ENV:COMPUTERNAME", "$ENV:USERNAME")
    $files = Get-Content -Path $env:USERPROFILE\desktop\files.txt

    # Get the total number of files
    $totalFiles = $files.Count
    $filesdone = 0

    $files | ForEach-Object -Process {
        $f = Resolve-Path -LiteralPath $_.FullName
        $acl = (Get-Acl $f)
        $fObject = $f | Select-Object @{Name = 'FullName'; Expression = { $_ } }
        $aclObject = $acl | Select-Object @{Name = 'Acl'; Expression = { $_ } }
        Select-Object $fObject, $aclObject | Export-Csv -Path $env:USERPROFILE\desktop\acls.csv -Append -Force
        If ($acl.Owner -ne $NewOwner) {
            $acl.SetOwner($NewOwner)
            Set-Acl -Path $f -AclObject $acl

        }
        $filesdone += 1
        $progress = $filesdone / $totalFiles * 100
        $progress = $progress.ToString('0.00')
        Write-Progress -PercentComplete $progress -Completed $filesdone -SecondsRemaining $((($totalFiles - $filesdone) * ($progress / 100) * 60))



    }
}