function Set-ACLs {
    [CmdletBinding()]
    param (
       
         [Parameter(Mandatory = $false)]
         [string]
        $FolderToScan = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\"

    )
    $ErrorActionPreference = 'Continue'
    $NewOwner = New-Object System.Security.Principal.NTAccount("$ENV:COMPUTERNAME", "$ENV:USERNAME")
    # Now we run the fastfileenum exe to get a list of files appeneded to a text file on the desktop
    Start-Process -FilePath "D:\Projects\PowerShell-Profile\Non PowerShell Tools\FastFileEnum\bin\Debug\net7.0\win32.exe" -ArgumentList "$(Resolve-Path $FolderToScan)" -Wait -NoNewWindow -Verbose
    
    # read the large text file line by line into an in memory collection. this needs to be the fastest way to do this
    $RAWPaths = Import-Content -Path $env:USERPROFILE\desktop\files.txt -Verbose
    

    if (-not ([string]::IsNullOrWhiteSpace($RAWPaths))) {
        [string[]]$Files = if (-not ([string]::IsNullOrWhiteSpace($RAWPaths))) {
          $RAWPaths.Split()
        }
        if (-Not ([string]::IsNullOrWhiteSpace($Files))) {
          $FastFileList = [System.Collections.Generic.HashSet[string]]::new([string[]]($Files), [System.StringComparer]::OrdinalIgnoreCase)
        }
    }
    [GC]::Collect()

    # Get the total number of files
    $totalFiles = $FastFileList.Count
    $filesdone = 0

    $files | ForEach-Object -Process {
        $f = Resolve-Path $_
        $acl = (Get-Acl $f)
        # $fObject = $f | Select-Object @{Name = 'FullName'; Expression = { $_ } }
        # $aclObject = $acl | Select-Object @{Name = 'Acl'; Expression = { $_ } }
        # Select-Object $fObject, $aclObject | Export-Csv -Path $env:USERPROFILE\desktop\acls.csv -Append -Force
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
# Set-ACLs -Verbose