<#
.SYNOPSIS
    Downloads and installs supplemental X-Ways Forensics resources.

.DESCRIPTION
    Downloads selected X-Ways resource files into an X-Ways installation folder.
    The default resources are Excire, Conditional Coloring, and the AFF4 X-Tension.

    Optionally downloads WinHex/X-Ways templates from known public template sources
    into a scripts and templates folder.

    Credentials can be supplied with -Credential or stored locally with Export-Clixml.
    Stored credentials are protected by Windows DPAPI and are only decryptable by the
    same Windows user on the same machine.

.PARAMETER XWaysRoot
    The root folder of the X-Ways installation, such as F:\xwfportable.

.PARAMETER XWScriptsAndTemplatesFolder
    Optional destination folder for downloaded templates. If omitted, the command uses
    ..\XWScriptsAndTemplates relative to XWaysRoot.

.PARAMETER Credential
    Optional PSCredential object for X-Ways authenticated resource downloads. If omitted,
    the command imports the stored credential or prompts for one and stores it locally.

.PARAMETER CredentialPath
    Optional path to the stored credential XML file. This is a file path, not the
    credential value itself. Defaults to:
    Documents\XWAYSRESOURCESCREDENTIALFILES\Get-XwaysResources.credential.xml

.PARAMETER ResetCredentials
    Removes the stored credential before prompting for a new one.

.PARAMETER GetTemplates
    Downloads additional WinHex/X-Ways templates into XWScriptsAndTemplatesFolder.

.EXAMPLE
    Get-XwaysResources -XWaysRoot 'F:\xwfportable'

    Downloads the default X-Ways resource files into F:\xwfportable.

.EXAMPLE
    Get-XwaysResources -XWaysRoot 'F:\xwfportable' -GetTemplates

    Downloads the default resource files and additional templates.

.EXAMPLE
    Get-XwaysResources -XWaysRoot 'F:\xwfportable' -ResetCredentials

    Removes the stored credential and prompts for a new X-Ways credential.

.EXAMPLE
    $credential = Get-Credential
    Get-XwaysResources -XWaysRoot 'F:\xwfportable' -Credential $credential -GetTemplates

    Uses an explicitly supplied credential instead of loading or saving one first.

.EXAMPLE
    Get-XwaysResources -XWaysRoot 'F:\xwfportable' -GetTemplates -WhatIf

    Shows the download, extraction, folder creation, and cleanup actions that would run.

.OUTPUTS
    System.Management.Automation.PSCustomObject

.NOTES
    Requires network access.

    Uses Get-FileDownload when it is already available in the session; otherwise falls
    back to Invoke-WebRequest.
