function Invoke-AnalysisGhidra {
    [CmdletBinding()]
    param([string]$InputPath,[string]$OutputDirectory,[string]$GhidraPath,[string]$AssetDirectory,[string]$LogDirectory,[int]$MaxFunctions=0,[ValidateRange(10,86370)][int]$TimeoutSeconds=1800,[string]$PdbPath,[string]$TerminalSitesPath)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $inputHash=(Get-FileHash -LiteralPath $InputPath -Algorithm SHA256).Hash
    $pdbHash=if($PdbPath){(Get-FileHash -LiteralPath $PdbPath -Algorithm SHA256).Hash}else{$null}
    $java=Get-Command java -CommandType Application -ErrorAction Ignore|Select-Object -First 1
    if(-not $java){return [pscustomobject]@{Status='Unavailable';Reason='Ghidra requires a compatible Java JDK.'}}
    $configurationSeconds=[Math]::Min(30,[Math]::Max(1,[int][Math]::Floor($TimeoutSeconds/10)))
    $vm=Invoke-AnalysisTool $java.Source @('-cp',(Join-Path $GhidraPath 'support/LaunchSupport.jar'),'LaunchSupport',$GhidraPath,'-vmargs') -LogPath (Join-Path $LogDirectory 'ghidra-vmargs') -WorkingDirectory $LogDirectory -TimeoutSeconds $configurationSeconds
    if($vm.Status -ne 'Completed'){return [pscustomobject]@{Status='Failed';Reason='Ghidra launch configuration failed.';Process=$vm}}
    $project=Join-Path $LogDirectory 'ghidra-project'
    $userDirectory=Join-Path $LogDirectory 'ghidra-user'
    $tempDirectory=Join-Path $LogDirectory 'ghidra-temp'
    foreach($directory in @($project,$userDirectory,$tempDirectory)){$null=[IO.Directory]::CreateDirectory($directory)}
    $remainingSeconds=[int][Math]::Floor($TimeoutSeconds-$timer.Elapsed.TotalSeconds)
    if($remainingSeconds -lt 3){return [pscustomobject]@{Status='Failed';Reason='Ghidra launch preparation exhausted the shared time budget.';Process=$vm}}
    # Auto-analysis and export must share the process deadline. Previously each
    # received the full budget, so a long analysis left almost no time to export.
    $overheadSeconds=[Math]::Min(60,[Math]::Max(1,[int][Math]::Ceiling($remainingSeconds/10)))
    $phaseSeconds=$remainingSeconds-$overheadSeconds
    $analysisSeconds=[Math]::Max(1,[int][Math]::Floor($phaseSeconds/2))
    $exportSeconds=[Math]::Max(1,$phaseSeconds-$analysisSeconds)
    $exportDeadline=[DateTimeOffset]::UtcNow.AddSeconds($remainingSeconds-[Math]::Min(5,$overheadSeconds)).ToUnixTimeMilliseconds()
    $budgets=[ordered]@{TotalSeconds=$TimeoutSeconds;ConfigurationTimeoutSeconds=$configurationSeconds;HeadlessTimeoutSeconds=$remainingSeconds;AutoAnalysisSeconds=$analysisSeconds;ExportSeconds=$exportSeconds;ImportAndFinalizationReserveSeconds=$overheadSeconds;ExportDeadlineUnixMilliseconds=$exportDeadline}
    $arguments=@([IO.File]::ReadAllLines($vm.StandardOutputPath)|Where-Object {$_})
    $arguments+=@('-Xmx2G','-Djava.awt.headless=true',('-Duser.home='+$userDirectory),('-Djava.io.tmpdir='+$tempDirectory),'-cp',(Join-Path $GhidraPath 'Ghidra/Framework/Utility/lib/Utility.jar'),'ghidra.Ghidra','ghidra.app.util.headless.AnalyzeHeadless',$project,'ProfileAnalysis','-import',$InputPath,'-readOnly','-scriptPath',$AssetDirectory,'-preScript','PrepareProgram.java',$(if($PdbPath){$PdbPath}else{'none'}),$(if($TerminalSitesPath){$TerminalSitesPath}else{'none'}),'-postScript','ExportProgram.java',$OutputDirectory,[string]$MaxFunctions,'60',[string]$exportSeconds,[string]$exportDeadline,'-analysisTimeoutPerFile',[string]$analysisSeconds,'-log',(Join-Path $LogDirectory 'ghidra-analysis.log'),'-scriptlog',(Join-Path $LogDirectory 'ghidra-export.log'))
    $result=Invoke-AnalysisTool $java.Source $arguments -LogPath (Join-Path $LogDirectory 'ghidra') -WorkingDirectory $LogDirectory -TimeoutSeconds $remainingSeconds
    $manifest=Join-Path $OutputDirectory 'ghidra-result.json'
    if(Test-Path -LiteralPath $manifest -PathType Leaf){
        try{$record=Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}
        catch{return [pscustomobject]@{Status='Failed';Reason='Ghidra produced an unreadable manifest; retained files remain unverified.';Process=$result;Budgets=$budgets}}
        $afterHash=(Get-FileHash -LiteralPath $InputPath -Algorithm SHA256).Hash
        if($record.ExecutableSHA256 -ne $inputHash -or $afterHash -ne $inputHash -or $record.Status -notin 'Succeeded','Partial','Failed' -or $null -eq $record.Coverage){
            return [pscustomobject]@{Status='Failed';Reason='Ghidra manifest identity/status or source preservation verification failed.';Process=$result;Budgets=$budgets}
        }
        $status=$record.Status
        if($PdbPath -and (Get-FileHash -LiteralPath $PdbPath -Algorithm SHA256).Hash -ne $pdbHash){return [pscustomobject]@{Status='Failed';Reason='Retained PDB changed during analysis.';Manifest=$record;Process=$result;Budgets=$budgets}}
        $pdbReason=$null
        if($PdbPath -and ($record.Pdb.Loaded -ne $true -or $record.Pdb.Preparation.Status -ne 'Matched' -or $record.Pdb.Preparation.IdentityMatched -ne $true -or $record.Pdb.Preparation.SHA256 -ne $pdbHash)){$pdbReason='The retained matching PDB was not applied with verified preparation identity/hash; see its preparation and analysis logs.';if($status -ne 'Failed'){$status='Partial'}}
        $validation=[ordered]@{ProviderReportedStatus=$record.Status;ProviderReportedCoverageComplete=$record.Coverage.Complete;ProcessCompleted=($result.Status -eq 'Completed');InputUnchanged=$true}
        # An interrupted process or incomplete/unknown auto-analysis cannot be
        # upgraded by a successful export of only the functions discovered so far.
        if($result.Status -notin 'Completed','Timeout'){$status='Failed'}
        elseif($status -ne 'Failed' -and ($result.Status -eq 'Timeout' -or $record.AutoAnalysis.TimedOut -isnot [bool] -or $record.AutoAnalysis.TimedOut)){$status='Partial'}
        if($status -ne 'Succeeded'){
            $record.Status=$status
            $record.Coverage|Add-Member -NotePropertyName Complete -NotePropertyValue $false -Force
        }
        return [pscustomobject]@{Status=$status;Reason=$pdbReason;Manifest=$record;RawManifestPath=$manifest;Validation=$validation;Process=$result;Budgets=$budgets;InputUnchanged=$true;InputSHA256Before=$inputHash;InputSHA256After=$afterHash;PdbUnchanged=if($PdbPath){$true}else{$null}}
    }
    [pscustomobject]@{Status='Failed';Reason='Ghidra did not produce a verified manifest. Any partial exports and logs were retained.';Process=$result;Budgets=$budgets}
}
