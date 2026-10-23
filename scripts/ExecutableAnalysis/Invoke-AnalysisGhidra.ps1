function Invoke-AnalysisGhidra {
    [CmdletBinding()]
    param([string]$InputPath,[string]$OutputDirectory,[string]$GhidraPath,[string]$AssetDirectory,[string]$LogDirectory,[int]$MaxFunctions=0,[int]$TimeoutSeconds=1800)
    $java=Get-Command java -CommandType Application -ErrorAction Ignore|Select-Object -First 1
    if(-not $java){return [pscustomobject]@{Status='Unavailable';Reason='Ghidra requires a compatible Java JDK.'}}
    $vm=Invoke-AnalysisTool $java.Source @('-cp',(Join-Path $GhidraPath 'support/LaunchSupport.jar'),'LaunchSupport',$GhidraPath,'-vmargs') -LogPath (Join-Path $LogDirectory 'ghidra-vmargs') -WorkingDirectory $LogDirectory -TimeoutSeconds 30
    if($vm.Status -ne 'Completed'){return [pscustomobject]@{Status='Failed';Reason='Ghidra launch configuration failed.';Process=$vm}}
    $project=Join-Path $LogDirectory 'ghidra-project'
    $userDirectory=Join-Path $LogDirectory 'ghidra-user'
    $tempDirectory=Join-Path $LogDirectory 'ghidra-temp'
    foreach($directory in @($project,$userDirectory,$tempDirectory)){$null=[IO.Directory]::CreateDirectory($directory)}
    $arguments=@([IO.File]::ReadAllLines($vm.StandardOutputPath)|Where-Object {$_})
    $arguments+=@('-Xmx2G','-Djava.awt.headless=true',('-Duser.home='+$userDirectory),('-Djava.io.tmpdir='+$tempDirectory),'-cp',(Join-Path $GhidraPath 'Ghidra/Framework/Utility/lib/Utility.jar'),'ghidra.Ghidra','ghidra.app.util.headless.AnalyzeHeadless',$project,'ProfileAnalysis','-import',$InputPath,'-readOnly','-scriptPath',$AssetDirectory,'-postScript','ExportProgram.java',$OutputDirectory,[string]$MaxFunctions,'60',[string]$TimeoutSeconds,'-analysisTimeoutPerFile',[string]$TimeoutSeconds,'-log',(Join-Path $LogDirectory 'ghidra-analysis.log'),'-scriptlog',(Join-Path $LogDirectory 'ghidra-export.log'))
    $result=Invoke-AnalysisTool $java.Source $arguments -LogPath (Join-Path $LogDirectory 'ghidra') -WorkingDirectory $LogDirectory -TimeoutSeconds ($TimeoutSeconds+30)
    $manifest=Join-Path $OutputDirectory 'ghidra-result.json'
    if($result.Status -eq 'Completed' -and (Test-Path -LiteralPath $manifest)){
        $record=Get-Content -LiteralPath $manifest -Raw|ConvertFrom-Json
        return [pscustomobject]@{Status=$record.Status;Manifest=$record;Process=$result}
    }
    [pscustomobject]@{Status='Failed';Reason='Ghidra did not produce a verified completed manifest.';Process=$result}
}
