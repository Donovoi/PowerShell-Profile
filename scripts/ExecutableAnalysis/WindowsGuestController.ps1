# Trusted management process inside the owned disposable guest. Never runs on host.
#requires -Version 5.1
$ErrorActionPreference='Stop'
$configurationPath='C:\ProfileAnalysis\Private\launch.json'
$taskName='PowerShellProfile-ExecutableAnalysis'
$taskCreated=$false
$folder=$null
$observation=[ordered]@{Status='Failed';StartedUtc=[DateTime]::UtcNow.ToString('o');LaunchMethod='ScheduledTaskPasswordLogonLimited';CredentialRemovedBeforeLaunch=$false;RunnerStarted=$false;RunnerExitCode=$null;TaskRemoved=$false;Error=$null}
$observation.Phases=@()
function Write-ControllerProgress {
    param([string]$Phase)
    $observation.Phases+=@{Name=$Phase;Utc=[DateTime]::UtcNow.ToString('o')}
    $observation|ConvertTo-Json -Depth 5|Set-Content -LiteralPath 'C:\ProfileAnalysis\Private\controller.json' -Encoding utf8
}
try {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'The profile-loading controller requires its management administrator token.'}
    $configuration=Get-Content -LiteralPath $configurationPath -Raw|ConvertFrom-Json
    Remove-Item -LiteralPath $configurationPath -Force
    if(Test-Path -LiteralPath $configurationPath){throw 'The private launch credential was not removed.'}
    $observation.CredentialRemovedBeforeLaunch=$true
    Write-Output 'PROFILE_ANALYSIS_LAUNCH_CREDENTIAL_REMOVED=True'
    if($configuration.UserName -notmatch '^[A-Za-z0-9._-]{1,64}$' -or $configuration.ExpectedSHA256 -notmatch '^[a-fA-F0-9]{64}$' -or $configuration.TimeoutSeconds -lt 1 -or $configuration.TimeoutSeconds -gt 600){throw 'Invalid fixed guest launch configuration.'}
    # Password-logon tasks receive a Windows user profile and supported desktop.
    # Credentials are never placed in a process command line or task action.
    Write-ControllerProgress 'ConnectTaskScheduler'
    $scheduler=New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $folder=$scheduler.GetFolder('\')
    if(@($folder.GetTasks(1)|Where-Object Name -EQ $taskName).Count){throw 'The clean baseline unexpectedly contains the analysis task.'}
    $command="& 'C:\ProfileAnalysis\Runner.ps1' -TimeoutSeconds "+[int]$configuration.TimeoutSeconds+" -ExpectedSHA256 '"+$configuration.ExpectedSHA256+"' 1> 'C:\ProfileAnalysis\Results\runner-stdout.txt' 2> 'C:\ProfileAnalysis\Results\runner-stderr.txt'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $definition=$scheduler.NewTask(0)
    $definition.Principal.UserId=$env:COMPUTERNAME+'\'+$configuration.UserName
    $definition.Principal.LogonType=1 # TASK_LOGON_PASSWORD
    $definition.Principal.RunLevel=0 # TASK_RUNLEVEL_LUA
    $definition.Settings.Enabled=$true
    $definition.Settings.AllowDemandStart=$true
    $definition.Settings.DisallowStartIfOnBatteries=$false
    $definition.Settings.StopIfGoingOnBatteries=$false
    $definition.Settings.MultipleInstances=2 # TASK_INSTANCES_IGNORE_NEW
    $definition.Settings.ExecutionTimeLimit='PT'+([int]$configuration.TimeoutSeconds+300)+'S'
    $action=$definition.Actions.Create(0) # TASK_ACTION_EXEC
    $action.Path='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $action.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+$encoded
    $action.WorkingDirectory='C:\ProfileAnalysis\Work'
    # TASK_CREATE (2), never UPDATE: a colliding task must not be overwritten.
    Write-ControllerProgress 'RegisterLimitedTask'
    $registered=$folder.RegisterTaskDefinition($taskName,$definition,2,$definition.Principal.UserId,$configuration.UserPassword,1)
    $taskCreated=$true
    $taskPrincipal=$registered.Definition.Principal
    if($taskPrincipal.LogonType -ne 1 -or $taskPrincipal.RunLevel -ne 0){throw 'The analysis task did not retain limited password-logon settings.'}
    $expectedAccountName=$env:COMPUTERNAME+'\'+$configuration.UserName
    $expectedAccount=New-Object Security.Principal.NTAccount($expectedAccountName)
    $registeredSid=if($taskPrincipal.UserId -match '^S-1-'){
        ([Security.Principal.SecurityIdentifier]::new([string]$taskPrincipal.UserId)).Value
    }else{
        $registeredAccount=New-Object Security.Principal.NTAccount($taskPrincipal.UserId)
        $registeredAccount.Translate([Security.Principal.SecurityIdentifier]).Value
    }
    $expectedSid=$expectedAccount.Translate([Security.Principal.SecurityIdentifier]).Value
    if($registeredSid -ne $expectedSid){throw 'The analysis task principal does not match the owned standard account SID.'}
    if(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop|Where-Object {$_.SID.Value -eq $expectedSid}){throw 'The controller refuses an Administrators member, including a filtered administrator token.'}
    $observation.TaskPrincipal=@{UserId=$expectedAccountName;RegisteredUserId=$taskPrincipal.UserId;UserSid=$registeredSid;ExpectedUserSid=$expectedSid;LogonType='Password';RunLevel='Limited'}
    Write-ControllerProgress 'VerifyGuestBatchLogonRight'
    # This grants one logon right to the verified standard account inside the
    # disposable guest. It grants no administrator membership or process privilege.
    $batchLogonNative=@'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class ProfileAnalysisBatchLogon {
 [StructLayout(LayoutKind.Sequential)] struct Attributes { public uint Length; public IntPtr Root,Name; public uint Flags; public IntPtr Security,Quality; }
 [StructLayout(LayoutKind.Sequential)] struct Unicode { public ushort Length,MaximumLength; public IntPtr Buffer; }
 [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system,ref Attributes attributes,uint access,out IntPtr policy);
 [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr policy,byte[] sid,Unicode[] rights,uint count);
 [DllImport("advapi32.dll")] static extern uint LsaEnumerateAccountRights(IntPtr policy,byte[] sid,out IntPtr rights,out uint count);
 [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
 [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr memory);
 [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LogonUser(string user,string domain,string password,int type,int provider,out IntPtr token);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 static void Check(uint status){if(status!=0)throw new Win32Exception((int)LsaNtStatusToWinError(status));}
 public static bool Grant(string sidText,string user,string domain,string password){
  SecurityIdentifier sid=new SecurityIdentifier(sidText);byte[] bytes=new byte[sid.BinaryLength];sid.GetBinaryForm(bytes,0);
  IntPtr policy=IntPtr.Zero,buffer=IntPtr.Zero,rights=IntPtr.Zero;
  try {
   Attributes attributes=new Attributes();attributes.Length=(uint)Marshal.SizeOf(typeof(Attributes));
   Check(LsaOpenPolicy(IntPtr.Zero,ref attributes,0x810,out policy));
   string name="SeBatchLogonRight";buffer=Marshal.StringToHGlobalUni(name);
   Unicode right=new Unicode();right.Buffer=buffer;right.Length=(ushort)(name.Length*2);right.MaximumLength=(ushort)(right.Length+2);
   Check(LsaAddAccountRights(policy,bytes,new Unicode[]{right},1));
   uint count;Check(LsaEnumerateAccountRights(policy,bytes,out rights,out count));bool found=false;
   for(uint i=0;i<count;i++){
    Unicode entry=(Unicode)Marshal.PtrToStructure(IntPtr.Add(rights,checked((int)i*Marshal.SizeOf(typeof(Unicode)))),typeof(Unicode));
    string value=Marshal.PtrToStringUni(entry.Buffer,entry.Length/2);
    if(value=="SeDenyBatchLogonRight")throw new InvalidOperationException("The dedicated account has an explicit deny-batch-logon right.");
    if(value==name)found=true;
   }
   if(!found)return false;
   IntPtr token;
   if(!LogonUser(user,domain,password,4,0,out token))throw new Win32Exception(Marshal.GetLastWin32Error(),"Verify dedicated batch logon");
   try {
    using(WindowsIdentity identity=new WindowsIdentity(token)){
     if(identity.User.Value!=sidText)throw new InvalidOperationException("Batch logon returned the wrong identity.");
     foreach(IdentityReference group in identity.Groups)if(group.Value=="S-1-5-32-544")throw new InvalidOperationException("Batch logon refuses an Administrators group member.");
     if(new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))throw new InvalidOperationException("Batch logon refuses an administrator token.");
    }
   } finally {CloseHandle(token);}
   return true;
  } finally {if(rights!=IntPtr.Zero)LsaFreeMemory(rights);if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);if(policy!=IntPtr.Zero)LsaClose(policy);}
 }
}
'@
    [type]$batchLogonType=Add-Type -TypeDefinition $batchLogonNative -Language CSharp -PassThru|Where-Object {$_.IsPublic -and $_.GetMethod('Grant')}
    if(-not $batchLogonType::Grant($registeredSid,$configuration.UserName,$env:COMPUTERNAME,$configuration.UserPassword)){throw 'The dedicated account batch-logon right could not be verified.'}
    $observation.BatchLogonRightVerified=$true
    if($registered.Xml.Contains([string]$configuration.UserPassword)){throw 'The analysis task definition unexpectedly exposed its credential.'}
    $configuration.UserPassword=$null
    Write-ControllerProgress 'StartLimitedTask'
    $before=$registered.LastRunTime
    $null=$registered.Run($null)
    Write-ControllerProgress 'ObserveTask'
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        $task=$folder.GetTask($taskName)
        if($task.State -eq 4 -or $task.LastRunTime -gt $before){$observation.RunnerStarted=$true}
        if($observation.RunnerStarted -and $task.State -notin 2,4){$observation.RunnerExitCode=$task.LastTaskResult;break}
        if(-not $observation.RunnerStarted -and $task.State -notin 2,4 -and $task.LastTaskResult -notin 0,267011,267009,267045){throw ('The task failed to start. Native task result: '+$task.LastTaskResult)}
        if(-not $observation.RunnerStarted -and $timer.Elapsed.TotalSeconds -gt 30){throw ('The task did not start within 30 seconds. Last task result: '+$task.LastTaskResult)}
        if($timer.Elapsed.TotalSeconds -gt ([int]$configuration.TimeoutSeconds+300)){throw 'The trusted guest runner exceeded its preparation, target, and observation deadline.'}
        Start-Sleep -Milliseconds 500
    }
    Write-ControllerProgress 'ValidateRunnerOutcome'
    if($observation.RunnerExitCode -ne 0){throw ('The trusted runner task failed. Task result: '+$observation.RunnerExitCode)}
    if(-not(Test-Path -LiteralPath 'C:\ProfileAnalysis\Results\runtime.json')){throw ('The trusted runner exited before producing runtime.json. Task result: '+$observation.RunnerExitCode)}
    $report=Get-Item -LiteralPath 'C:\ProfileAnalysis\Results\runtime.json'
    if($report.Length -gt 1MB){throw 'The guest runtime report exceeded its size limit.'}
    $result=Get-Content -LiteralPath $report.FullName -Raw|ConvertFrom-Json
    if($result.Status -notin 'Completed','Partial','Failed'){throw 'The guest runtime status is invalid.'}
    Write-Output ('PROFILE_ANALYSIS_RUNTIME='+$result.Status)
} catch {$observation.Error=$_.Exception.Message;throw} finally {
    try {
        if($taskCreated){
            $observation.Phases+=@{Name='RemoveOwnedTask';Utc=[DateTime]::UtcNow.ToString('o')}
            try {$folder.GetTask($taskName).Stop(0)}
            finally {
                $folder.DeleteTask($taskName,0)
                if(@($folder.GetTasks(1)|Where-Object Name -EQ $taskName).Count){throw 'The analysis task was not removed.'}
                $observation.TaskRemoved=$true
            }
        }
    } catch {$observation.Error=$_.Exception.Message;throw} finally {
        try{if(Test-Path -LiteralPath $configurationPath){Remove-Item -LiteralPath $configurationPath -Force}}
        finally{
            if(-not $observation.Error -and $observation.TaskRemoved -and $observation.RunnerStarted -and $observation.RunnerExitCode -eq 0){$observation.Status='Completed'}
            $observation.CompletedUtc=[DateTime]::UtcNow.ToString('o');$observation|ConvertTo-Json -Depth 5|Set-Content -LiteralPath 'C:\ProfileAnalysis\Private\controller.json' -Encoding utf8
        }
    }
}
