# Native APIs are compiled only. Every profile/token operation below uses a fake.
#requires -Version 5.1
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$TestRoot=(Get-Item -LiteralPath $TestRoot).FullName
$helper=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestDeploymentProfile.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors){throw 'Guest deployment profile helper did not parse.'}
$source=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('using System;')},$true))
if($source.Count -ne 1){throw 'The exact native profile helper source was not found.'}
$fixture=@'
namespace ProfileAnalysisDeploymentProfileTests {
 public sealed class Fake : ProfileAnalysisDeploymentProfile.IProfileApi {
  public string Scenario,Directory;public bool Loaded,Disposed;public int Loads,Unloads,Restores,RestoreFailures;public readonly System.Collections.Generic.Dictionary<string,int> Privileges=new System.Collections.Generic.Dictionary<string,int>();
  public readonly System.Collections.Generic.List<string> Calls=new System.Collections.Generic.List<string>();
  public Fake(string scenario,string directory){Scenario=scenario;Directory=directory;Loaded=scenario=="Existing" || scenario=="TemporaryExisting";Privileges["SeBackupPrivilege"]=scenario=="AlreadyEnabled"?2:0;Privileges["SeRestorePrivilege"]=scenario=="AlreadyEnabled"?2:0;}
  public string UserSid {get{return Scenario=="WrongSid"?"S-1-5-21-1-2-3-501":"S-1-5-21-1-2-3-500";}}
  public string AccountName {get{return "FIXTURE\\Administrator";}}
  public bool IsAdministrator {get{return Scenario!="NotAdmin";}}
  public bool IsLocalAccount {get{return Scenario!="RemoteAccount";}}
  public bool IsImpersonating {get{return Scenario=="Impersonating";}}
  public bool HiveExists(){Calls.Add("Hive");return Loaded && Scenario!="MissingHive";}
  public int ProfileType(out uint flags){Calls.Add("Type");flags=0;if(!Loaded)return 2;if(Scenario=="TemporaryExisting" || Scenario=="TemporaryAfterLoad")flags=1;return Scenario=="TypeFailure"?5:0;}
  public string ProfileDirectory(){Calls.Add("Directory");return ProfileAnalysisDeploymentProfile.Lease.ValidateProfileDirectory(Directory,Scenario=="DirectoryMismatch"?Directory+"-other":Directory);}
  public object EnablePrivilege(string name){Calls.Add("Enable:"+name);if(Scenario=="MissingRestorePrivilege" && name=="SeRestorePrivilege")throw new System.ComponentModel.Win32Exception(1300,"Fixture missing restore privilege");int before=Privileges[name];Privileges[name]=2;return new object[]{name,before};}
  public void RestorePrivilege(object previous){object[] value=(object[])previous;Calls.Add("Restore:"+(string)value[0]);Restores++;if((string)value[0]=="SeBackupPrivilege" && (Scenario=="RestoreFailure" || Scenario=="LoadAndRestoreFailure" || ((Scenario=="OneShotRestoreFailure" || Scenario=="OneShotLoadRestoreFailure") && RestoreFailures==0))){RestoreFailures++;throw new System.ComponentModel.Win32Exception(5,"Fixture restore failed");}Privileges[(string)value[0]]=(int)value[1];}
  public System.IntPtr Load(string userName){Calls.Add("Load");Loads++;if(userName!="Administrator")throw new System.Exception("Wrong local profile name");if(Scenario=="LoadFailure" || Scenario=="LoadAndRestoreFailure" || Scenario=="OneShotLoadRestoreFailure")throw new System.ComponentModel.Win32Exception(2,"Fixture load failed");Loaded=true;return new System.IntPtr(123);}
  public void Unload(System.IntPtr profile){Calls.Add("Unload");Unloads++;if(profile!=new System.IntPtr(123))throw new System.Exception("Not an owned handle");if(Scenario=="UnloadFailure")throw new System.ComponentModel.Win32Exception(5,"Fixture unload failed");Loaded=false;}
  public void Dispose(){Calls.Add("Dispose");Disposed=true;}
 }
 public static class Checks {
  static void Require(bool condition,string message){if(!condition)throw new System.Exception(message);}
  public static void Run(string directory){
   string sid="S-1-5-21-1-2-3-500";
   foreach(string scenario in new string[]{"Existing","Missing","AlreadyEnabled"}){
    Fake api=new Fake(scenario,directory);var lease=ProfileAnalysisDeploymentProfile.Lease.Acquire(sid,api);var proof=lease.Proof;
    Require(proof.Status=="Ready" && proof.UserSid==sid && proof.ProfileType==0 && proof.PrivilegesRestored && proof.PendingPrivilegeRestorations==0,"Ready profile proof failed: "+scenario);
    Require(api.Privileges["SeBackupPrivilege"]==(scenario=="AlreadyEnabled"?2:0) && api.Privileges["SeRestorePrivilege"]==(scenario=="AlreadyEnabled"?2:0),"Acquire changed the original privilege state: "+scenario);
    if(scenario=="Existing")Require(!proof.LoadedByThisRun && proof.WasHiveLoaded && api.Loads==0 && api.Restores==0,"An already-loaded profile was loaded or adjusted again.");
    else Require(proof.LoadedByThisRun && !proof.WasHiveLoaded && api.Loads==1 && api.Restores==2,"Missing profile was not loaded under restored privileges.");
    lease.Release();lease.Dispose();Require(lease.Proof.Status=="Released" && lease.Proof.Released && lease.Proof.PrivilegesRestored && api.Disposed,"Release proof failed: "+scenario);
    Require(api.Unloads==(scenario=="Existing"?0:1),"Release unloaded an unowned handle or unloaded twice: "+scenario);
    Require(api.Privileges["SeBackupPrivilege"]==(scenario=="AlreadyEnabled"?2:0) && api.Privileges["SeRestorePrivilege"]==(scenario=="AlreadyEnabled"?2:0),"Release changed the original privilege state.");
   }
   foreach(string scenario in new string[]{"WrongSid","NotAdmin","RemoteAccount","Impersonating","TemporaryExisting","TemporaryAfterLoad","MissingHive","TypeFailure","DirectoryMismatch","MissingRestorePrivilege","LoadFailure","RestoreFailure","OneShotRestoreFailure","LoadAndRestoreFailure","OneShotLoadRestoreFailure"}){
    Fake api=new Fake(scenario,directory);System.Exception caught=null;
    try{ProfileAnalysisDeploymentProfile.Lease.Acquire(sid,api);}catch(System.Exception error){caught=error;}
    Require(caught!=null && api.Disposed,"Invalid profile was accepted or token was not disposed: "+scenario);
    if(scenario=="WrongSid" || scenario=="NotAdmin" || scenario=="RemoteAccount" || scenario=="Impersonating" || scenario=="TemporaryExisting")Require(api.Loads==0 && api.Unloads==0,"An invalid identity/preloaded profile was changed: "+scenario);
    else if(scenario=="MissingRestorePrivilege")Require(api.Loads==0 && api.Restores==1 && api.Privileges["SeBackupPrivilege"]==0,"Partial privilege acquisition was not restored.");
    else if(scenario=="LoadFailure")Require(api.Unloads==0 && api.Restores==2 && caught is System.ComponentModel.Win32Exception && ((System.ComponentModel.Win32Exception)caught).NativeErrorCode==2,"Load failure lost its primary native error or released an unowned handle.");
    else if(scenario=="LoadAndRestoreFailure" || scenario=="OneShotLoadRestoreFailure")Require(api.Unloads==0 && api.Restores>=3 && caught is System.ComponentModel.Win32Exception && ((System.ComponentModel.Win32Exception)caught).NativeErrorCode==2,"Primary load error was replaced by a restoration error or pending restoration was not retried.");
    else Require(api.Unloads==1,"Failed post-load validation did not release its owned handle: "+scenario);
    if(scenario=="RestoreFailure" || scenario=="OneShotRestoreFailure")Require(caught is System.ComponentModel.Win32Exception && ((System.ComponentModel.Win32Exception)caught).NativeErrorCode==5,"The original native restoration error was replaced by a generic exception.");
    var failureProof=(ProfileAnalysisDeploymentProfile.Proof)caught.Data["DeploymentProfileProof"];
    if(scenario=="RestoreFailure" || scenario=="LoadAndRestoreFailure"){
     Require(!failureProof.PrivilegesRestored && failureProof.PendingPrivilegeRestorations==1 && failureProof.PendingPrivilegeNames[0]=="SeBackupPrivilege" && failureProof.PrivilegeRestorationFailures>=2 && api.Privileges["SeBackupPrivilege"]==2 && caught.Data["DeploymentProfileCleanupError"]!=null,"Persistent restoration failure lost its original snapshot or falsely reported restored privileges.");
    }else{
     Require(api.Privileges["SeBackupPrivilege"]==0 && api.Privileges["SeRestorePrivilege"]==0,"Failure left privileges enabled: "+scenario);
     if(scenario=="OneShotRestoreFailure" || scenario=="OneShotLoadRestoreFailure")Require(failureProof.PrivilegesRestored && failureProof.PendingPrivilegeRestorations==0 && failureProof.PrivilegeRestorationFailures==1 && failureProof.Released,"Successful failure cleanup did not restore the original disabled privilege and retain its earlier failure evidence.");
    }
   }
   Fake unloadApi=new Fake("UnloadFailure",directory);var failedLease=ProfileAnalysisDeploymentProfile.Lease.Acquire(sid,unloadApi);System.Exception unloadError=null;
   try{failedLease.Release();}catch(System.Exception error){unloadError=error;}
   Require(unloadError is System.ComponentModel.Win32Exception && failedLease.Proof.Status=="CleanupFailed" && !failedLease.Proof.Released && failedLease.Proof.PrivilegesRestored && unloadApi.Disposed && unloadApi.Unloads==1,"Unload failure was hidden or left privileges changed.");
   foreach(string invalid in new string[]{"\\\\server\\profile","relative","C:relative","C:\\"}){
    bool rejected=false;try{ProfileAnalysisDeploymentProfile.Lease.ValidateProfileDirectory(invalid,invalid);}catch(System.InvalidOperationException){rejected=true;}
    Require(rejected,"Nonlocal or relative profile path was accepted.");
   }
   System.Type native=typeof(ProfileAnalysisDeploymentProfile.Lease).Assembly.GetType("ProfileAnalysisDeploymentProfile.NativeApi");
   var flags=System.Reflection.BindingFlags.NonPublic;
   Require(System.Runtime.InteropServices.Marshal.SizeOf(native.GetNestedType("ProfileInfo",flags))==(System.IntPtr.Size==8?56:32),"PROFILEINFO native layout differs from Windows ABI.");
   Require(System.Runtime.InteropServices.Marshal.SizeOf(native.GetNestedType("UserInfo3",flags))==(System.IntPtr.Size==8?184:116),"USER_INFO_3 native layout differs from Windows ABI.");
   Require(System.Runtime.InteropServices.Marshal.SizeOf(native.GetNestedType("Privileges",flags))==16,"TOKEN_PRIVILEGES one-entry layout differs from Windows ABI.");
  }
 }
}
'@
Add-Type -TypeDefinition ($source[0].Value+"`n"+$fixture) -Language CSharp
$profileDirectory=Join-Path $TestRoot 'fake-profile'
$null=[IO.Directory]::CreateDirectory($profileDirectory)
[IO.File]::WriteAllText((Join-Path $profileDirectory 'NTUSER.DAT'),'Fixture only; never loaded as a registry hive.')
[ProfileAnalysisDeploymentProfileTests.Checks]::Run($profileDirectory)
. $helper
# Exercise the exact PowerShell exit wrapper with the same fake-backed lease.
$fake=[ProfileAnalysisDeploymentProfileTests.Fake]::new('Missing',$profileDirectory)
$lease=[ProfileAnalysisDeploymentProfile.Lease]::Acquire('S-1-5-21-1-2-3-500',$fake)
$acquired=$lease.Proof|ConvertTo-Json|ConvertFrom-Json
$cleanup=Exit-AnalysisWindowsDeploymentProfile -Lease $lease
if($acquired.Status -ne 'Ready' -or $cleanup.Status -ne 'Released' -or -not $cleanup.Released -or -not $cleanup.PrivilegesRestored){throw 'PowerShell lease snapshot/exit contract failed.'}
Write-Host ('PASS: PowerShell '+$PSVersionTable.PSVersion+' compiled profile interop without invoking it; fake API tests verify identity, local profile/hive, exact privilege restoration, prior-loaded preservation and owned-handle cleanup')

