$ErrorActionPreference = 'silentlycontinue';
Import-Module -Name .\Get-UniqueStrings.psm1 -Global
function Get-UniqueStrings {
  [CmdletBinding()]
  param(
    # Directory to process
    [Parameter(Mandatory = $false)]
    [string]
    $Path = $(Get-Location).Path,
    # Minimum length of strings to work with
    [Parameter(Mandatory = $false)]
    [int16]
    $MinLength = 5,
    # Destination File
    [Parameter(Mandatory = $false)]
    [string]
    $FinalFile = $(Get-Location).Path + '../Unique.txt'
  )

  $Directory = $Path
  if (-not ([string]::IsNullOrWhiteSpace($Directory))) {
    [string[]]$Content = Import-Content -Path $Directory
    [string[]]$StringsOnly = $Content | GetStrings -MinimumLength $MinLength
    if (-not ([string]::IsNullOrWhiteSpace($StringsOnly))) {
      [string[]]$Words = if (-not ([string]::IsNullOrWhiteSpace($StringsOnly))) {
        $StringsOnly.Split()
      }
      if (-not ([string]::IsNullOrWhiteSpace($Words))) {
        $UniqueWordList = [System.Collections.Generic.HashSet[string]]::new([string[]]($Words),[System.StringComparer]::OrdinalIgnoreCase)
      }

    }
    [string]$hashString = ($UniqueWordList | Out-String).Trim()

    $hashString | Out-File -FilePath $FinalFile -Encoding Ascii -Force
  }
  Write-Output 'Done'


}

