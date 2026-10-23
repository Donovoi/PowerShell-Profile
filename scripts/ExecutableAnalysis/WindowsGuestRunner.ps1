# This trusted script is copied into the dedicated guest during provisioning.
# Never run this script against an input on the host.
#requires -Version 5.1
param(
    [ValidateRange(1,600)][int]$TimeoutSeconds=120,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSHA256
)
$ErrorActionPreference='Stop'
$target='C:\ProfileAnalysis\Work\target.exe'
$output='C:\ProfileAnalysis\Results'
$record=[ordered]@{SchemaVersion=1;Status='Failed';StartedUtc=[DateTime]::UtcNow.ToString('o');GuestUser=[Security.Principal.WindowsIdentity]::GetCurrent().Name;IsAdministrator=$null;ExpectedSHA256=$ExpectedSHA256;TargetSHA256=$null;TargetUnchanged=$null;Execution=$null;Validation=@{};Limitations=@('Execution is offline and without arguments or GUI interaction.','Process polling can miss very short-lived processes.','File observations cover the guest work and temporary directories, not every system volume.','Registry observations cover bounded HKCU Software values, not every registry hive.','Connection snapshots do not trace every failed network API call; no external network adapter is present.','A disposable VM is a containment measure, not a guarantee against hypervisor escape.')}
$record.Budgets=[ordered]@{TimeoutSeconds=$TimeoutSeconds;MaximumActiveProcesses=32;MaximumProcessMemoryBytes=536870912;MaximumJobMemoryBytes=1073741824;CombinedOutputThresholdBytes=8388608;PollingIntervalMilliseconds=100;OutputThresholdIsPolled=$true;FileInventoryEntryLimit=5000;RegistryKeyLimit=2000;RegistryValueLimit=5000}
$record.Limitations+='Process creation or memory allocation can fail at the configured job limits. The polled output threshold can be exceeded between observations.'