#>
function Get-XwaysResources {
  [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
  [OutputType([pscustomobject])]
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$XWaysRoot,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$XWScriptsAndTemplatesFolder,

    [Parameter()]
    [pscredential]$Credential,

    [Parameter()]
    [ValidateNotNull()]
    [System.IO.FileInfo]$CredentialPath = (Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)) -ChildPath 'XWAYSRESOURCESCREDENTIALFILES\Get-XwaysResources.credential.xml'),

    [Parameter()]
    [switch]$ResetCredentials,

    [Parameter()]
    [switch]$GetTemplates
  )

  function Resolve-XWaysProviderPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  }

  function Get-XWaysResourceCredential {
    param(
      [pscredential]$Credential,
      [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Credential) {
      return $Credential
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $storedCredential = Import-Clixml -LiteralPath $Path
      if ($storedCredential -isnot [pscredential]) {
        throw "Credential file '$Path' did not contain a PSCredential. Use -ResetCredentials and try again."
      }

      return $storedCredential
    }

    $parentPath = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
      New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
    }

    $newCredential = Get-Credential -Message 'Enter your X-Ways credentials'
    $newCredential | Export-Clixml -Path $Path -Force
    return $newCredential
  }

  function New-XWaysBasicAuthHeader {
    param([Parameter(Mandatory = $true)][pscredential]$Credential)

    $networkCredential = $Credential.GetNetworkCredential()
    $authenticationPair = '{0}:{1}' -f $networkCredential.UserName, $networkCredential.Password
    $authenticationToken = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($authenticationPair))

    @{
      Authorization = "Basic $authenticationToken"
      'User-Agent'  = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.5414.120 Safari/537.36'
      Referer       = 'https://x-ways.net/res/'
    }
  }

  function Save-XWaysDownload {
    param(
      [Parameter(Mandatory = $true)][uri[]]$Uri,
      [Parameter(Mandatory = $true)][string]$DestinationDirectory,
      [hashtable]$Headers
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
      New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
    }

    $downloadItems = foreach ($item in $Uri) {
      $fileName = [uri]::UnescapeDataString([IO.Path]::GetFileName($item.LocalPath))
      if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "Could not determine a file name for '$item'."
      }

      $outputPath = Join-Path -Path $DestinationDirectory -ChildPath $fileName
      if ((Test-Path -LiteralPath $outputPath -PathType Leaf) -and ((Get-Item -LiteralPath $outputPath).Length -gt 0)) {
        Write-Verbose "Output file already exists: $outputPath"
        continue
      }

      [pscustomobject]@{
        Uri        = $item
        OutputPath = $outputPath
      }
    }

    if (-not $downloadItems) {
      return
    }

    # Avoid passing Basic auth headers to external downloaders, where they can
    # appear in the process command line. Authenticated X-Ways resources use
    # native PowerShell downloads; unauthenticated template downloads may still
    # use the faster helper.
    $downloadCommand = if ($Headers -and $Headers.ContainsKey('Authorization')) {
      $null
    }
    else {
      Get-Command -Name Get-FileDownload -ErrorAction SilentlyContinue
    }
    if ($downloadCommand) {
      $downloadParameters = @{
        URL                  = @($downloadItems.Uri | ForEach-Object { $_.AbsoluteUri })
        DestinationDirectory = $DestinationDirectory
        UseAria2             = $true
        NoRPCMode            = $true
      }

      if ($Headers) {
        $downloadParameters.Headers = $Headers
      }

      Get-FileDownload @downloadParameters | Out-Null
      return
    }

    foreach ($downloadItem in $downloadItems) {
      $invokeParameters = @{
        Uri         = $downloadItem.Uri
        OutFile     = $downloadItem.OutputPath
        ErrorAction = 'Stop'
      }

      if ($Headers) {
        $invokeParameters.Headers = $Headers
      }

      Invoke-WebRequest @invokeParameters | Out-Null
    }
  }

  function Test-XWaysDirectoryHasItems {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
      return $false
    }

    return [bool](Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
  }

  function Expand-XWaysArchive {
    param(
      [Parameter(Mandatory = $true)][string]$RootPath,
      [Parameter(Mandatory = $true)][string]$ArchivePrefix,
      [Parameter(Mandatory = $true)][string]$DestinationName
    )

    $archives = Get-ChildItem -LiteralPath $RootPath -Filter "$ArchivePrefix*.zip" -File -ErrorAction SilentlyContinue
    if (-not $archives) {
      return
    }

    $destinationPath = Join-Path -Path $RootPath -ChildPath $DestinationName
    if (Test-XWaysDirectoryHasItems -Path $destinationPath) {
      Write-Verbose "Expanded resource already exists: $destinationPath"
      return
    }

    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
      New-Item -Path $destinationPath -ItemType Directory -Force | Out-Null
    }

    foreach ($archive in $archives) {
      Expand-Archive -LiteralPath $archive.FullName -DestinationPath $destinationPath -Force
      Remove-Item -LiteralPath $archive.FullName -Force
    }
  }

  function Save-XWaysTemplateIndex {
    param(
      [Parameter(Mandatory = $true)][uri]$Uri,
      [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $response = Invoke-WebRequest -Uri $Uri -ErrorAction Stop
    $links = @($response.Links | Where-Object { $_.href -match '\.(tpl|zip)$' })

    foreach ($link in $links) {
      $downloadUri = [uri]::new($Uri, $link.href)
      Save-XWaysDownload -Uri $downloadUri -DestinationDirectory $DestinationDirectory | Out-Null
    }

    return $links.Count
  }

  function Expand-XWaysTemplateArchives {
    param([Parameter(Mandatory = $true)][string]$DestinationDirectory)

    $archives = Get-ChildItem -LiteralPath $DestinationDirectory -Filter '*.zip' -File -ErrorAction SilentlyContinue
    foreach ($archive in $archives) {
      Expand-Archive -LiteralPath $archive.FullName -DestinationPath $DestinationDirectory -Force
      Remove-Item -LiteralPath $archive.FullName -Force
    }
  }

  $previousProgressPreference = $ProgressPreference
  $ProgressPreference = 'SilentlyContinue'
  $xWaysRootPath = $null

  try {
    $credentialFilePath = $CredentialPath.FullName
    $xWaysRootPath = Resolve-XWaysProviderPath -Path $XWaysRoot

    if (-not (Test-Path -LiteralPath $xWaysRootPath -PathType Container)) {
      throw "X-Ways root folder does not exist: $xWaysRootPath"
    }

    if ($PSBoundParameters.ContainsKey('XWScriptsAndTemplatesFolder')) {
      $templatesPath = Resolve-XWaysProviderPath -Path $XWScriptsAndTemplatesFolder
    }
    else {
      $templatesPath = [IO.Path]::GetFullPath((Join-Path -Path $xWaysRootPath -ChildPath '..\XWScriptsAndTemplates'))
    }

    if ($ResetCredentials -and (Test-Path -LiteralPath $credentialFilePath)) {
      if ($PSCmdlet.ShouldProcess($credentialFilePath, 'Remove stored X-Ways credential')) {
        Remove-Item -LiteralPath $credentialFilePath -Force
      }
    }

    $resources = @(
      [pscustomobject]@{ Name = 'Excire'; Uri = [uri]'https://www.x-ways.net/res/Excire%20for%20v21.1%20and%20later.zip'; ArchivePrefix = 'Excire'; DestinationName = 'Excire'; ExpandArchive = $true }
      [pscustomobject]@{ Name = 'Conditional Coloring'; Uri = [uri]'https://x-ways.net/res/conditional%20coloring/Conditional%20Coloring.cfg'; ArchivePrefix = $null; DestinationName = $null; ExpandArchive = $false }
      [pscustomobject]@{ Name = 'AFF4 X-Tension'; Uri = [uri]'https://www.x-ways.net/res/aff4-xways-2.1.1.zip'; ArchivePrefix = 'aff4'; DestinationName = 'aff4'; ExpandArchive = $true }
    )

    $resourceFilesDownloaded = $false
    if ($PSCmdlet.ShouldProcess($xWaysRootPath, 'Download X-Ways resource files')) {
      $xWaysCredential = Get-XWaysResourceCredential -Credential $Credential -Path $credentialFilePath
      $headers = New-XWaysBasicAuthHeader -Credential $xWaysCredential
      $resourceUris = foreach ($resource in $resources) {
        if ($resource.ExpandArchive -and $resource.DestinationName) {
          $resourceDestinationPath = Join-Path -Path $xWaysRootPath -ChildPath $resource.DestinationName
          if (Test-XWaysDirectoryHasItems -Path $resourceDestinationPath) {
            Write-Verbose "Expanded resource already exists: $resourceDestinationPath"
            continue
          }
        }

        $resource.Uri
      }

      if ($resourceUris) {
        Save-XWaysDownload -Uri $resourceUris -DestinationDirectory $xWaysRootPath -Headers $headers
      }
      else {
        Write-Verbose 'All X-Ways resource files are already present.'
      }

      $resourceFilesDownloaded = $true
    }

    foreach ($resource in $resources | Where-Object { $_.ExpandArchive }) {
      if ($PSCmdlet.ShouldProcess($xWaysRootPath, "Expand $($resource.Name) archive")) {
        Expand-XWaysArchive -RootPath $xWaysRootPath -ArchivePrefix $resource.ArchivePrefix -DestinationName $resource.DestinationName
      }
    }

    $templateDownloadCount = 0
    if ($GetTemplates) {
      if ($PSCmdlet.ShouldProcess($templatesPath, 'Create X-Ways scripts and templates folder')) {
        New-Item -Path $templatesPath -ItemType Directory -Force | Out-Null
      }

      $templateSources = @(
        [pscustomobject]@{ Kind = 'Index'; Uri = [uri]'https://res.jens-training.com/templates/' }
        [pscustomobject]@{ Kind = 'Archive'; Uri = [uri]'https://github.com/kacos2000/WinHex_Templates/archive/refs/heads/master.zip' }
        [pscustomobject]@{ Kind = 'Index'; Uri = [uri]'https://x-ways.net/winhex/templates/' }
      )

      foreach ($source in $templateSources) {
        if (-not $PSCmdlet.ShouldProcess($templatesPath, "Download templates from $($source.Uri)")) {
          continue
        }

        if ($source.Kind -eq 'Archive') {
          Save-XWaysDownload -Uri $source.Uri -DestinationDirectory $templatesPath
          $templateDownloadCount++
          continue
        }

        $templateDownloadCount += Save-XWaysTemplateIndex -Uri $source.Uri -DestinationDirectory $templatesPath
      }

      if ($PSCmdlet.ShouldProcess($templatesPath, 'Expand downloaded template archives')) {
        Expand-XWaysTemplateArchives -DestinationDirectory $templatesPath
      }
    }

    [pscustomobject]@{
      XWaysRoot                 = $xWaysRootPath
      ScriptsAndTemplatesFolder = if ($GetTemplates) {
        $templatesPath 
      }
      else {
        $null 
      }
      ResourceFilesDownloaded   = $resourceFilesDownloaded
      TemplateFilesDownloaded   = $templateDownloadCount
      CredentialPath            = $credentialFilePath
    }
  }
  catch {
    $PSCmdlet.ThrowTerminatingError($_)
  }
  finally {
    if ($xWaysRootPath -and (Test-Path -LiteralPath $xWaysRootPath -PathType Container)) {
      $ariaFiles = Get-ChildItem -LiteralPath $xWaysRootPath -Filter '*aria2*' -File -ErrorAction SilentlyContinue
      foreach ($ariaFile in $ariaFiles) {
        if ($PSCmdlet.ShouldProcess($ariaFile.FullName, 'Remove aria2 metadata file')) {
          Remove-Item -LiteralPath $ariaFile.FullName -Force -ErrorAction SilentlyContinue
        }
      }
    }

    $ProgressPreference = $previousProgressPreference
  }
}
