#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$TestRoot=[IO.Path]::GetFullPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new fixture directory.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$repo=Split-Path $PSScriptRoot -Parent
$assets=Join-Path $repo 'scripts/ExecutableAnalysis'
. (Join-Path $assets 'Invoke-AnalysisTool.ps1')
$node=Get-Command node -CommandType Application -ErrorAction Stop|Select-Object -First 1
$bridge=Join-Path $assets 'rea-bridge.mjs'
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}

# A fixture-owned protocol peer, not a real REA/provider installation. No network,
# downloads, target execution, JVM, MCP registration or user settings are involved.
$mock=@'
import readline from 'node:readline';
import fs from 'node:fs/promises';
import path from 'node:path';
const mode=process.env.REA_BRIDGE_TEST_MODE;
const send=(id,result)=>process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\n');
const names=['binary_session','open_binary','binary_overview','list_procedures','list_strings','procedure_pseudo_code','inspect_go_binary','inspect_rust_binary','inspect_pe_resources','inspect_artifact','extract_artifact','export_evidence_bundle','close_binary'];
for await(const line of readline.createInterface({input:process.stdin})) {
 const request=JSON.parse(line); if(request.id===undefined)continue;
 if(request.method==='initialize'){send(request.id,{protocolVersion:'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'rea',version:mode==='version'?'0.0.0':'6.7.0'}});continue;}
 if(request.method==='tools/list'){send(request.id,{tools:names.map(name=>({name,inputSchema:{type:'object'}}))});continue;}
 if(request.method!=='tools/call')continue;
 const {name,arguments:args}=request.params;
 if(mode==='timeout'&&name==='open_binary'){await new Promise(resolve=>setTimeout(resolve,1500));continue;}
 if(mode==='mutation'&&name==='open_binary')await fs.appendFile(args.path,Buffer.from('changed by fixture provider'));
 if(name==='list_strings'&&mode==='json'){process.stdout.write('malformed JSON\n');continue;}
 if(name==='list_strings'&&mode==='utf8'){
  process.stdout.write(Buffer.concat([Buffer.from('{"jsonrpc":"2.0","id":'+request.id+',"result":{"text":"'),Buffer.from([0xff]),Buffer.from('"}}\n')]));continue;
 }
 if(name==='list_strings'&&mode==='failure'){send(request.id,{isError:true,structuredContent:{error:{message:'Owned fixture provider failure'}}});continue;}
 if(name==='export_evidence_bundle'&&mode!=='missingexport')await fs.writeFile(args.path,mode==='oversizedexport'?'A'.repeat(100000):'{"schema_version":1,"records":[]}\n',{flag:'wx'});
 let normalized_result=name==='list_procedures'?[{address:'0x1000',value:'$(NeverExecuteThis)',procedure:{external:false}},{address:'0x2000',value:'second',procedure:{external:false}}]:name==='procedure_pseudo_code'?'int fixture(void) { return 42; }':name==='open_binary'?{ReceivedPath:args.path}:{};
 if(mode==='limit'&&name==='list_strings')normalized_result='A'.repeat(12000);
 if(mode==='extraction'&&name==='extract_artifact')normalized_result={output_root:path.join(process.cwd(),'fixture-missing-extraction')};
 send(request.id,{structuredContent:{normalized_result,evidence_id:name,limitations:[]},content:[]});
}
'@
$mockPath=Join-Path $TestRoot 'mock-rea.mjs'
[IO.File]::WriteAllText($mockPath,$mock,[Text.UTF8Encoding]::new($false))

function Invoke-BridgeCase([string]$Mode) {
    $run=Join-Path $TestRoot $Mode
    $null=[IO.Directory]::CreateDirectory($run)
    $source=Join-Path $run 'native & $(NeverExecuteThis) %PATH% [fixture].exe'
    [IO.File]::WriteAllBytes($source,([byte[]](0x4d,0x5a,1,2,3,4)))
    $output=Join-Path $run 'output'
    $null=[IO.Directory]::CreateDirectory($output)
    $configuration=@{
        reaScript=$mockPath;inputPath=$source;outputDirectory=$output
        format=if($Mode -eq 'extraction'){'archive'}else{'native'}
        # The first Node launch can be slow on a cold Windows CI runner. Keep
        # the deliberate timeout case strict without timing ordinary startup.
        timeoutSeconds=if($Mode -eq 'timeout'){1}else{10};totalTimeoutSeconds=60
        maxFunctions=if($Mode -eq 'functionlimit'){1}else{0}
        maxEvidenceBytes=if($Mode -eq 'limit'){4096}else{67108864}
        maxTotalEvidenceBytes=if($Mode -eq 'oversizedexport'){65536}else{1073741824}
    }
    $configPath=Join-Path $run 'config.json'
    $configuration|ConvertTo-Json|Set-Content -LiteralPath $configPath -Encoding utf8
    $process=Invoke-AnalysisTool $node.Source @($bridge,$configPath) -LogPath (Join-Path $run 'process') -WorkingDirectory $run -TimeoutSeconds 90 -Environment @{REA_BRIDGE_TEST_MODE=$Mode}
    $manifestPath=Join-Path $output 'rea-result.json'
    if(-not(Test-Path -LiteralPath $manifestPath)){
        $process|Select-Object Status,ExitCode,Seconds|ConvertTo-Json -Compress|Write-Host
        foreach($diagnostic in @($process.StandardOutputPath,$process.StandardErrorPath)){
            if(Test-Path -LiteralPath $diagnostic){Get-Content -LiteralPath $diagnostic -Tail 15|ForEach-Object{Write-Host ($_.Substring(0,[Math]::Min(400,$_.Length)))}}
        }
    }
    Assert (Test-Path -LiteralPath $manifestPath) "Case $Mode did not preserve a manifest; process: $($process.Status)"
    $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
    [pscustomobject]@{Record=$manifest;Source=$source;Output=$output;Process=$process}
}

$control=Invoke-BridgeCase 'control'
Assert ($control.Record.Status -eq 'Succeeded' -and $control.Process.Status -eq 'Completed') 'Control analysis failed'
Assert ($control.Record.InputUnchanged -and $control.Record.TargetExecuted -eq $false) 'Source identity or execution boundary was lost'
Assert ($control.Record.Coverage.Complete -and $control.Record.Coverage.DecompiledFunctions -eq 2) 'Control did not recover both fixture functions'
$openStage=$control.Record.Stages|Where-Object Tool -eq 'open_binary'
$openRecord=Get-Content -LiteralPath (Join-Path $control.Output $openStage.EvidencePath) -Raw|ConvertFrom-Json
Assert ($openRecord.structuredContent.normalized_result.ReceivedPath -ceq $control.Source) 'A metacharacter path lost its exact argument boundary'
Assert ($control.Record.Cleanup -eq 'ProviderClosed') 'Control provider did not close'
Assert (-not(Test-Path -LiteralPath (Join-Path $TestRoot 'NeverExecuteThis'))) 'Target-derived content became a command'
Write-Host 'PASS: one owned protocol session, complete fixture coverage, literal metacharacter path, untrusted symbol data and provider close'

$limited=Invoke-BridgeCase 'functionlimit'
Assert ($limited.Record.Status -eq 'Partial' -and -not $limited.Record.Coverage.Complete) 'Function limit was reported as complete'
Assert ($limited.Record.Coverage.DiscoveredFunctions -eq 2 -and $limited.Record.Coverage.AttemptedFunctions -eq 1) 'Function coverage counts were lost'
$oversized=Invoke-BridgeCase 'limit'
Assert ($oversized.Record.Status -eq 'Partial') 'Oversized evidence was reported as success'
$failure=$oversized.Record.Stages|Where-Object Name -eq 'list_strings'
Assert ($failure.Status -eq 'Failed' -and $failure.Error -match 'retention limit') 'Oversized evidence did not preserve its exact failure'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $oversized.Output 'rea-raw') -File|Where-Object Length -gt 4096).Count -eq 0) 'Oversized raw evidence was saved as complete'
Write-Host 'PASS: function and evidence limits produce explicit partial coverage'

