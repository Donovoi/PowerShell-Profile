function Format-Powershell {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]
    $FolderOrFilePath
  )

  if (-not (Get-Module -ListAvailable -Name 'PSScriptAnalyzer')) {
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
  }

  if (-not (Get-Module -ListAvailable -Name 'PowerShell-Beautifier')) {
    Install-Module -Name PowerShell-Beautifier -Scope CurrentUser -Force
  }

  Import-Module PSScriptAnalyzer
  Import-Module PowerShell-Beautifier


  #Handle if the path is a file or a folder
  #If File
  if ($FolderOrFilePath -like '*.ps*') {
    Edit-DTWBeautifyScript -SourcePath $(Resolve-Path $FolderOrFilePath)
  }
  else {
    #If Folder
    $files = Get-ChildItem -Path $FolderOrFilePath -Recurse -Include @("*.ps1", "*.psm1", "*.psd1")
    foreach ($file in $files) {
      Edit-DTWBeautifyScript -SourcePath $file.FullName
      # $beautifiedContent = [System.IO.File]::ReadAllText($file.FullName)

      # $rules = (Get-ScriptAnalyzerRule).RuleName

      # $settings = @{
      #   IncludeRules = $rules
      # }

      # Invoke-Formatter -ScriptDefinition $beautifiedContent -Settings $settings | Out-File -FilePath $file.FullName -Force
    }
  }

}