function Get-GuestFileInventory {
    $rows=New-Object 'Collections.Generic.List[object]'
    $stack=New-Object 'Collections.Generic.Stack[string]'
    foreach($directory in @('C:\ProfileAnalysis\Work',$env:TEMP)){if(Test-Path -LiteralPath $directory){$stack.Push($directory)}}
    $visited=0
    while($stack.Count -gt 0 -and $visited -lt 5000) {
        foreach($entry in Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction SilentlyContinue) {
            $visited++;if($visited -gt 5000){break}
            if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            if($entry.PSIsContainer){$stack.Push($entry.FullName);continue}
            $hash=$null;$hashError=$null
            if($entry.Length -le 1MB){try{$hash=(Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash}catch{$hashError=$_.Exception.Message}}
            $rows.Add([pscustomobject]@{Path=$entry.FullName;Bytes=$entry.Length;ModifiedUtc=$entry.LastWriteTimeUtc.ToString('o');SHA256=$hash;HashError=$hashError})
        }
    }
    [pscustomobject]@{Files=$rows.ToArray();Visited=$visited;Truncated=($stack.Count -gt 0 -or $visited -ge 5000);Scope=@('C:\ProfileAnalysis\Work',$env:TEMP)}
}

function Get-GuestRegistryInventory {
    $rows=New-Object 'Collections.Generic.List[object]'
    $inventoryErrors=New-Object 'Collections.Generic.List[string]'
    $stack=New-Object 'Collections.Generic.Stack[string]';$stack.Push('Software')
    $visited=0;$characters=0
    while($stack.Count -gt 0 -and $visited -lt 2000 -and $rows.Count -lt 5000 -and $characters -lt 262144) {
        $name=$stack.Pop();$visited++;$key=$null
        try {
            $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($name,$false)
            if($null -eq $key){continue}
            foreach($child in $key.GetSubKeyNames()){$stack.Push($name+'\'+$child)}
            foreach($valueName in $key.GetValueNames()) {
                if($rows.Count -ge 5000 -or $characters -ge 262144){break}
                $value=$key.GetValue($valueName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $text=if($value -is [byte[]]){[Convert]::ToBase64String($value)}else{[string]($value -join "`n")}
                $truncated=$text.Length -gt 4096;if($truncated){$text=$text.Substring(0,4096)};$characters+=$text.Length
                $rows.Add([pscustomobject]@{Key=('HKCU\'+$name);Name=$valueName;Kind=[string]$key.GetValueKind($valueName);Value=$text;Truncated=$truncated})
            }
        } catch {$inventoryErrors.Add($name+': '+$_.Exception.Message)} finally {if($key){$key.Dispose()}}
    }
    [pscustomobject]@{Values=$rows.ToArray();VisitedKeys=$visited;Truncated=($stack.Count -gt 0 -or $rows.Count -ge 5000 -or $characters -ge 262144);Scope='HKCU\Software';Errors=$inventoryErrors.ToArray()}
}

try {
    $record.RunnerSHA256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $record.IsAdministrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($record.IsAdministrator){throw 'Target execution refuses an administrator token.'}
    $currentUserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Where-Object {$_.SID.Value -eq $currentUserSid}){throw 'Target execution refuses an account in Administrators, including a filtered administrator token.'}
    $record.Validation.AccountNotAdministrator=$true
    $record.TargetSHA256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if($record.TargetSHA256 -ne $ExpectedSHA256){throw 'Guest input SHA256 differs from the host snapshot.'}
    $record.Validation.HashMatched=$true
    $adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop|Select-Object Name,Status,HardwareInterface,InterfaceDescription)
    if(@($adapters|Where-Object HardwareInterface).Count){throw 'The guest has a hardware network adapter.'}
    $routes=@(Get-NetRoute -ErrorAction Stop|Select-Object -First 100 DestinationPrefix,InterfaceAlias,NextHop)
    if(@($routes|Where-Object DestinationPrefix -In '0.0.0.0/0','::/0').Count){throw 'The guest has a default network route.'}
    $record.Validation.NoNetworkAdapter=$true
    @{Adapters=$adapters;Routes=$routes;Connections=@(Get-NetTCPConnection -ErrorAction SilentlyContinue|Select-Object -First 256 LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $output 'network-before.json') -Encoding utf8
    $native=@'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ProfileAnalysisGuestJob {
 [StructLayout(LayoutKind.Sequential)] struct Security { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup { public uint Size; public string Reserved; public string Desktop; public string Title; public uint X,Y,XSize,YSize,XChars,YChars,Fill,Flags; public ushort Show,ReservedSize; public IntPtr ReservedData,Input,Output,Error; }
 [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process,Thread; public uint ProcessId,ThreadId; }
 [StructLayout(LayoutKind.Sequential)] struct BasicLimits { public long ProcessTime,JobTime; public uint Flags; public UIntPtr MinimumWorking,MaximumWorking; public uint ActiveProcesses; public UIntPtr Affinity; public uint Priority,Scheduling; }
 [StructLayout(LayoutKind.Sequential)] struct Counters { public ulong ReadOps,WriteOps,OtherOps,ReadBytes,WriteBytes,OtherBytes; }
 [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits { public BasicLimits Basic; public Counters Io; public UIntPtr ProcessMemory,JobMemory,PeakProcessMemory,PeakJobMemory; }
 public sealed class Observation { public int ProcessId; public string Name; public string ImagePath; public string FirstObservedUtc; }
 public sealed class Result { public uint RootProcessId; public uint ExitCode; public string Reason; public long DurationMilliseconds; public bool SuspendedBeforeAssignment; public bool JobAssigned; public bool JobClosed; public List<Observation> Processes=new List<Observation>(); }
 [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr security,string name);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int info,IntPtr buffer,uint length);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int info,IntPtr buffer,uint length,IntPtr returned);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint exitCode);
 [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref Startup startup,out ProcessInfo process);
 [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr CreateFile(string file,uint access,uint share,ref Security security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint exitCode);
 [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr value,uint milliseconds);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 static void Require(bool success,string operation) { if(!success)throw new Win32Exception(Marshal.GetLastWin32Error(),operation); }
 static bool Valid(IntPtr handle) { return handle!=IntPtr.Zero && handle!=new IntPtr(-1); }
 public static Result Run(string target,string directory,string output,int seconds) {
  IntPtr job=IntPtr.Zero,stdout=IntPtr.Zero,stderr=IntPtr.Zero,stdin=IntPtr.Zero,buffer=IntPtr.Zero;
  ProcessInfo process=new ProcessInfo(); Result result=new Result(); Stopwatch timer=new Stopwatch();
  try {
   job=CreateJobObject(IntPtr.Zero,null);Require(Valid(job),"CreateJobObject");
   ExtendedLimits limits=new ExtendedLimits();limits.Basic.Flags=0x2000|0x100|0x200|0x8;limits.Basic.ActiveProcesses=32;
   limits.ProcessMemory=new UIntPtr(536870912);limits.JobMemory=new UIntPtr(1073741824);
   buffer=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ExtendedLimits)));Marshal.StructureToPtr(limits,buffer,false);
   Require(SetInformationJobObject(job,9,buffer,(uint)Marshal.SizeOf(typeof(ExtendedLimits))),"SetInformationJobObject");Marshal.FreeHGlobal(buffer);buffer=IntPtr.Zero;
   Security security=new Security();security.Length=Marshal.SizeOf(typeof(Security));security.Inherit=true;
   stdout=CreateFile(Path.Combine(output,"stdout.txt"),0x40000000,1,ref security,2,0x80,IntPtr.Zero);Require(Valid(stdout),"Create stdout");
   stderr=CreateFile(Path.Combine(output,"stderr.txt"),0x40000000,1,ref security,2,0x80,IntPtr.Zero);Require(Valid(stderr),"Create stderr");
   stdin=CreateFile("NUL",0x80000000,3,ref security,3,0x80,IntPtr.Zero);Require(Valid(stdin),"Create stdin");
   Startup startup=new Startup();startup.Size=(uint)Marshal.SizeOf(typeof(Startup));startup.Flags=0x101;startup.Input=stdin;startup.Output=stdout;startup.Error=stderr;
   Require(CreateProcess(target,new StringBuilder("\""+target+"\""),IntPtr.Zero,IntPtr.Zero,true,0x08000004,IntPtr.Zero,directory,ref startup,out process),"Create suspended target");
   result.RootProcessId=process.ProcessId;result.SuspendedBeforeAssignment=true;
   Require(AssignProcessToJobObject(job,process.Process),"Assign target before execution");result.JobAssigned=true;
   Require(ResumeThread(process.Thread)!=0xffffffff,"Resume target");timer.Start();result.Reason="Completed";
   buffer=Marshal.AllocHGlobal(8+IntPtr.Size*64);HashSet<int> seen=new HashSet<int>();
   while(true) {
    Require(QueryInformationJobObject(job,3,buffer,(uint)(8+IntPtr.Size*64),IntPtr.Zero),"Query job process list");
    int count=Marshal.ReadInt32(buffer,4);
    for(int i=0;i<Math.Min(count,64);i++) {
     int id=Marshal.ReadIntPtr(buffer,8+i*IntPtr.Size).ToInt32();if(!seen.Add(id))continue;
     Observation observation=new Observation();observation.ProcessId=id;observation.FirstObservedUtc=DateTime.UtcNow.ToString("o");
     try { using(Process current=Process.GetProcessById(id)){observation.Name=current.ProcessName;try{observation.ImagePath=current.MainModule.FileName;}catch{}} } catch {}
     result.Processes.Add(observation);
    }
    if(count==0)break;
    if(timer.ElapsedMilliseconds>seconds*1000L){result.Reason="Timeout";break;}
    if(new FileInfo(Path.Combine(output,"stdout.txt")).Length+new FileInfo(Path.Combine(output,"stderr.txt")).Length>8388608L){result.Reason="OutputLimit";break;}
    Thread.Sleep(100);
   }
   if(result.Reason!="Completed")Require(TerminateJobObject(job,124),"Terminate bounded job");
   WaitForSingleObject(process.Process,5000);uint exitCode;Require(GetExitCodeProcess(process.Process,out exitCode),"Get exit code");result.ExitCode=exitCode;
   result.DurationMilliseconds=timer.ElapsedMilliseconds;
  } finally {
   if(Valid(process.Process) && !result.JobAssigned)TerminateProcess(process.Process,125);
   if(Valid(job)){CloseHandle(job);result.JobClosed=true;}
   if(Valid(process.Thread))CloseHandle(process.Thread);if(Valid(process.Process))CloseHandle(process.Process);
   if(Valid(stdout))CloseHandle(stdout);if(Valid(stderr))CloseHandle(stderr);if(Valid(stdin))CloseHandle(stdin);if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);
  }
  return result;
 }
}
'@
    Add-Type -TypeDefinition $native -Language CSharp
    # Compile the trusted observer before the baseline so its temporary compiler
    # artifacts are not presented as changes caused by the supplied executable.
    Get-GuestFileInventory|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $output 'files-before.json') -Encoding utf8
    Get-GuestRegistryInventory|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $output 'registry-before.json') -Encoding utf8
    $record.Execution=[ProfileAnalysisGuestJob]::Run($target,'C:\ProfileAnalysis\Work',$output,$TimeoutSeconds)
    $record.Status=if($record.Execution.Reason -eq 'Completed'){'Completed'}else{'Partial'}
} catch {$record.Status='Failed';$record.Error=$_.Exception.Message}
finally {
    try{$record.TargetUnchanged=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $ExpectedSHA256}catch{$record.TargetUnchanged=$false}
    try{Get-GuestFileInventory|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $output 'files-after.json') -Encoding utf8}catch{$record.Limitations+=('Post-run file inventory failed: '+$_.Exception.Message)}
    try{Get-GuestRegistryInventory|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $output 'registry-after.json') -Encoding utf8}catch{$record.Limitations+=('Post-run registry inventory failed: '+$_.Exception.Message)}
    try{@{Connections=@(Get-NetTCPConnection -ErrorAction Stop|Select-Object -First 256 LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess)}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $output 'network-after.json') -Encoding utf8}catch{$record.Limitations+=('Post-run connection inventory failed: '+$_.Exception.Message)}
    $record.FinishedUtc=[DateTime]::UtcNow.ToString('o')
    $record|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $output 'runtime.json') -Encoding utf8
    Write-Output ('PROFILE_ANALYSIS_RUNTIME='+$record.Status)
}
