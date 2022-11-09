# Implement your module commands in this script.

function GetStrings {
  [CmdletBinding()]
  param
  (
    [Parameter(Position = 1, Mandatory = $True, ValueFromPipeline = $True)]
    [String[]]
    $Path,

    [uint32]
    $MinimumLength = 5
  )

  process {
    [string]$AsciiFileContents = $Path
    $AsciiRegex = [regex]"[\x20-\x7E]{$MinimumLength,}"
    $Results = $AsciiRegex.Matches($AsciiFileContents)

    $Results
  }
}



function Import-Content {
  [CmdletBinding()]
  param(
    [Parameter(
      Mandatory = $true,
      ValueFromPipeline = $true,
      Position = 0
    )]
    [ValidateNotNullOrEmpty()]
    [string[]]
    $Path,
    [switch]
    $Raw
  )
  process {
    $Files = Get-ChildItem -LiteralPath $Path -Recurse -Force -File
    foreach ($file in (Resolve-Path -LiteralPath $Files)) {
      if (Test-Path -LiteralPath $file -PathType Leaf) {
        if ($Raw) {
          [System.IO.File]::ReadAllText($file) | Write-Output -NoEnumerate

        } else {
          [System.IO.File]::ReadAllLines($file) | Write-Output -NoEnumerate

        }
      }
    }
  }
}


# Export only the functions using PowerShell standard verb-noun naming.
# Be sure to list each exported functions in the FunctionsToExport field of the module manifest file.
# This improves performance of command discovery in PowerShell.
Export-ModuleMember -Function *-*
Export-ModuleMember -Function GetStrings
