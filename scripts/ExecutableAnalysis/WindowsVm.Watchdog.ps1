# Independent trusted host deadline. Never executes a supplied analysis target.
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$')][string]$VirtualMachineId,
    [Parameter(Mandatory)][string]$OwnershipManifestPath,
    [Parameter(Mandatory)][ValidateRange(1,2100)][int]$DeadlineSeconds,
    [Parameter(Mandatory)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'WindowsVm.Common.ps1')

function Invoke-AnalysisWindowsWatchdog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{8}-(?:[a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$')][string]$VirtualMachineId,
        [Parameter(Mandatory)][string]$OwnershipManifestPath,
        [Parameter(Mandatory)][ValidateRange(1,2100)][int]$DeadlineSeconds,
        [Parameter(Mandatory)][string]$EvidenceDirectory
    )
    $ErrorActionPreference='Stop'
    function Assert-WatchdogRegularPath([string]$Path) {
        $cursor=[IO.Path]::GetFullPath($Path)
        while($cursor){
            if(Test-Path -LiteralPath $cursor){
                $item=Get-Item -LiteralPath $cursor -Force
                if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Watchdog paths cannot traverse reparse points.'}
            }
            $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
        }
    }
    function Write-WatchdogRecord([string]$Name,[object]$Value) {
        $path=Join-Path $evidence $Name;Assert-WatchdogRegularPath $path
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 8))
        $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    }
    $manifestPath=[IO.Path]::GetFullPath($OwnershipManifestPath)
    $evidence=[IO.Path]::GetFullPath($EvidenceDirectory)
    Assert-WatchdogRegularPath $manifestPath;Assert-WatchdogRegularPath $evidence
    if(Test-Path -LiteralPath $evidence){throw 'Watchdog evidence must be a new directory.'}
    $manifestFile=Get-Item -LiteralPath $manifestPath
    if($manifestFile.PSIsContainer -or $manifestFile.Length -gt 1MB){throw 'The watchdog ownership manifest must be a bounded regular file.'}
    $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.Status -ne 'Ready' -or $manifest.VirtualMachineId -ine $VirtualMachineId -or $manifest.VirtualMachineName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'){throw 'The watchdog requires the exact ready owned VM identity.'}
    $storage=[IO.Path]::GetFullPath($manifest.StoragePath).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    Assert-WatchdogRegularPath $storage
    if(-not $manifestPath.StartsWith($storage,[StringComparison]::OrdinalIgnoreCase)){throw 'The watchdog manifest is outside its owned storage.'}
    $null=[IO.Directory]::CreateDirectory($evidence);Assert-WatchdogRegularPath $evidence
    $runId=[guid]::NewGuid().ToString('N');$timer=$null
    $record=[ordered]@{Schema='PowerShellProfile.WindowsVmWatchdog.v1';Status='Failed';BoundUUID=$VirtualMachineId;VirtualMachineName=$manifest.VirtualMachineName;WatchdogId=$runId;PID=$PID;DeadlineSeconds=$DeadlineSeconds;StartedUtc=$null;FinishedUtc=$null;ElapsedSeconds=$null;PowerOffAttempted=$false;PowerOffVerified=$false;CancellationRejected=$false;Error=$null;Limitations=@('The deadline begins before ready.json. At expiry, identity validation, power-off and verification each have a 15-second command limit; VM shutdown is not instantaneous.','The watchdog never restores snapshots, deletes VMs or acts on another UUID.')}
    try{
        $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox -ArgumentList @('showvminfo',$VirtualMachineId,'--machinereadable') -TimeoutSeconds 15 -MaxOutputCharacters 1048576)
        Assert-AnalysisWindowsVmIsolation $settings $manifest
        if($settings.VMState -notin 'running','paused','poweroff'){throw 'The watchdog refuses an unexpected initial VM state.'}
        $ownership=Invoke-AnalysisWindowsVBox -ArgumentList @('getextradata',$VirtualMachineId,'PowerShellProfile.AnalysisVm.Manifest') -TimeoutSeconds 15 -MaxOutputCharacters 16384
        if($ownership -notmatch '(?m)^Value: ([^\r\n]+)\r?$' -or [IO.Path]::GetFullPath($Matches[1].Trim()) -ine $manifestPath){throw 'The VM ownership link does not match the watchdog manifest.'}
        $timer=[Diagnostics.Stopwatch]::StartNew();$record.StartedUtc=[DateTime]::UtcNow.ToString('o')
        Write-WatchdogRecord 'ready.json' ([ordered]@{Schema=$record.Schema;Status='Ready';PID=$PID;BoundUUID=$VirtualMachineId;WatchdogId=$runId;StartedUtc=$record.StartedUtc;DeadlineSeconds=$DeadlineSeconds;DeadlineUtc=[DateTime]::UtcNow.AddSeconds($DeadlineSeconds).ToString('o')})
        $cancelPath=Join-Path $evidence 'cancel.json'
        while($timer.Elapsed.TotalSeconds -lt $DeadlineSeconds){
            if(Test-Path -LiteralPath $cancelPath){
                try{
                    Assert-WatchdogRegularPath $cancelPath;$cancelFile=Get-Item -LiteralPath $cancelPath
                    if($cancelFile.PSIsContainer -or $cancelFile.Length -gt 4096){throw 'Invalid cancellation marker.'}
                    # The caller publishes a complete marker atomically. Invalid,
                    # partial or cross-VM markers never disable the deadline.
                    $cancel=Get-Content -LiteralPath $cancelPath -Raw -Encoding UTF8|ConvertFrom-Json
                    if($cancel.Cancel -ne $true -or $cancel.BoundUUID -ine $VirtualMachineId -or $cancel.WatchdogId -cne $runId){throw 'Mismatched cancellation marker.'}
                    $record.Status='Cancelled';break
                }catch{$record.CancellationRejected=$true}
            }
            Start-Sleep -Milliseconds 200
        }
        if($record.Status -ne 'Cancelled'){
            Assert-WatchdogRegularPath $manifestPath
            if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $manifestHash){throw 'The watchdog ownership manifest changed before expiry.'}
            $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox -ArgumentList @('showvminfo',$VirtualMachineId,'--machinereadable') -TimeoutSeconds 15 -MaxOutputCharacters 1048576)
            Assert-AnalysisWindowsVmIsolation $settings $manifest
            if($settings.VMState -in 'running','paused'){
                $record.PowerOffAttempted=$true
                $null=Invoke-AnalysisWindowsVBox -ArgumentList @('controlvm',$VirtualMachineId,'poweroff') -TimeoutSeconds 15 -MaxOutputCharacters 16384
                $settings=ConvertFrom-AnalysisWindowsVmInfo (Invoke-AnalysisWindowsVBox -ArgumentList @('showvminfo',$VirtualMachineId,'--machinereadable') -TimeoutSeconds 15 -MaxOutputCharacters 1048576)
                Assert-AnalysisWindowsVmIsolation $settings $manifest
            }elseif($settings.VMState -ne 'poweroff'){throw 'The watchdog refuses an unexpected VM state at expiry.'}
            if($settings.VMState -ne 'poweroff'){throw 'The watchdog could not verify that its VM is powered off.'}
            $record.PowerOffVerified=$true;$record.Status='Expired'
        }
    }catch{$record.Status='Failed';$record.Error=$_.Exception.Message}
    finally{
        $record.FinishedUtc=[DateTime]::UtcNow.ToString('o');if($timer){$record.ElapsedSeconds=$timer.Elapsed.TotalSeconds}
        Write-WatchdogRecord 'result.json' $record
    }
    [pscustomobject]$record
}

Invoke-AnalysisWindowsWatchdog @PSBoundParameters
