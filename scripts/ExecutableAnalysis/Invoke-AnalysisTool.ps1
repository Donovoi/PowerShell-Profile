function Get-AnalysisProviderStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Process,[Parameter(Mandatory)]$Manifest,[Parameter(Mandatory)][string]$ExpectedSHA256)
    if($Manifest.InputUnchanged -ne $true -or $Manifest.InputSHA256Before -ne $ExpectedSHA256 -or $Manifest.InputSHA256After -ne $ExpectedSHA256){return 'Failed'}
    if($Manifest.Status -notin 'Succeeded','Partial','Failed'){return 'Failed'}
    if($Manifest.Status -eq 'Failed'){return 'Failed'}
    if($Process.Status -ne 'Completed'){return 'Partial'}
    return $Manifest.Status
}

function Invoke-AnalysisTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateRange(1,86400)][int]$TimeoutSeconds = 600,
        [ValidateRange(1048576,1073741824)][long]$MaxLogBytes = 67108864,
        [AllowEmptyString()][string]$InputText,
        [hashtable]$Environment = @{}
    )
    if($IsWindows -and [IO.Path]::GetExtension($FilePath) -in '.cmd','.bat','.ps1') {
        throw 'Analysis tools must use a native executable, not a batch or PowerShell shim; shell forwarding does not preserve literal argument boundaries.'
    }
    # Stream large decompiler output to evidence files, rather than buffering it in memory.
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($item in $ArgumentList) { $info.ArgumentList.Add($item) }
    foreach ($key in $Environment.Keys) { $info.Environment[$key] = [string]$Environment[$key] }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if(-not ('PowerShellProfile.Analysis.BoundedEvidenceStream' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'BoundedEvidenceStream.cs') -ErrorAction Stop
    }
    $stdout = $null; $stderr = $null; $started = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $reason = $null
    $commandPath=$LogPath+'.command.json'
    $commandRecord=[ordered]@{StartedUtc=[DateTime]::UtcNow.ToString('o');FilePath=$FilePath;ArgumentList=$ArgumentList;WorkingDirectory=$WorkingDirectory;TimeoutSeconds=$TimeoutSeconds;MaxLogBytes=$MaxLogBytes;EnvironmentOverrides=$Environment;ExecutableSHA256=(Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash}
    $commandStream=[IO.File]::Open($commandPath,'CreateNew','Write','Read')
    try{$commandBytes=[Text.Encoding]::UTF8.GetBytes(($commandRecord|ConvertTo-Json -Depth 5));$commandStream.Write($commandBytes,0,$commandBytes.Length)}finally{$commandStream.Dispose()}
    try {
        $stdout = [IO.File]::Open($LogPath + '.stdout', 'CreateNew', 'Write', 'Read')
        $stderr = [IO.File]::Open($LogPath + '.stderr', 'CreateNew', 'Write', 'Read')
        $started = $process.Start()
        $budget=[PowerShellProfile.Analysis.EvidenceBudget]::new($MaxLogBytes)
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync([PowerShellProfile.Analysis.BoundedEvidenceStream]::new($stdout,$budget))
        $errTask = $process.StandardError.BaseStream.CopyToAsync([PowerShellProfile.Analysis.BoundedEvidenceStream]::new($stderr,$budget))
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $inputTask = $process.StandardInput.WriteAsync($InputText)
            if (-not $inputTask.Wait($TimeoutSeconds * 1000)) { throw [TimeoutException]::new('Child process did not consume its input before the deadline.') }
        }
        $process.StandardInput.Close()
        while (-not $process.WaitForExit(100)) {
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { $reason = 'Timeout'; break }
            if ($outTask.IsFaulted -or $errTask.IsFaulted) { $reason = 'OutputLimitOrWriteFailure'; break }
        }
        if ($reason -and -not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        foreach ($task in @($outTask,$errTask)) {
            try{if (-not $task.Wait(5000)) { $reason = 'OutputDrainTimeout'; break }}
            catch{if($_.Exception.ToString() -match 'byte budget exceeded'){$reason='OutputLimit'}else{$reason='OutputWriteFailure'}}
        }
        if ($stdout.Position + $stderr.Position -gt $MaxLogBytes) { $reason = 'OutputLimit' }
        [pscustomobject]@{
            ExitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
            Status = if ($reason) { $reason } elseif ($process.ExitCode -eq 0) { 'Completed' } else { 'Failed' }
            Seconds = [Math]::Round($timer.Elapsed.TotalSeconds,2)
            CommandRecordPath = $commandPath
            StandardOutputPath = $LogPath + '.stdout'
            StandardErrorPath = $LogPath + '.stderr'
        }
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        if ($stdout) { $stdout.Dispose() }; if ($stderr) { $stderr.Dispose() }
        $process.Dispose()
    }
}
