function Invoke-EverythingSearch {
    <#
    .SYNOPSIS
    Searches Everything without stopping unrelated Everything processes.
    .DESCRIPTION
    Without SearchInDirectory, queries the existing default/named instance.
    With SearchInDirectory and no InstanceName, starts a unique folder-indexing
    instance with separate settings, then stops only the process it started.
    Missing portable tools are installed into EverythingDirectory on invocation.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$EverythingDirectory=(Join-Path $env:LOCALAPPDATA 'PowerShellProfile/Tools/Everything'),
        [string]$EverythingCLI,
        [string]$EverythingPortableExe,
        [string]$SearchInDirectory,
        [string]$SearchTerm='*',
        [string]$EverythingCLIDownloadURL='https://www.voidtools.com/ES-1.1.0.38.x64.zip',
        [string]$EverythingPortableDownloadURL='https://www.voidtools.com/Everything-1.5.0.1424b.x64.zip',
        [string]$InstanceName,
        [ValidateRange(1,600)][int]$TimeoutSeconds=60
    )
    $ErrorActionPreference='Stop'
    if (-not (Get-Command Initialize-CmdletDependencies -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'Initialize-CmdletDependencies.ps1') }
    Initialize-CmdletDependencies -RequiredCmdlets @('Get-FileDownload','Extract-ZipFile','Invoke-Process') -PreferLocal -ErrorAction Stop
    $tools=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EverythingDirectory)
    if (-not $EverythingCLI) { $EverythingCLI=Join-Path $tools es.exe }
    if (-not $EverythingPortableExe) { $EverythingPortableExe=Join-Path $tools Everything.exe }
    $ownedInstance=[bool]$SearchInDirectory -and -not $InstanceName
    if ($SearchInDirectory) {
        $SearchInDirectory=(Get-Item -LiteralPath $SearchInDirectory -Force -ErrorAction Stop).FullName
        if (-not [IO.Directory]::Exists($SearchInDirectory)) { throw 'SearchInDirectory must be a directory.' }
    }
    foreach ($tool in @(
        @{Path=$EverythingCLI;URL=$EverythingCLIDownloadURL;Name='es.exe';Needed=$true},
        @{Path=$EverythingPortableExe;URL=$EverythingPortableDownloadURL;Name='Everything.exe';Needed=$ownedInstance}
    )) {
        if (-not $tool.Needed -or [IO.File]::Exists($tool.Path)) { continue }
        $directory=[IO.Path]::GetDirectoryName($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($tool.Path))
        $zip=Get-FileDownload -URL $tool.URL -DestinationDirectory $directory -ForceNativeDownload -Force -TimeoutSeconds $TimeoutSeconds
        Extract-ZipFile -zipFilePath $zip -outputFolderPath $directory -Force -ErrorAction Stop
        if (-not [IO.File]::Exists($tool.Path)) { throw "Portable archive did not supply $($tool.Name) at the requested path." }
    }
    $ownedProcess=$null; $instanceDirectory=$null
    # ES console output uses the active Windows code page. A UTF-8 export preserves filenames.
    $resultFile=Join-Path ([IO.Path]::GetTempPath()) ('ProfileSearch-'+[guid]::NewGuid().ToString('N')+'.txt')
    try {
        if ($ownedInstance) {
            $InstanceName='ProfileSearch-'+[guid]::NewGuid().ToString('N')
            $instanceDirectory=Join-Path $tools $InstanceName
            $null=[IO.Directory]::CreateDirectory($instanceDirectory)
            $config=Join-Path $instanceDirectory Everything.ini
            $settings=@('[Everything]','run_as_admin=0','alpha_instance=0','ipc=1','check_for_updates_on_startup=0','show_taskbar_notification_icon=0',
                'auto_include_fixed_volumes=0','auto_include_removable_volumes=0','ntfs_volume_guids=','ntfs_volume_includes=',
                'http_server_enabled=0','etp_server_enabled=0',('folders="'+$SearchInDirectory.Replace('\','\\')+'"'),
                'folder_monitor_changes=0',('db_location='+$instanceDirectory))
            [IO.File]::WriteAllLines($config,$settings,[Text.UTF8Encoding]::new($false))
            $ownedProcess=Start-Process -FilePath $EverythingPortableExe -ArgumentList @('-instance',$InstanceName,'-config',('"{0}"' -f $config),'-startup') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $instanceDirectory stdout.log) -RedirectStandardError (Join-Path $instanceDirectory stderr.log) -PassThru -ErrorAction Stop
        }
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $indexed=-not $ownedInstance
        do {
            if ($ownedProcess -and $ownedProcess.HasExited) { throw 'Owned Everything instance exited before the search.' }
            $arguments=@('-argv','-full-path','-timeout','1000','-export-txt',$resultFile,'-utf8-bom')
            if ($InstanceName) { $arguments+=@('-instance',$InstanceName) }
            if ($SearchInDirectory) { $arguments+=@('-path',$SearchInDirectory) }
            $arguments+=@('-search',$SearchTerm)
            if (-not $indexed) { $arguments=@('-argv','-instance',$InstanceName,'-reindex') }
            $result=Invoke-Process -FilePath $EverythingCLI -ArgumentList $arguments -PassThru -IgnoreExitCode -TimeoutSeconds ([Math]::Max(1,[int]($TimeoutSeconds-$timer.Elapsed.TotalSeconds)))
            if ($result.ExitCode -eq 0) {
                if (-not $indexed) { $indexed=$true; continue }
                break
            }
            if (-not $ownedInstance -or $result.ExitCode -notin 7,8 -or $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Everything search failed with exit code $($result.ExitCode)." }
            Start-Sleep -Milliseconds 100
        } while ($true)
        if (-not [IO.File]::Exists($resultFile)) { throw 'Everything did not produce its requested result file.' }
        [IO.File]::ReadAllLines($resultFile,[Text.Encoding]::UTF8) | Where-Object { $_.Length -gt 0 } | Sort-Object -Unique
    }
    finally {
        if ([IO.File]::Exists($resultFile)) { [IO.File]::Delete($resultFile) }
        if ($ownedProcess) {
            try {
                if (-not $ownedProcess.HasExited) { Stop-Process -Id $ownedProcess.Id -Force -ErrorAction Stop; $null=$ownedProcess.WaitForExit(5000) }
            } finally { $ownedProcess.Dispose() }
        }
        if ($instanceDirectory) {
            $resolved=[IO.Path]::GetFullPath($instanceDirectory)
            if ([IO.Path]::GetDirectoryName($resolved) -ne $tools -or [IO.Path]::GetFileName($resolved) -notmatch '^ProfileSearch-[a-f0-9]{32}$') { throw 'Invalid instance cleanup target.' }
            if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop }
        }
    }
}