# Import only the inventory/diagnostic definitions from the runner AST. Never
# dot-source the executable runner or touch its fixed guest paths on this host.
$runner=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestRunner.ps1'
$tokens=$null;$errors=$null
$runnerAst=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
if($errors){throw 'Runner did not parse.'}
foreach($name in 'Get-GuestFileInventory','Get-GuestExceptionDetail'){
    $definition=@($runnerAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    if($definition.Count -ne 1){throw 'An exact runner helper definition was not found.'}
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$inventoryRoot=Join-Path $TestRoot 'inventory'
$null=[IO.Directory]::CreateDirectory($inventoryRoot)
$filePath=Join-Path $inventoryRoot 'known.txt';[IO.File]::WriteAllText($filePath,'known inventory data',[Text.UTF8Encoding]::new($false))
$inventory=Get-GuestFileInventory -Root $inventoryRoot
if(-not $inventory.Complete -or $inventory.Status -ne 'Completed' -or $inventory.ErrorCount -ne 0 -or $inventory.Files.Count -ne 1 -or $inventory.Files[0].SHA256 -ne (Get-FileHash -LiteralPath $filePath).Hash){throw 'Readable real fixture inventory was incomplete or incorrect.'}
$missing=Get-GuestFileInventory -Root (Join-Path $TestRoot 'missing-inventory')
if($missing.Complete -or $missing.Status -ne 'Partial' -or $missing.ErrorCount -ne 1 -or $missing.Errors[0].Operation -ne 'InspectRoot'){throw 'A missing inventory root was silently reported as complete.'}

& {
    # Local advanced-function fakes emit normally nonterminating errors. The
    # production function must explicitly turn these into retained diagnostics.
    $ErrorActionPreference='Continue'
    $script:inventoryCase='enumeration';$script:producedInventoryEntries=0
    function Get-ChildItem {
        [CmdletBinding()]
        param([string]$LiteralPath,[switch]$Force)
        if($ErrorActionPreference -ne 'Stop'){throw 'Inventory enumeration omitted explicit ErrorAction Stop.'}
        if($script:inventoryCase -eq 'enumeration'){Write-Error ('Fixture enumeration denied '+('x'*5000));return}
        if($script:inventoryCase -eq 'many-errors'){
            if($LiteralPath -eq $inventoryRoot){for($i=0;$i -lt 70;$i++){[pscustomobject]@{FullName=(Join-Path $inventoryRoot ('denied-'+$i));PSIsContainer=$true;Attributes=[IO.FileAttributes]::Directory}}}
            else{Write-Error 'Fixture child enumeration denied'}
            return
        }
        if($script:inventoryCase -eq 'entry-limit'){
            for($i=0;$i -lt 10000;$i++){$script:producedInventoryEntries++;[pscustomobject]@{FullName=(Join-Path $inventoryRoot ('large-'+$i));PSIsContainer=$false;Attributes=[IO.FileAttributes]::Normal;Length=2097152;LastWriteTimeUtc=[DateTime]::UtcNow}}
            return
        }
        Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
    }
    function Get-FileHash {
        [CmdletBinding()]
        param([string]$LiteralPath,[string]$Algorithm)
        if($ErrorActionPreference -ne 'Stop'){throw 'Inventory hashing omitted explicit ErrorAction Stop.'}
        Write-Error 'Fixture file hash denied'
    }
    $denied=Get-GuestFileInventory -Root $inventoryRoot
    if($denied.Complete -or $denied.ErrorCount -ne 1 -or $denied.Errors[0].Operation -ne 'EnumerateDirectory' -or $denied.Errors[0].Message -notlike 'Fixture enumeration denied*' -or $denied.Errors[0].Message.Length -gt 1024){throw 'Directory access failure was not retained as a bounded partial inventory.'}
    $script:inventoryCase='hash'
    $hashDenied=Get-GuestFileInventory -Root $inventoryRoot
    if($hashDenied.Complete -or $hashDenied.ErrorCount -ne 1 -or $hashDenied.Errors[0].Operation -ne 'HashFile' -or $hashDenied.Files[0].HashError -notlike 'Fixture file hash denied*' -or $hashDenied.Files[0].SHA256){throw 'A nonterminating hash failure was silently represented as a successful inventory.'}
    $script:inventoryCase='many-errors'
    $many=Get-GuestFileInventory -Root $inventoryRoot
    if($many.Complete -or $many.ErrorCount -ne 70 -or $many.Errors.Count -ne 64 -or -not $many.ErrorsTruncated){throw 'Directory error collection lost its bound or did not report omitted errors.'}
    $script:inventoryCase='entry-limit'
    $limited=Get-GuestFileInventory -Root $inventoryRoot
    if($limited.Complete -or -not $limited.Truncated -or $limited.Visited -ne 5000 -or $limited.Files.Count -ne 5000 -or $script:producedInventoryEntries -gt 5001){throw 'File inventory did not stop its input stream at the bounded entry limit.'}
}

$catchDefinition=@($runnerAst.FindAll({param($node) $node -is [Management.Automation.Language.CatchClauseAst] -and $node.Body.Extent.Text.Contains('$record.ErrorDetails=Get-GuestExceptionDetail')},$true))
if($catchDefinition.Count -ne 1){throw 'The exact runner catch diagnostic block was not found.'}
$catchText=$catchDefinition[0].Body.Extent.Text
$catchBlock=[scriptblock]::Create($catchText.Substring(1,$catchText.Length-2))
$record=[ordered]@{}
function Invoke-PrivateDiagnosticFixture {
    param([string]$PrivateValue)
    if(-not $PrivateValue){throw 'Fixture argument missing.'}
    Write-Error -Message ('Fixture denied '+('m'*10000)) -ErrorId ('FixtureFailure'+('i'*2000)) -TargetObject ('fixture-target-'+('t'*3000)) -ErrorAction Stop
}
try{Invoke-PrivateDiagnosticFixture -PrivateValue 'private-credential-fixture-never-record'}catch{& $catchBlock}
$diagnostic=$record|ConvertTo-Json -Depth 8
if($record.Status -ne 'Failed' -or $record.Error.Length -gt 4096 -or $record.ErrorDetails.Message.Length -gt 4096 -or $record.ErrorContext.ScriptLineNumber -le 0 -or -not $record.ErrorContext.ScriptStackTrace -or $record.ErrorContext.ScriptStackTrace.Length -gt 4096 -or $record.ErrorContext.FullyQualifiedErrorId.Length -gt 1024 -or $record.ErrorContext.TargetName.Length -gt 1024){throw 'Runner failure context was missing or exceeded its diagnostic bounds.'}
if($diagnostic -match 'private-credential-fixture-never-record|BoundParameters|TargetObject|PositionMessage'){throw 'Runner failure context retained a private argument or unsafe invocation details.'}
Write-Host 'PASS: exact runner inventory records bounded read/hash errors and streamed truncation; exact catch retains bounded location/native diagnostics without private invocation arguments'

$outerTry=@($runnerAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Finally})
if($outerTry.Count -ne 1){throw 'The exact runner try/finally was not found.'}
$beforeStatements=@($outerTry[0].Body.Statements|Where-Object {$_.Extent.Text -match '^\$(?:fileBefore=|fileBefore\||record\.FileInventoryBefore=)'})
$afterStatement=@($outerTry[0].Finally.FindAll({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and @($node.Body.Statements|Where-Object {$_.Extent.Text.StartsWith('$fileAfter=Invoke-GuestInventoryWorker')}).Count -eq 1},$true))
$coverageStatement=@($outerTry[0].Finally.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($record.FileInventoryBefore.Complete')},$true))
if($beforeStatements.Count -ne 3 -or $afterStatement.Count -ne 1 -or $coverageStatement.Count -ne 1){throw 'The exact inventory report/coverage clauses were not found.'}
$beforeBlock=[scriptblock]::Create(($beforeStatements|ForEach-Object {$_.Extent.Text}) -join "`n")
$afterBlock=[scriptblock]::Create($afterStatement[0].Extent.Text)
$coverageBlock=[scriptblock]::Create($coverageStatement[0].Extent.Text)
foreach($name in 'Invoke-GuestInventoryWorker','Get-GuestInventoryWorkerState'){
    $definition=@($runnerAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if($definition.Count -ne 1){throw ('The exact worker helper was not found: '+$name)}
    $source=$definition[0].Extent.Text
    if($name -eq 'Invoke-GuestInventoryWorker'){$source=$source.Replace('function Invoke-GuestInventoryWorker {','function Invoke-GuestInventoryWorkerActual {')}
    . ([scriptblock]::Create($source))
}
& {
    $OwnedRunner=$false
    function Invoke-GuestInventoryWorker {
        param([string]$Kind,[int]$TimeoutSeconds)
        if($Kind -cne 'File' -or $TimeoutSeconds -ne 120){throw 'The exact file clauses changed their worker request.'}
        if($script:inventoryProxyThrows){throw 'Fixture worker invocation failure.'}
        Invoke-GuestInventoryWorkerActual -Kind $Kind -TimeoutSeconds 5
    }
    foreach($case in 'complete','before-incomplete','after-incomplete','missing-before','existing-failure','after-throws','worker-throws'){
        $script:inventoryProxyThrows=$false;$script:ProfileAnalysisInventoryWorkers=[Collections.Generic.List[object]]::new()
        $output=Join-Path $TestRoot ('inventory-final-'+$case);$null=[IO.Directory]::CreateDirectory($output)
        $record=[ordered]@{Status=if($case -eq 'existing-failure'){'Failed'}else{'Completed'};Limitations=@('Existing limitation')}
        if($case -ne 'missing-before'){
            $script:inventoryNextReply=[pscustomobject]@{Status=if($case -in 'before-incomplete','existing-failure'){'Partial'}else{'Completed'};Complete=($case -notin 'before-incomplete','existing-failure');ErrorCount=if($case -in 'before-incomplete','existing-failure'){1}else{0};Truncated=$false;ErrorsTruncated=$false;Files=@(@{Path='before-fixture'});Errors=@(@{Message='before-detail'})}
            $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:inventoryNextReply|ConvertTo-Json -Depth 6 -Compress)))
            Set-Item Function:\Get-GuestFileInventory -Value ([scriptblock]::Create('param($RecordSink,$ProgressState) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('''+$encoded+'''))|ConvertFrom-Json'))
            & $beforeBlock
            $storedBefore=Get-Content -LiteralPath (Join-Path $output 'files-before.json') -Raw|ConvertFrom-Json
            if($storedBefore.Files[0].Path -ne 'before-fixture' -or $storedBefore.Errors[0].Message -ne 'before-detail' -or $record.FileInventoryBefore.Complete -ne $script:inventoryNextReply.Complete -or $storedBefore.Worker.Status -ne 'Completed'){throw 'The exact before clause lost full retained observations or its worker coverage summary.'}
        }
        $script:inventoryNextReply=if($case -eq 'after-throws'){'Throw'}else{[pscustomobject]@{Status=if($case -eq 'after-incomplete'){'Partial'}else{'Completed'};Complete=($case -ne 'after-incomplete');ErrorCount=if($case -eq 'after-incomplete'){1}else{0};Truncated=$false;ErrorsTruncated=$false;Files=@(@{Path='after-fixture'});Errors=@(@{Message='after-detail'})}}
        if($case -eq 'after-throws'){Set-Item Function:\Get-GuestFileInventory -Value {param($RecordSink,$ProgressState)throw 'Fixture after-inventory read failure.'}}
        else{
            $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($script:inventoryNextReply|ConvertTo-Json -Depth 6 -Compress)))
            Set-Item Function:\Get-GuestFileInventory -Value ([scriptblock]::Create('param($RecordSink,$ProgressState) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('''+$encoded+'''))|ConvertFrom-Json'))
        }
        $script:inventoryProxyThrows=$case -eq 'worker-throws'
        & $afterBlock
        if($case -notin 'after-throws','worker-throws'){
            $storedAfter=Get-Content -LiteralPath (Join-Path $output 'files-after.json') -Raw|ConvertFrom-Json
            if($storedAfter.Files[0].Path -ne 'after-fixture' -or $storedAfter.Errors[0].Message -ne 'after-detail' -or $record.FileInventoryAfter.Complete -ne $script:inventoryNextReply.Complete -or $storedAfter.Worker.Status -ne 'Completed'){throw 'The exact after clause lost full retained observations or its worker coverage summary.'}
        }elseif($case -eq 'after-throws'){
            $storedAfter=Get-Content -LiteralPath (Join-Path $output 'files-after.json') -Raw|ConvertFrom-Json
            if($record.FileInventoryAfter.Status -ne 'Partial' -or $record.FileInventoryAfter.Complete -ne $false -or $storedAfter.Worker.Status -ne 'Failed' -or $storedAfter.CollectionError -notmatch 'Fixture after-inventory read failure'){throw 'A failed collector lost its explicit partial worker evidence.'}
        }elseif($record.FileInventoryAfter.Status -ne 'Failed' -or $record.FileInventoryAfter.Complete -ne $false -or ($record.Limitations -join ' ') -notmatch 'Fixture worker invocation failure'){throw 'A failed worker invocation lost its failure summary or limitation.'}
        & $coverageBlock
        $expectedStatus=if($case -eq 'complete'){'Completed'}elseif($case -eq 'existing-failure'){'Failed'}else{'Partial'}
        if($record.Status -ne $expectedStatus -or $record.Limitations -notcontains 'Existing limitation'){throw ('The exact coverage finalizer changed the wrong result: '+$case)}
        $coverageLimited=($record.Limitations -join ' ') -match 'File snapshots are incomplete'
        if($coverageLimited -ne ($case -ne 'complete')){throw ('The final inventory coverage limitation is missing or spurious: '+$case)}
        $workerState=Get-GuestInventoryWorkerState
        if($workerState.PendingCount -ne 0 -or ($case -ne 'after-throws' -and $workerState.RetainedCount -ne 0)){throw 'A completed inert fixture retained an unexpected active worker.'}
        foreach($worker in $script:ProfileAnalysisInventoryWorkers){if(-not $worker.Disposed -and $worker.Async.IsCompleted -and (-not $worker.StopAsync -or $worker.StopAsync.IsCompleted)){$worker.PowerShell.Dispose();$worker.Disposed=$true}}
    }
}
Write-Host 'PASS: exact before/after clauses retain full inventories and coverage; incomplete or missing inventories downgrade Completed, preserve Failed, and retain limitations'
