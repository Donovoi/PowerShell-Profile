function Set-ACLs {
  [CmdletBinding()]
  param(

    [Parameter(Mandatory = $false)]
    [string]
    $FolderToScan = $XWAYSUSB + "\"

  )
  $PWD
  $ErrorActionPreference = 'Continue'
  $NewOwner = New-Object System.Security.Principal.NTAccount ("$ENV:COMPUTERNAME","$ENV:USERNAME")
  # Now we run the es.exe tool to get a list of all files in the $FolderToScan
  # Start-Process -FilePath "D:\Projects\PowerShell-Profile\Non PowerShell Tools\FastFileEnum\bin\Debug\net7.0\win32.exe" -ArgumentList "$(Resolve-Path $FolderToScan)" -Wait -NoNewWindow -Verbose

  # TODO: Replace this with the Get-Everything cmdlet
  Start-Process -FilePath ".\Non PowerShell Tools\everything portable\es.exe" -ArgumentList "-full-path-and-name -export-csv OUTPUT.csv folder: $($XWAYSUSB)\ -no-header" -Wait -NoNewWindow

  $OutPutCSV = Resolve-Path .\OUTPUT.csv

  Get-Content $outputcsv -ReadCount 1 | ForEach-Object -Process {

    # handle apostrophes in file paths
    $SanitizedFilePath = $_.Trim('"')
    $ResolvedFilePath = Resolve-Path -Path $SanitizedFilePath -Verbose
    $acl = (Get-Acl $ResolvedFilePath)
    if ($acl.Owner -ne $NewOwner) {
      $acl.SetOwner($NewOwner)
      Set-Acl -Path $ResolvedFilePath -AclObject $acl
      [GC]::Collect()
    }
  }


  # # Get the total number of files
  # $totalFiles = $FilePathsArray.Count
  # $filesdone = 0

  # $FilePathsArray | ForEach-Object -Process {
  #     $f = Resolve-Path -LiteralPath $_
  #     $acl = (Get-Acl $f)
  #     If ($acl.Owner -ne $NewOwner) {
  #         $acl.SetOwner($NewOwner)
  #         Set-Acl -Path $f -AclObject $acl

  #     }
  #     $filesdone += 1
  #     $progress = $filesdone / $totalFiles * 100
  #     $progress = $progress.ToString('0.00')
  #     Write-Progress -PercentComplete $progress -Completed $filesdone -SecondsRemaining $((($totalFiles - $filesdone) * ($progress / 100) * 60))




}
#Set-ACLs -Verbose

