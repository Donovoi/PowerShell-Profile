# Exercise extracted collectors with inert files and fake registry/network providers only.
#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'TestRoot must be new.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$runner=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/ExecutableAnalysis/WindowsGuestRunner.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) 'Guest runner did not parse.'
foreach($name in 'Get-GuestFileInventory','Get-GuestRegistryInventory','Get-GuestNetworkInventory'){
    $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    Assert-True ($nodes.Count -eq 1) ('Exact collector missing: '+$name)
    $source=$nodes[0].Extent.Text
    if($name -eq 'Get-GuestRegistryInventory'){
        $marker='[Microsoft.Win32.Registry]::CurrentUser'
        Assert-True (($source.Split(@($marker),[StringSplitOptions]::None).Count-1) -eq 1) 'Registry fake substitution must replace exactly the root provider.'
        $source=$source.Replace($marker,'$script:RegistryRootFixture')
    }
    . ([scriptblock]::Create($source))
}
function New-SinkFixture {
    [pscustomobject]@{Queue=[Collections.Concurrent.ConcurrentQueue[object]]::new();State=[Collections.Concurrent.ConcurrentDictionary[string,object]]::new()}
}
function Assert-PrimitiveSink($Sink,[int]$MaximumRows){
    $snapshot=$Sink.Queue.ToArray()
    Assert-True ($snapshot.Count -le $MaximumRows) 'Record queue exceeded its hard bound.'
    foreach($envelope in $snapshot){
        Assert-True ($envelope.Kind -in 'File','RegistryValue','Connection','Error') 'Unexpected record kind.'
        foreach($property in $envelope.Data.PSObject.Properties){
            $value=$property.Value
            Assert-True ($null -eq $value -or $value -is [string] -or $value -is [ValueType]) 'A queued row retained a live provider or mutable nested object.'
        }
    }
    foreach($value in $Sink.State.Values){Assert-True ($null -eq $value -or $value -is [string] -or $value -is [ValueType]) 'Progress retained non-scalar provider state.'}
}
$fileRoot=Join-Path $TestRoot 'files';$null=[IO.Directory]::CreateDirectory($fileRoot)
[IO.File]::WriteAllText((Join-Path $fileRoot 'known.txt'),'Known inert inventory bytes.')
$sink=New-SinkFixture;$actual=Get-GuestFileInventory -Root $fileRoot -RecordSink $sink.Queue -ProgressState $sink.State
Assert-True ($actual.Complete -and $actual.Files.Count -eq 1 -and $sink.Queue.Count -eq 1 -and $sink.State['Complete']) 'Complete file observations were not published.'
Assert-True ($sink.Queue.ToArray()[0].Data.SHA256 -eq (Get-FileHash -LiteralPath (Join-Path $fileRoot 'known.txt')).Hash) 'Published file hash changed.'
Assert-PrimitiveSink $sink 5064
$sink=New-SinkFixture;$missing=Get-GuestFileInventory -Root (Join-Path $TestRoot 'absent') -RecordSink $sink.Queue -ProgressState $sink.State
Assert-True (-not $missing.Complete -and $sink.Queue.ToArray()[0].Kind -eq 'Error' -and $sink.State['ErrorCount'] -eq 1) 'File errors were lost from the sink.'
function Get-ChildItem {
    [CmdletBinding()]param([string]$LiteralPath,[switch]$Force)
    for($index=0;$index -lt $script:FakeFileCount;$index++){
        [pscustomobject]@{FullName=('C:\'+('p'*$script:FakePathLength)+$index);Length=2097152;Attributes=[IO.FileAttributes]::Normal;PSIsContainer=$false;LastWriteTimeUtc=[DateTime]::UtcNow}
    }
}
try{
    $script:FakeFileCount=1;$script:FakePathLength=1100;$sink=New-SinkFixture
    $long=Get-GuestFileInventory -Root $fileRoot -RecordSink $sink.Queue -ProgressState $sink.State
    Assert-True (-not $long.Complete -and $long.DataTruncated -and $long.Files[0].PathTruncated -and $long.Files[0].Path.Length -eq 1024) 'Truncated file identity was reported complete.'
    $script:FakeFileCount=5000;$script:FakePathLength=600;$sink=New-SinkFixture
    $bounded=Get-GuestFileInventory -Root $fileRoot -RecordSink $sink.Queue -ProgressState $sink.State
    Assert-True (-not $bounded.Complete -and $bounded.DataTruncated -and $bounded.Files.Count -lt 5000 -and $sink.State['Characters'] -le 2097152) 'Total file text budget was not enforced.'
    Assert-PrimitiveSink $sink 5064
}finally{Remove-Item Function:\Get-ChildItem}
$fakeRegistry=@'
using System;
using Microsoft.Win32;
public sealed class InventorySinkRegistryRoot {
 public string Scenario;public int Closed;
 public InventorySinkRegistryRoot(string scenario){Scenario=scenario;}
 public InventorySinkRegistryNode OpenSubKey(string name,bool writable){
  if(writable)throw new InvalidOperationException("Unexpected writable registry request.");
  if(Scenario=="Errors"&&name!="Software")throw new UnauthorizedAccessException(new string('e',2048));
  return new InventorySinkRegistryNode(this,name);
 }
}
public sealed class InventorySinkRegistryNode {
 private InventorySinkRegistryRoot root;private string name;
 public InventorySinkRegistryNode(InventorySinkRegistryRoot r,string n){root=r;name=n;}
 public string[] GetSubKeyNames(){if(name!="Software")return new string[0];if(root.Scenario=="Errors"){var names=new string[70];for(int i=0;i<70;i++)names[i]="error"+i;return names;}if(root.Scenario=="LongIdentity")return new[]{new string('k',1100)};return new string[0];}
 public string[] GetValueNames(){if(root.Scenario=="Errors")return new string[0];if(root.Scenario=="Many"){var names=new string[5001];for(int i=0;i<names.Length;i++)names[i]="value"+i;return names;}return new[]{root.Scenario=="LongIdentity"?new string('n',700):"value"};}
 public object GetValue(string name,object fallback,RegistryValueOptions options){if(options!=RegistryValueOptions.DoNotExpandEnvironmentNames)throw new InvalidOperationException("Unexpected expansion.");if(root.Scenario=="Binary")return new byte[1048576];if(root.Scenario=="Multi")return new[]{new string('m',3000),new string('n',3000)};if(root.Scenario=="Text")return new string('t',1048576);return "inert";}
 public RegistryValueKind GetValueKind(string name){return root.Scenario=="Binary"?RegistryValueKind.Binary:root.Scenario=="Multi"?RegistryValueKind.MultiString:RegistryValueKind.String;}
 public void Dispose(){root.Closed++;}
}
'@
Add-Type -TypeDefinition $fakeRegistry -ErrorAction Stop
foreach($scenario in 'Normal','Errors','LongIdentity','Binary','Multi','Text','Many'){
    $script:RegistryRootFixture=[InventorySinkRegistryRoot]::new($scenario);$sink=New-SinkFixture
    $registry=Get-GuestRegistryInventory -RecordSink $sink.Queue -ProgressState $sink.State
    Assert-PrimitiveSink $sink 5064
    Assert-True ($script:RegistryRootFixture.Closed -gt 0) 'Fake registry handles were not closed.'
    if($scenario -eq 'Normal'){Assert-True ($registry.Complete -and $registry.Values.Count -eq 1 -and $sink.Queue.ToArray()[0].Kind -eq 'RegistryValue') 'Normal registry result was lost.'}
    elseif($scenario -eq 'Errors'){Assert-True (-not $registry.Complete -and $registry.ErrorCount -eq 70 -and $registry.Errors.Count -eq 64 -and $registry.ErrorsTruncated -and $sink.Queue.Count -eq 64) 'Registry errors were unbounded or lost.'}
    elseif($scenario -eq 'LongIdentity'){Assert-True (-not $registry.Complete -and $registry.Values[-1].KeyTruncated -and $registry.Values[-1].NameTruncated -and $registry.Values[-1].Key.Length -eq 1024 -and $registry.Values[-1].Name.Length -eq 512) 'Registry identity truncation was not explicit.'}
    elseif($scenario -eq 'Many'){Assert-True (-not $registry.Complete -and $registry.Values.Count -eq 5000 -and $sink.Queue.Count -eq 5000) 'Registry value count exceeded its bound.'}
    else{Assert-True (-not $registry.Complete -and $registry.DataTruncated -and $registry.Values[0].Value.Length -eq 4096 -and $registry.Values[0].Truncated) 'Oversized registry value conversion was not bounded and marked partial.'}
}
function Get-NetTCPConnection {
    [CmdletBinding()]param()
    for($index=0;$index -lt $script:ConnectionCount;$index++){
        [pscustomobject]@{LocalAddress=if($script:LongAddress){'a'*1024}else{'127.0.0.1'};LocalPort=1000;RemoteAddress='127.0.0.1';RemotePort=2000;State='Established';OwningProcess=1234;UnwantedNestedProvider=[pscustomobject]@{ShouldNotEscape='fixture'}}
    }
    if($script:ConnectionThrow){throw 'Known connection provider failure.'}
}
try{
    foreach($scenario in 'Complete','Overflow','ErrorAfterRow','LongIdentity'){
        $script:ConnectionCount=if($scenario -eq 'Overflow'){257}else{1};$script:ConnectionThrow=$scenario -eq 'ErrorAfterRow';$script:LongAddress=$scenario -eq 'LongIdentity'
        $sink=New-SinkFixture;$network=Get-GuestNetworkInventory -RecordSink $sink.Queue -ProgressState $sink.State
        Assert-PrimitiveSink $sink 320
        if($scenario -eq 'Complete'){Assert-True ($network.Complete -and $network.Connections.Count -eq 1 -and $sink.State['Complete']) 'Complete network result was not published.'}
        elseif($scenario -eq 'Overflow'){Assert-True (-not $network.Complete -and $network.Truncated -and $network.Connections.Count -eq 256 -and $network.ErrorCount -eq 0 -and $sink.Queue.Count -eq 256) 'Network limit was misreported as an error or exceeded.'}
        elseif($scenario -eq 'ErrorAfterRow'){Assert-True (-not $network.Complete -and $network.Connections.Count -eq 1 -and $network.ErrorCount -eq 1 -and $sink.Queue.Count -eq 2 -and $sink.Queue.ToArray()[1].Kind -eq 'Error') 'Network provider failure discarded a previously observed row.'}
        else{Assert-True (-not $network.Complete -and $network.DataTruncated -and $network.Connections[0].Truncated -and $network.Connections[0].LocalAddress.Length -eq 128) 'Truncated network identity was reported complete.'}
    }
}finally{Remove-Item Function:\Get-NetTCPConnection}
[pscustomobject]@{Status='Passed';PowerShellVersion=[string]$PSVersionTable.PSVersion;NativeRegistryOperations=$false;NativeNetworkQueries=$false;TargetExecution=$false;Checks=@('Exact file collector known bytes and read errors','Bounded file paths and total text','Fake registry handle cleanup, 64 errors, 5000 rows and bounded value conversion','Connection overflow, partial-row retention and primitive queue schema')}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $TestRoot 'result.json') -Encoding UTF8
Write-Output 'PASS: exact collector sinks retain bounded primitive rows/errors, explicit truncation and scalar progress using inert files and fake registry/network providers.'
