function Invoke-AnalysisFirmware {
    <#
    .SYNOPSIS
    Statically extracts Dell PFS components, UEFI sections and HII forms.
    .DESCRIPTION
    Runs only explicitly configured analysis tools. Neither the input installer
    nor extracted programs are executed. OutputDirectory must not exist. Output
    growth is monitored; the byte budget is a stop threshold, not a disk quota.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][hashtable]$Tools,
        [Parameter(Mandatory)][string]$LogDirectory,
        [ValidateRange(5,86400)][int]$TimeoutSeconds=600,
        [ValidateRange(1048576,17179869184)][long]$MaxOutputBytes=1GB,
        [ValidateRange(1,1000000)][int]$MaxFiles=30000,
        [ValidateRange(1,4096)][int]$MaxIFRModules=1024,
        [ValidateRange(268435456,17179869184)][long]$MaxMemoryBytes=2GB
    )
    $ErrorActionPreference='Stop'
    $source=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
    $output=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    $logs=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogDirectory)
    foreach($path in @($source,$output,$logs)){
        $cursor=$path
        while($cursor){
            if(Test-Path -LiteralPath $cursor){
                if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Firmware analysis rejects reparse points: $cursor"}
            }
            $cursor=[IO.Path]::GetDirectoryName($cursor)
        }
    }
    if(-not(Test-Path -LiteralPath $source -PathType Leaf)){throw 'Firmware input must be one regular file.'}
    if(Test-Path -LiteralPath $output){throw 'Firmware OutputDirectory must not exist.'}
    if($logs.Equals($output,[StringComparison]::OrdinalIgnoreCase) -or $logs.StartsWith($output+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Firmware LogDirectory must be outside OutputDirectory.'}
    $resolved=@{}
    foreach($name in @('Python','BIOSUtilities','UEFIExtract','IFRExtractor')){
        if(-not $Tools[$name]){return [pscustomobject]@{Status='Unavailable';Reason="Firmware tool is unavailable: $name";TargetExecuted=$false}}
        $resolved[$name]=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$Tools[$name])
        $kind=if($name -eq 'BIOSUtilities'){'Container'}else{'Leaf'}
        if(-not(Test-Path -LiteralPath $resolved[$name] -PathType $kind)){return [pscustomobject]@{Status='Unavailable';Reason="Firmware tool path is unavailable: $name";TargetExecuted=$false}}
    }
    $before=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    foreach($name in @('Python','UEFIExtract','IFRExtractor')){
        $cursor=$resolved[$name]
        while($cursor){
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Firmware tool uses a reparse point: $name"}
            $cursor=[IO.Path]::GetDirectoryName($cursor)
        }
        if((Get-FileHash -LiteralPath $resolved[$name] -Algorithm SHA256).Hash -eq $before){throw "Input content cannot be used as a firmware analysis tool: $name"}
    }
    $null=[IO.Directory]::CreateDirectory($logs)
    $worker=Join-Path $PSScriptRoot 'firmware-worker.py'
    $arguments=@('-B',$worker,'--input',$source,'--output',$output,'--bios-utilities',$resolved.BIOSUtilities,'--uefi-extract',$resolved.UEFIExtract,'--ifr-extractor',$resolved.IFRExtractor,'--expected-sha256',$before,'--timeout',[string]([Math]::Max(1,$TimeoutSeconds-3)),'--max-output-bytes',[string]$MaxOutputBytes,'--max-files',[string]$MaxFiles,'--max-ifr-modules',[string]$MaxIFRModules,'--max-memory-bytes',[string]$MaxMemoryBytes)
    if($Tools.PythonDependencies){
        $dependencies=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$Tools.PythonDependencies)
        if(-not(Test-Path -LiteralPath $dependencies -PathType Container)){throw 'Firmware PythonDependencies directory is unavailable.'}
        $arguments=@('-I','-S')+$arguments+@('--python-dependencies',$dependencies)
    }
    $process=$null
    $failure=$null
    try{
        $process=Invoke-AnalysisTool -FilePath $resolved.Python -ArgumentList $arguments -LogPath (Join-Path $logs ('firmware-'+[Guid]::NewGuid().ToString('N'))) -WorkingDirectory $logs -TimeoutSeconds $TimeoutSeconds -MaxLogBytes 16MB -Environment @{PYTHONDONTWRITEBYTECODE='1';PYTHONNOUSERSITE='1'}
    }catch{$failure=$_.Exception.Message}
    $after=$null
    try{$after=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash}catch{$failure='Input could not be hashed after analysis: '+$_.Exception.Message}
    $manifestPath=Join-Path $output 'firmware-result.json'
    $manifest=$null
    if(Test-Path -LiteralPath $manifestPath -PathType Leaf){
        try{$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json}catch{$failure='Firmware manifest is invalid: '+$_.Exception.Message}
    }
    if($manifest -and $process){
        $status=Get-AnalysisProviderStatus -Process $process -Manifest $manifest -ExpectedSHA256 $before
        if($after -ne $before -or $manifest.TargetExecuted -ne $false){$status='Failed'}
        return [pscustomobject]@{Status=$status;Manifest=$manifest;ManifestPath=$manifestPath;Process=$process;TargetExecuted=$false;InputUnchanged=($after -eq $before);Reason=$failure;MenuSummaryPath=$manifest.MenuSummaryPath;NumericValidationPath=$manifest.NumericValidationPath;FormNavigationPath=$manifest.FormNavigationPath;FormPackageTextPaths=@($manifest.FormPackageTextPaths)}
    }
    # A killed worker may not reach its finalizer. Preserve that evidence gap and
    # the independently verified input hash without inventing an inventory.
    if(-not $failure){$failure='Firmware worker did not produce a verified manifest.'}
    $manifest=[ordered]@{SchemaVersion=1;Status='Failed';InputPath=$source;InputSHA256Before=$before;InputSHA256After=$after;InputUnchanged=($after -eq $before);TargetExecuted=$false;Files=@();Variants=@();Tools=@();Diagnostics=@($failure);Limitations=@('Worker completion and artifact inventory were not verified.');Summary=@{InventoryComplete=$false};Process=$process}
    if(-not(Test-Path -LiteralPath $output)){$null=[IO.Directory]::CreateDirectory($output)}
    # Recheck the exact directory before writing the fallback manifest.
    if((Get-Item -LiteralPath $output -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Firmware output became a reparse point.'}
    if(-not(Test-Path -LiteralPath $manifestPath)){
        [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    }
    [pscustomobject]@{Status='Failed';Manifest=[pscustomobject]$manifest;ManifestPath=$manifestPath;Process=$process;TargetExecuted=$false;InputUnchanged=($after -eq $before);Reason=$failure}
}
