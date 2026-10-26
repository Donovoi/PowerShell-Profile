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
import { createHash } from 'node:crypto';
const mode=process.env.REA_BRIDGE_TEST_MODE;
const retainedRecords=[];
const send=(id,result)=>process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\n');
const names=['binary_session','open_binary','binary_overview','list_procedures','list_strings','procedure_pseudo_code','inspect_go_binary','inspect_rust_binary','inspect_pe_resources','inspect_artifact','extract_artifact','analyze_javascript_application','export_evidence_bundle','close_binary'];
for await(const line of readline.createInterface({input:process.stdin})) {
 const request=JSON.parse(line); if(request.id===undefined)continue;
 if(request.method==='initialize'){send(request.id,{protocolVersion:'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'rea',version:mode==='version'?'0.0.0':'6.7.0'}});continue;}
 if(request.method==='tools/list'){send(request.id,{tools:names.map(name=>({name,inputSchema:{type:'object',properties:name==='analyze_javascript_application'?{source_paths:{type:'array'},detail:{type:'string'},max_heap_mb:{type:'integer'}}:['inspect_artifact','extract_artifact'].includes(name)?{integrity_policy:{type:'string'}}:{}}}))});continue;}
 if(request.method!=='tools/call')continue;
 const {name,arguments:args}=request.params;
 if(mode==='timeout'&&name==='open_binary'){await new Promise(resolve=>setTimeout(resolve,1500));continue;}
 if(mode==='mutation'&&name==='open_binary')await fs.appendFile(args.path,Buffer.from('changed by fixture provider'));
 if(name==='list_strings'&&mode==='json'){process.stdout.write('malformed JSON\n');continue;}
 if(name==='list_strings'&&mode==='utf8'){
  process.stdout.write(Buffer.concat([Buffer.from('{"jsonrpc":"2.0","id":'+request.id+',"result":{"text":"'),Buffer.from([0xff]),Buffer.from('"}}\n')]));continue;
 }
 if(name==='list_strings'&&mode==='failure'){send(request.id,{isError:true,structuredContent:{error:{message:'Owned fixture provider failure'}}});continue;}
 if(name==='export_evidence_bundle'&&mode!=='missingexport')await fs.writeFile(args.path,mode==='oversizedexport'?'A'.repeat(100000):JSON.stringify({schema_version:1,records:retainedRecords}),{flag:'wx'});
 let normalized_result=name==='list_procedures'?[{address:'0x1000',value:'$(NeverExecuteThis)',procedure:{external:false}},{address:'0x2000',value:'second',procedure:{external:false}}]:name==='procedure_pseudo_code'?'int fixture(void) { return 42; }':name==='open_binary'?{ReceivedPath:args.path}:{};
 if(mode==='limit'&&name==='list_strings')normalized_result='A'.repeat(12000);
 if(mode==='emptycode'&&name==='procedure_pseudo_code')normalized_result='';
 if(mode==='extraction'&&name==='extract_artifact')normalized_result={output_root:path.join(process.cwd(),'fixture-missing-extraction')};
 if(mode.startsWith('asar')&&name==='extract_artifact'){
  if(['asarstrict','asarcontradiction'].includes(mode)&&args.integrity_policy!=='record-and-continue'){send(request.id,{isError:true,structuredContent:{error:{code:'artifact_integrity_mismatch',message:'Fixture declared integrity mismatch'}}});continue;}
  if(mode==='asarmissing'){send(request.id,{isError:true,structuredContent:{error:{message:'Required unpacked member is missing'}}});continue;}
  const root=path.join(process.cwd(),'fixture-extraction');await fs.mkdir(path.join(root,'native'),{recursive:true});
  const contents={'package.json':'{"name":"fixture","main":"main.js"}','main.js':'export const knownAnswer = 42;\n','native/fixture.node':'UNPACKED_KNOWN_BYTES'};
  const artifacts=[];
  for(const [relative,content] of Object.entries(contents)){await fs.writeFile(path.join(root,relative),content);artifacts.push({relative_path:relative,bytes_written:Buffer.byteLength(content),sha256:createHash('sha256').update(content).digest('hex')});}
  normalized_result={output_root:root,containment_verified:true,artifacts};
  if(mode==='asarcontradiction')normalized_result.integrity_contradictions=[{logical_path:'native/fixture.node',declared_sha256:'0'.repeat(64),calculated_sha256:artifacts[2].sha256,unpacked:true}];
  if(mode.startsWith('asartransport')){
   const id='ev_'+'a'.repeat(64);retainedRecords.push({evidence_id:mode==='asartransportmissing'?'ev_'+'b'.repeat(64):id,operation:name,normalized_result});
   send(request.id,{isError:true,structuredContent:{error:{code:'resource_constraint',details:{resource:'transport',reported_limits:{boundary:'mcp-response',evidence_id:id}}}}});continue;
  }
 }
 if(name==='analyze_javascript_application')normalized_result={summary:{coverage:{application:{status:mode==='asarpartial'?'partial':'complete'},semantic:{status:'complete'}}},ReceivedArguments:args};
 if(mode==='asarunknown'&&name==='analyze_javascript_application')delete normalized_result.summary.coverage.semantic;
 if(mode==='asarmutation'&&name==='analyze_javascript_application')await fs.appendFile(path.join(args.input_path,'main.js'),'changed by fixture provider');
 let limitations=[];
 if(['open_binary','binary_overview','list_procedures','list_strings','procedure_pseudo_code'].includes(name))limitations=['UNRELATED_TRANSPORT_POLICY'];
 if(mode==='flow-warning'&&name==='procedure_pseudo_code')limitations.push('Ghidra Listing reports a terminal call at 0x140010c7a with no resolved callee; its no-return basis is unknown.');
 if(mode==='metadata-pdb'&&name==='binary_overview')limitations.push('The Ghidra Program references PDB fixture.pdb; Ghidra reports load state unknown.');
 if(name==='inspect_go_binary'){
  normalized_result={build_info:mode==='metadata-go'?{version:'go-fixture'}:null};
  limitations=['GO_UNRELATED_GENERIC_CAVEAT'];
 }
 if(name==='inspect_rust_binary'){
  normalized_result={auditable_metadata:mode==='metadata-rust-auditable'?{packages:[]}:null,rustc_commit:mode.startsWith('metadata-rust')?{hashes:[{hash:'a'.repeat(40)}]}:null};
  limitations=['RUST_UNRELATED_GENERIC_CAVEAT'];
 }
 send(request.id,{structuredContent:{normalized_result,evidence_id:name,limitations},content:[]});
}
'@
$mockPath=Join-Path $TestRoot 'mock-rea.mjs'
[IO.File]::WriteAllText($mockPath,$mock,[Text.UTF8Encoding]::new($false))

function Invoke-BridgeCase([string]$Mode) {
    $run=Join-Path $TestRoot $Mode
    $null=[IO.Directory]::CreateDirectory($run)
    $source=Join-Path $run $(if($Mode.StartsWith('asar')){'app.asar'}else{'native & $(NeverExecuteThis) %PATH% [fixture].exe'})
    [IO.File]::WriteAllBytes($source,([byte[]](0x4d,0x5a,1,2,3,4)))
    $output=Join-Path $run 'output'
    $null=[IO.Directory]::CreateDirectory($output)
    $configuration=@{
        reaScript=$mockPath;inputPath=$source;outputDirectory=$output
        format=if($Mode.StartsWith('asar')){'javascript'}elseif($Mode -eq 'extraction'){'archive'}else{'native'}
        maxJavaScriptHeapMB=2048
        maxJavaScriptFiles=if($Mode -eq 'asarbounded'){1}else{40}
        maxExtractionEntries=if($Mode -eq 'asarextractionlimit'){2}else{50000}
        archiveIntegrityPolicy=if($Mode -eq 'asarcontradiction'){'record-and-continue'}else{'fail'}
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

Assert (($control.Record.Limitations -join ' ') -notmatch 'Go|Rust|GENERIC_CAVEAT|dep-v0') 'Negative language probes polluted native report limitations'
Assert (($control.Record.Limitations -join ' ') -notmatch 'UNRELATED_TRANSPORT_POLICY') 'Native provider transport policy polluted target limitations'
$flow=Invoke-BridgeCase 'flow-warning'
Assert ($flow.Record.NativeFlowWarnings.Count -eq 1 -and ($flow.Record.Limitations -join ' ') -match '1 terminal-call sites') 'A target-specific native flow uncertainty was lost or duplicated'
$pdb=Invoke-BridgeCase 'metadata-pdb'
Assert (($pdb.Record.Limitations -join ' ') -match 'references PDB fixture.pdb' -and ($pdb.Record.Limitations -join ' ') -notmatch 'UNRELATED_TRANSPORT_POLICY') 'Observed PDB uncertainty was lost with provider boilerplate'
$emptyCode=Invoke-BridgeCase 'emptycode'
Assert ($emptyCode.Record.Status -eq 'Partial' -and ($emptyCode.Record.Limitations -join ' ') -notmatch 'pseudocode is a decompiler reconstruction') 'A decompiled-code caveat was reported when no pseudocode was recovered'
foreach($mode in 'metadata-go','metadata-rust','metadata-rust-auditable'){
    $metadata=Invoke-BridgeCase $mode
    $limits=$metadata.Record.Limitations -join ' '
    Assert ($limits -notmatch 'GENERIC_CAVEAT') 'Generic provider capability caveats escaped raw evidence'
    if($mode -eq 'metadata-go'){
        Assert ($limits -match 'Go build metadata was recovered' -and $limits -notmatch 'Rust|dep-v0') 'Go report did not select only observed Go limitations'
    }else{
        Assert ($limits -match 'Rust compiler-path markers' -and $limits -notmatch 'Go build') 'Rust report did not select only observed Rust limitations'
        Assert (($limits -match 'No .dep-v0') -eq ($mode -eq 'metadata-rust')) 'Missing Rust dependency metadata was reported despite a recovered section'
    }
}
Write-Host 'PASS: language metadata limitations require a positive finding; unrelated probe diagnostics remain in raw evidence'

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

$asar=Invoke-BridgeCase 'asar'
Assert ($asar.Record.Status -eq 'Succeeded' -and $asar.Record.TargetExecuted -eq $false) 'Complete ASAR fixture failed or executed target code'
$retained=@($asar.Record.Artifacts|Where-Object Kind -EQ 'extracted')
Assert ($retained.Count -eq 3) 'Packed or unpacked source bytes were lost'
foreach($artifact in $retained){Assert ((Get-FileHash -LiteralPath (Join-Path $asar.Output $artifact.Path)).Hash -eq $artifact.SHA256) 'Retained ASAR artifact hash mismatch'}
Assert ([IO.File]::ReadAllText((Join-Path $asar.Output 'rea-extracted/native/fixture.node')) -ceq 'UNPACKED_KNOWN_BYTES') 'Unpacked native member bytes changed'
Assert (($asar.Record.JavaScriptSelection.SelectedSourceFiles -join ',') -ceq 'package.json,main.js') 'Declared JavaScript entry point was not prioritized'
$semanticStage=$asar.Record.Stages|Where-Object Tool -EQ 'analyze_javascript_application'
$semanticRecord=Get-Content -LiteralPath (Join-Path $asar.Output $semanticStage.EvidencePath) -Raw|ConvertFrom-Json
Assert (($semanticRecord.structuredContent.normalized_result.ReceivedArguments.source_paths -join ',') -eq 'package.json,main.js') 'Provider did not receive bounded source selection'
Assert ($semanticRecord.structuredContent.normalized_result.ReceivedArguments.max_heap_mb -eq 2048) 'JavaScript worker heap budget was not forwarded'
Assert ($semanticRecord.structuredContent.normalized_result.ReceivedArguments.detail -eq 'summary') 'Provider summary delivery was not requested'
Assert ($semanticRecord.structuredContent.normalized_result.ReceivedArguments.input_path -eq (Join-Path $asar.Output 'rea-extracted')) 'Semantic analysis did not use the verified retained source tree'
$partial=Invoke-BridgeCase 'asarpartial'
Assert ($partial.Record.Status -eq 'Partial' -and $partial.Record.JavaScriptProviderCoverage.application.status -eq 'partial') 'Partial JavaScript semantic coverage was reported as complete'
$unknown=Invoke-BridgeCase 'asarunknown'
Assert ($unknown.Record.Status -eq 'Partial') 'Missing JavaScript semantic coverage was reported as complete'
$bounded=Invoke-BridgeCase 'asarbounded'
Assert ($bounded.Record.Status -eq 'Partial' -and -not $bounded.Record.JavaScriptSelection.Complete -and $bounded.Record.JavaScriptSelection.SelectedSourceFiles.Count -eq 1) 'JavaScript selection limit lost coverage information'
Assert (@($bounded.Record.Artifacts|Where-Object Kind -EQ 'extracted').Count -eq 3) 'Semantic limits unexpectedly discarded recovered source files'
$missing=Invoke-BridgeCase 'asarmissing'
Assert ($missing.Record.Status -eq 'Partial' -and @($missing.Record.Stages|Where-Object Tool -EQ 'analyze_javascript_application').Count -eq 0) 'Failed ASAR extraction fell back to unbounded semantic analysis'
$entryLimit=Invoke-BridgeCase 'asarextractionlimit'
Assert ($entryLimit.Record.Status -eq 'Partial' -and @($entryLimit.Record.Stages|Where-Object { $_.Name -eq 'retain_extracted_files' -and $_.Error -match '2-entry bound' }).Count -eq 1) 'Extraction entry limit was ignored or hidden'
$strict=Invoke-BridgeCase 'asarstrict'
Assert ($strict.Record.Status -eq 'Partial' -and @($strict.Record.Artifacts|Where-Object Kind -EQ 'extracted').Count -eq 0) 'Default policy retained mismatched archive members'
$contradiction=Invoke-BridgeCase 'asarcontradiction'
Assert ($contradiction.Record.Status -eq 'Partial' -and $contradiction.Record.ArchiveIntegrityContradictions.Count -eq 1 -and @($contradiction.Record.Artifacts|Where-Object Kind -EQ 'extracted').Count -eq 3) 'Explicit recovery lost observed bytes, integrity contradiction, or partial status'
$transport=Invoke-BridgeCase 'asartransport'
Assert ($transport.Record.Status -eq 'Succeeded' -and @($transport.Record.Stages|Where-Object RecoveredFromRetainedEvidence -EQ $true).Count -eq 1 -and @($transport.Record.Artifacts|Where-Object Kind -EQ 'extracted').Count -eq 3) 'Oversized transport response did not recover its exact retained evidence'
$missingRecord=Invoke-BridgeCase 'asartransportmissing'
Assert ($missingRecord.Record.Status -eq 'Partial' -and @($missingRecord.Record.Artifacts|Where-Object Kind -EQ 'extracted').Count -eq 0) 'An unrelated retained evidence ID was accepted'
$mutatedSource=Invoke-BridgeCase 'asarmutation'
Assert ($mutatedSource.Record.Status -eq 'Failed' -and $mutatedSource.Process.Status -eq 'Failed' -and $mutatedSource.Record.RetainedSourcesUnchanged -eq $false) 'Semantic provider mutation left stale source hashes with a success status'
Write-Host 'PASS: ASAR source retention, exact unpacked bytes, bounded entry-point selection and honest semantic coverage'
& $node.Source --test (Join-Path $PSScriptRoot 'test_analysis_evidence.mjs')
if($LASTEXITCODE -ne 0){throw 'Read-only analysis evidence tools failed their regression checks.'}
