function Get-FFmpeg {
    <#
    .SYNOPSIS
    Installs a verified FFmpeg executable from a Windows static-build ZIP.
    .DESCRIPTION
    Defaults to Gyan's release essentials ZIP. LocalDependencies uses
    LocalPath/ffmpeg/bin/ffmpeg.exe; otherwise DestinationPath or a per-user tools
    directory is used. The extracted executable must report an FFmpeg version.
    Custom URLs must supply a ZIP containing exactly one bin/ffmpeg.exe.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [string]$Url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
        [string]$DestinationPath,
        [switch]$LocalDependencies,
        [string]$LocalPath = $PWD,
        [switch]$Force,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 600
    )
    $ErrorActionPreference = 'Stop'
    if ($LocalDependencies) { $DestinationPath = Join-Path $LocalPath 'ffmpeg/bin/ffmpeg.exe' }
    elseif (-not $DestinationPath) { $DestinationPath = Join-Path $env:LOCALAPPDATA 'PowerShellProfile/Tools/ffmpeg/bin/ffmpeg.exe' }
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath)
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) {
        $loader = Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1'
        if (Test-Path -LiteralPath $loader) { . $loader }
        else { . ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Initialize-CmdletDependencies.ps1' -ErrorAction Stop))) }
    }
    Initialize-CmdletDependencies -RequiredCmdlets @('Get-FileDownload','Extract-ZipFile','Invoke-Process') -PreferLocal -ErrorAction Stop
    function Assert-FFmpeg([string]$Path) {
        $version = Invoke-Process -FilePath $Path -ArgumentList @('-version') -PassThru -TimeoutSeconds 15
        if ($version.StandardOutput -notmatch '^ffmpeg version ') { throw 'Executable did not report an FFmpeg version.' }
    }
    if ([IO.File]::Exists($destination) -and -not $Force) { Assert-FFmpeg $destination; return $destination }
    if (([uri]$Url).AbsolutePath -notmatch '\.zip$') { throw 'Use a Windows static-build ZIP URL; .7z archives are not supported by this installer.' }
    if (-not $PSCmdlet.ShouldProcess($destination, 'Download, extract and verify FFmpeg')) { return }
    $parent = [IO.Path]::GetDirectoryName($destination)
    $null = [IO.Directory]::CreateDirectory($parent)
    $stage = [IO.Path]::Combine($parent, '.ffmpeg-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($stage)
    try {
        $zip = Get-FileDownload -URL $Url -DestinationDirectory $stage -FileName ffmpeg.zip -ForceNativeDownload -TimeoutSeconds $TimeoutSeconds -Confirm:$false
        $expanded = [IO.Path]::Combine($stage, 'expanded')
        Extract-ZipFile -zipFilePath $zip -outputFolderPath $expanded -Confirm:$false
        $binaries = @(Get-ChildItem -LiteralPath $expanded -Filter ffmpeg.exe -Recurse -File | Where-Object { $_.Directory.Name -eq 'bin' })
        if ($binaries.Count -ne 1) { throw 'Archive must contain exactly one bin/ffmpeg.exe.' }
        if (@(Get-ChildItem -LiteralPath $binaries[0].DirectoryName -Filter '*.dll' -File).Count) { throw 'Use a static FFmpeg build; shared-build DLL installation is not supported.' }
        Assert-FFmpeg $binaries[0].FullName
        # Only a static-build executable is installed; shared builds need their DLLs.
        [IO.File]::Move($binaries[0].FullName, $destination, [bool]$Force)
        $destination
    }
    finally {
        $resolvedStage = [IO.Path]::GetFullPath($stage)
        if ([IO.Path]::GetDirectoryName($resolvedStage) -ne $parent -or [IO.Path]::GetFileName($resolvedStage) -notmatch '^\.ffmpeg-[a-f0-9]{32}$') { throw 'Invalid FFmpeg cleanup target.' }
        if ([IO.Directory]::Exists($resolvedStage)) { Remove-Item -LiteralPath $resolvedStage -Recurse -Force -ErrorAction Stop }
    }
}