$timeout=Invoke-BridgeCase 'timeout'
Assert ($timeout.Record.Status -eq 'Partial' -and -not $timeout.Record.Coverage.Complete) 'Timeout was reported as complete'
Assert (@($timeout.Record.Stages|Where-Object { $_.Status -eq 'Failed' -and $_.Error -match 'exceeded 1000 ms' }).Count -eq 1) 'Timeout failure was not retained'
$failed=Invoke-BridgeCase 'failure'
Assert ($failed.Record.Status -eq 'Partial') 'Provider error was reported as success'
Assert (@($failed.Record.Stages|Where-Object { $_.Error -match 'Owned fixture provider failure' }).Count -eq 1) 'Provider error text was lost'
Write-Host 'PASS: timeouts and provider failures retain errors and avoid false completeness'

foreach($mode in 'json','utf8') {
    $invalid=Invoke-BridgeCase $mode
    Assert ($invalid.Record.Status -ne 'Succeeded' -and -not $invalid.Record.Coverage.Complete) "Malformed $mode response was accepted"
    $expected=if($mode -eq 'json'){'invalid JSON-RPC'}else{'invalid UTF-8'}
    Assert (@($invalid.Record.Stages|Where-Object { $_.Error -match $expected }).Count -gt 0) "Malformed $mode response lacked its diagnostic"
}
Write-Host 'PASS: malformed JSON and malformed UTF-8 cannot become valid evidence'

$mutated=Invoke-BridgeCase 'mutation'
Assert ($mutated.Record.Status -eq 'Failed' -and $mutated.Process.Status -eq 'Failed') 'Source mutation did not fail analysis'
Assert (-not $mutated.Record.InputUnchanged -and $mutated.Record.Error -match 'SHA-256 changed') 'Source mutation identity check was lost'
$version=Invoke-BridgeCase 'version'
Assert ($version.Record.Status -eq 'Failed' -and $version.Record.Error -match 'another version') 'Unvalidated REA version was accepted'
Write-Host 'PASS: source mutation and incompatible provider version fail explicitly'

$extraction=Invoke-BridgeCase 'extraction'
Assert ($extraction.Record.Status -eq 'Partial') 'Failed retained extraction was reported as success'
$copyStage=$extraction.Record.Stages|Where-Object Name -eq 'retain_extracted_files'
Assert ($copyStage.Status -eq 'Failed' -and $copyStage.Error) 'Extraction-copy failure lacked a failed stage'
Write-Host 'PASS: extraction-copy failures remain partial even when the provider extraction call succeeded'

foreach($mode in 'missingexport','oversizedexport') {
    $export=Invoke-BridgeCase $mode
    Assert ($export.Record.Status -eq 'Partial') "Unverified $mode was reported as success"
    $verification=$export.Record.Stages|Where-Object Name -eq 'verify_evidence_export'
    Assert ($verification.Status -eq 'Failed' -and $verification.Error) "Unverified $mode lacked a failed verification stage"
}
Write-Host 'PASS: missing and oversized evidence exports cannot silently pass verification'
