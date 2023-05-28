function Git-Pull {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Path = $PSScriptRoot
  )

  $ErrorActionPreference = 'Break'
  $global:OriginalCommand = $MyInvocation.MyCommand

  $repositories = @{}
  $repositories = Get-ChildItem -Path $Path -Recurse -Directory -Filter '.git' -Force | Split-Path -Parent
  # iterate through the hashtable and perform a git pull on each repository. THe repository is the parent of the .git directory
  #  We need to get the full path of the .git directory, then navigate to the parent directory and perform the git pull.
  $repositories.GetEnumerator() | ForEach-Object {
    Write-Output "Pulling from $($_)"
    Set-Location -Path $_
    # Set ownership to current user and grant full control to current user recursively
    icacls.exe $_ /setowner "$env:UserName" /t /c /q
    git config --global --add safe.directory $(Resolve-Path -Path $PWD)
    git pull --verbose
    Write-Output "git pull complete for $($_)"
  }


  # clean up
  Remove-Variable -Name repository -Force
  Remove-Variable -Name repositories -Force
  [GC]::Collect()
}