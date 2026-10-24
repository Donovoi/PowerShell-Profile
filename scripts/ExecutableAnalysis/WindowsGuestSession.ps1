#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Configure','Cleanup','Verify')][string]$Mode='Verify',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$')][string]$ExpectedUser
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$privateDirectory='C:\ProfileAnalysis\Private'
$trustedScript=Join-Path $privateDirectory 'WindowsGuestSession.ps1'
$configurationPath=Join-Path $privateDirectory 'session-config.json'
$ownershipPath=Join-Path $privateDirectory 'session-ownership.json'
$cleanupPath=Join-Path $privateDirectory 'interactive-session-cleanup.json'
$winlogonPath='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Assert-SessionRegularPath([string]$Path,[switch]$AllowMissing) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if(-not $item){if(-not $AllowMissing){throw 'A required private session file is unavailable.'};$parent=Split-Path $Path -Parent}
    else{if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Private session files must be regular files.'};$parent=$item.DirectoryName}
    while($parent){$directory=Get-Item -LiteralPath $parent -Force;if(-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Private session paths must not traverse reparse points.'};$parent=Split-Path $directory.FullName -Parent}
}
function Read-SessionJson([string]$Path) {
    Assert-SessionRegularPath $Path
    if((Get-Item -LiteralPath $Path).Length -gt 16384){throw 'The private session record exceeds its size budget.'}
    try{return (Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json)}catch{throw 'The private session record is not valid JSON.'}
}
function Write-SessionJson([string]$Path,[object]$Value,[switch]$CreateNew) {
    Assert-SessionRegularPath $Path -AllowMissing
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 6))
    $stream=[IO.File]::Open($Path,$(if($CreateNew){[IO.FileMode]::CreateNew}else{[IO.FileMode]::Create}),[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
}
function Get-SessionTask([object]$Folder,[string]$Name) {
    try{return $Folder.GetTask($Name)}catch{$errorObject=$_.Exception;while($errorObject.InnerException){$errorObject=$errorObject.InnerException};if($errorObject.HResult -eq -2147024894){return $null};throw}
}
function Read-SessionOwnership {
    $owner=Read-SessionJson $ownershipPath
    if($owner.Schema -ne 'PowerShellProfile.WindowsInteractiveSession.v1' -or $owner.RunId -notmatch '^[a-f0-9]{32}$' -or $owner.TaskName -cne ('ProfileAnalysisSessionCleanup-'+$owner.RunId) -or $owner.UserName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$' -or $owner.UserSid -notmatch '^S-1-5-21-[0-9-]+$'){throw 'The private session ownership record is invalid.'}
    if($owner.ScriptSHA256 -ne (Get-FileHash -LiteralPath $trustedScript -Algorithm SHA256).Hash){throw 'The trusted session helper changed after configuration.'}
    if($ExpectedUser -and $owner.UserName -ine $ExpectedUser){throw 'The requested user does not match session ownership.'}
    return $owner
}
function Assert-SessionLocalAccount([string]$UserName,[string]$ExpectedSid) {
    $user=Get-LocalUser -Name $UserName
    if(-not $user.Enabled -or $user.SID.Value -ne $ExpectedSid){throw 'The dedicated local session account does not match its expected identity.'}
    $administratorMembers=@(Get-LocalGroupMember -SID 'S-1-5-32-544')
    if(@($administratorMembers|Where-Object {$_.SID.Value -eq $ExpectedSid}).Count){throw 'The dedicated session account must not be an administrator.'}
}
function Get-SessionRegistryValue([string]$Name) {
    $key=Get-Item -LiteralPath $winlogonPath
    if($key.GetValueNames() -contains $Name){return $key.GetValue($Name)}
    return $null
}

function Test-SessionRegistryValue([string]$Name) {
    return (Get-Item -LiteralPath $winlogonPath).GetValueNames() -contains $Name
}

function Assert-SessionAutoLogonBaseline {
    [CmdletBinding()]
    param([bool]$SecretPresent,[bool]$PlaintextPasswordPresent,[object]$AutoAdminLogon,[object]$AutoLogonCount,
        [bool]$SecretEmpty,[bool]$OwnedCredentialMatch,[bool]$BaselineMigrationEnabled,
        [object]$DefaultUserName,[object]$DefaultDomainName,[string]$ComputerName=$env:COMPUTERNAME)
    $disabled=$null -ne $AutoAdminLogon -and [string]$AutoAdminLogon -ceq '0'
    $absent=$null -eq $AutoAdminLogon -and $null -eq $AutoLogonCount
    $localDomain=$null -eq $DefaultDomainName -or ($DefaultDomainName -is [string] -and ($DefaultDomainName -ceq '' -or $DefaultDomainName -ceq '.' -or ($ComputerName -and $DefaultDomainName -ieq $ComputerName)))
    $validUser=$DefaultUserName -is [string] -and $DefaultUserName -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'
    $knownSecret=$SecretPresent -and $BaselineMigrationEnabled -and $disabled -and $localDomain -and ($SecretEmpty -or ($OwnedCredentialMatch -and $validUser))
    if($PlaintextPasswordPresent -or -not($disabled -or $absent) -or ($SecretPresent -and -not $knownSecret) -or (-not $SecretPresent -and ($SecretEmpty -or $OwnedCredentialMatch)) -or ($SecretEmpty -and $OwnedCredentialMatch)){
        $mode=if($null -eq $AutoAdminLogon){'<absent>'}elseif([string]$AutoAdminLogon -cin '0','1'){[string]$AutoAdminLogon}else{'<unexpected>'}
        [long]$parsedCount=0
        $count=if($null -eq $AutoLogonCount){'<absent>'}elseif([long]::TryParse([string]$AutoLogonCount,[ref]$parsedCount)){$parsedCount.ToString()}else{'<unexpected>'}
        throw ('An existing autologon configuration must not be replaced. LsaSecretPresent={0}; PlaintextPasswordValuePresent={1}; AutoAdminLogon={2}; AutoLogonCount={3}.' -f $SecretPresent,$PlaintextPasswordPresent,$mode,$count)
    }
    [pscustomobject]@{Classification=if(-not $SecretPresent){'Absent'}elseif($SecretEmpty){'Empty'}else{'OwnedProvisioningCredential'};UserName=if($SecretPresent -and -not $SecretEmpty){$DefaultUserName}else{$null}}
}

function Get-SessionBaselineCredential {
    [CmdletBinding()]
    param([object]$Value)
    if($null -eq $Value){return}
    if($Value -isnot [Array] -or $Value.Count -gt 3){throw 'BaselineCredentials must be an array of at most three owned credentials.'}
    foreach($credential in $Value){
        if($null -eq $credential -or $credential -isnot [pscustomobject] -or @($credential.PSObject.Properties).Count -ne 2 -or -not $credential.PSObject.Properties['UserName'] -or -not $credential.PSObject.Properties['UserPassword']){throw 'An owned baseline credential has invalid fields.'}
        if($credential.UserName -isnot [string] -or $credential.UserName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$' -or $credential.UserPassword -isnot [string] -or $credential.UserPassword.Length -lt 1 -or $credential.UserPassword.Length -gt 1024 -or $credential.UserPassword.IndexOf([char]0) -ge 0){throw 'An owned baseline credential has invalid values.'}
    }
    return $Value
}

function Get-SessionAutoLogonBaseline {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword','',Justification='Consumes validated credentials from the administrator-only guest configuration for in-memory native comparison, clears temporary references, and never returns credential values.')]
    [CmdletBinding()]
    param([object[]]$BaselineCredentials=@())
    $defaultUser=Get-SessionRegistryValue 'DefaultUserName'
    $matching=@($BaselineCredentials|Where-Object {$_.UserName -ieq $defaultUser})
    [string[]]$passwords=@($matching|ForEach-Object {$_.UserPassword})
    try{$secret=[ProfileAnalysisSessionNative]::InspectSecret($passwords)}finally{for($i=0;$i -lt $passwords.Count;$i++){$passwords[$i]=$null}}
    Assert-SessionAutoLogonBaseline -SecretPresent $secret.Present -SecretEmpty $secret.Empty -OwnedCredentialMatch ($secret.MatchedCredentialIndex -ge 0) -BaselineMigrationEnabled ($BaselineCredentials.Count -gt 0) -DefaultUserName $defaultUser -DefaultDomainName (Get-SessionRegistryValue 'DefaultDomainName') -PlaintextPasswordPresent (Test-SessionRegistryValue 'DefaultPassword') -AutoAdminLogon (Get-SessionRegistryValue 'AutoAdminLogon') -AutoLogonCount (Get-SessionRegistryValue 'AutoLogonCount')
}

function Enter-SessionMutationLock {
    [CmdletBinding()]
    [OutputType([IO.FileStream])]
    param([string]$Path,[ValidateSet('Configure','Cleanup')][string]$Operation,[ValidateRange(0,30)][int]$CleanupWaitSeconds=15)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        try{return [IO.File]::Open($Path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch{
            $cause=$_.Exception.GetBaseException();$code=$cause.HResult -band 65535
            if($Operation -ne 'Cleanup' -or $cause -isnot [IO.IOException] -or $code -notin 32,33 -or $timer.Elapsed.TotalSeconds -ge $CleanupWaitSeconds){throw}
            Start-Sleep -Milliseconds 100
        }
    }
}

function Wait-SessionProof {
    [CmdletBinding()]
    param([scriptblock]$Probe,[ValidateRange(0,60)][int]$TimeoutSeconds=60,[ValidateRange(10,500)][int]$PollMilliseconds=200)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        try{return (& $Probe)}catch{if($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw};Start-Sleep -Milliseconds $PollMilliseconds}
    }
}

function Get-SessionPowerCfgArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([ValidateSet('SetAc','SetDc','SetActive')][string]$Operation,[guid]$SchemeId,[ValidateSet('Monitor','Standby')][string]$Setting='Monitor')
    if($SchemeId -eq [guid]::Empty){throw 'The guest active power scheme identity is invalid.'}
    if($Operation -eq 'SetActive'){return [string[]]@('/setactive',$SchemeId.ToString('D'))}
    $option=if($Operation -eq 'SetAc'){'/setacvalueindex'}else{'/setdcvalueindex'}
    $group=if($Setting -eq 'Monitor'){'7516b95f-f776-4464-8c53-06167f40cc99'}else{'238c9fa8-0aad-41ed-83f4-97be242c8f20'}
    $settingId=if($Setting -eq 'Monitor'){'3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'}else{'29f6c1db-86da-48c5-9fdb-f2b67b1f44da'}
    return [string[]]@($option,$SchemeId.ToString('D'),$group,$settingId,'0')
}

function Invoke-SessionPowerCfg {
    [CmdletBinding()]
    param([ValidateSet('SetAc','SetDc','SetActive')][string]$Operation,[guid]$SchemeId,[ValidateSet('Monitor','Standby')][string]$Setting='Monitor',[ValidateRange(1,15)][int]$TimeoutSeconds=15)
    $executable=Join-Path $env:SystemRoot 'System32\powercfg.exe';Assert-SessionRegularPath $executable
    $arguments=@(Get-SessionPowerCfgArgumentList -Operation $Operation -SchemeId $SchemeId -Setting $Setting)
    $info=[Diagnostics.ProcessStartInfo]::new($executable)
    # Every argument is a fixed operation, a canonical GUID or the literal zero.
    # This is compatible with .NET Framework without a shell or arbitrary text.
    $info.Arguments=$arguments -join ' ';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    try{
        if(-not $process.Start()){throw 'The guest power-policy command did not start.'}
        $started=$true;$timer=[Diagnostics.Stopwatch]::StartNew()
        $buffers=@([char[]]::new(2048),[char[]]::new(2048));$readers=@($process.StandardOutput,$process.StandardError)
        $ended=@($false,$false);$pending=@($readers[0].ReadAsync($buffers[0],0,2048),$readers[1].ReadAsync($buffers[1],0,2048));$characters=0
        while(-not($ended[0] -and $ended[1] -and $process.HasExited)){
            if($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds){throw 'The guest power-policy command exceeded its deadline.'}
            foreach($index in 0..1){
                if($ended[$index] -or -not $pending[$index].IsCompleted){continue}
                $count=$pending[$index].GetAwaiter().GetResult()
                if($count -eq 0){$ended[$index]=$true;continue}
                $characters+=$count;if($characters -gt 16384){throw 'The guest power-policy command exceeded its output limit.'}
                $pending[$index]=$readers[$index].ReadAsync($buffers[$index],0,2048)
            }
            Start-Sleep -Milliseconds 10
        }
        if($process.ExitCode -ne 0){throw ('The guest power-policy command failed with exit code '+$process.ExitCode+'.')}
    }finally{
        if($started -and -not $process.HasExited){try{$process.Kill();$null=$process.WaitForExit(5000)}catch{Write-Verbose 'The failed guest power-policy process could not confirm termination.'}}
        $process.Dispose()
    }
}

function Get-SessionPowerPolicy {
    return [ProfileAnalysisSessionNative]::PowerPolicy()
}

function Assert-SessionPowerPolicy {
    [CmdletBinding()]
    param([object]$Policy,[string]$ExpectedSchemeId,[switch]$AllowTimeouts)
    [guid]$scheme=[guid]::Empty
    if(-not $Policy -or -not $Policy.PSObject.Properties['ActiveSchemeId'] -or -not [guid]::TryParse([string]$Policy.ActiveSchemeId,[ref]$scheme) -or $scheme -eq [guid]::Empty){throw 'The guest active power scheme identity is invalid.'}
    if($ExpectedSchemeId -and $scheme.ToString('D') -ine $ExpectedSchemeId){throw 'The guest active power scheme changed after configuration.'}
    foreach($name in 'MonitorTimeoutAcSeconds','MonitorTimeoutDcSeconds','StandbyTimeoutAcSeconds','StandbyTimeoutDcSeconds'){
        if(-not $Policy.PSObject.Properties[$name]){throw 'A required guest power-policy value is unavailable.'}
        $value=$Policy.$name
        if($value -isnot [uint32] -and $value -isnot [int32] -and $value -isnot [int64]){throw 'A guest power-policy value has an invalid type.'}
        if($value -lt 0 -or $value -gt [uint32]::MaxValue -or (-not $AllowTimeouts -and $value -ne 0)){throw ('The required guest power-policy value was not verified: '+$name+'.')}
    }
}

function Get-SessionVerifiedPowerPolicy {
    [CmdletBinding()]
    param([string]$ExpectedSchemeId)
    $policy=Get-SessionPowerPolicy;Assert-SessionPowerPolicy -Policy $policy -ExpectedSchemeId $ExpectedSchemeId
    [pscustomobject]@{Status='Verified';ActiveSchemeId=$policy.ActiveSchemeId;MonitorTimeoutAcSeconds=$policy.MonitorTimeoutAcSeconds;MonitorTimeoutDcSeconds=$policy.MonitorTimeoutDcSeconds;StandbyTimeoutAcSeconds=$policy.StandbyTimeoutAcSeconds;StandbyTimeoutDcSeconds=$policy.StandbyTimeoutDcSeconds;VerifiedUtc=[DateTime]::UtcNow.ToString('o')}
}

function Set-SessionPowerPolicy {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Fixed guest power settings are part of mandatory isolated-session preparation; this helper runs only after the guest path and administrator guards.')]
    [CmdletBinding()]
    param()
    $before=Get-SessionPowerPolicy;Assert-SessionPowerPolicy -Policy $before -AllowTimeouts
    $scheme=[guid]$before.ActiveSchemeId
    foreach($setting in 'Monitor','Standby'){
        foreach($operation in 'SetAc','SetDc'){Invoke-SessionPowerCfg -Operation $operation -SchemeId $scheme -Setting $setting}
    }
    Invoke-SessionPowerCfg -Operation SetActive -SchemeId $scheme
    $verified=Get-SessionVerifiedPowerPolicy -ExpectedSchemeId $scheme.ToString('D')
    [pscustomobject]@{Before=$before;Verified=$verified}
}

$sessionNative=@'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class ProfileAnalysisSessionNative {
 [DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr root,out IntPtr scheme);
 [DllImport("powrprof.dll")] static extern uint PowerReadACValueIndex(IntPtr root,ref Guid scheme,ref Guid subgroup,ref Guid setting,out uint value);
 [DllImport("powrprof.dll")] static extern uint PowerReadDCValueIndex(IntPtr root,ref Guid scheme,ref Guid subgroup,ref Guid setting,out uint value);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
 public sealed class PowerPolicyObservation {public string ActiveSchemeId;public uint MonitorTimeoutAcSeconds,MonitorTimeoutDcSeconds,StandbyTimeoutAcSeconds,StandbyTimeoutDcSeconds;}
 static uint ReadPowerIndex(bool ac,Guid scheme,Guid group,Guid setting){
  uint value;uint error=ac?PowerReadACValueIndex(IntPtr.Zero,ref scheme,ref group,ref setting,out value):PowerReadDCValueIndex(IntPtr.Zero,ref scheme,ref group,ref setting,out value);
  if(error!=0)throw new Win32Exception((int)error,"Read required guest power-policy value");return value;
 }
 public static PowerPolicyObservation PowerPolicy(){
  IntPtr pointer;uint error=PowerGetActiveScheme(IntPtr.Zero,out pointer);
  if(error!=0)throw new Win32Exception((int)error,"Read guest active power scheme");
  if(pointer==IntPtr.Zero)throw new InvalidOperationException("The guest active power scheme is unavailable.");
  Guid scheme;try{scheme=(Guid)Marshal.PtrToStructure(pointer,typeof(Guid));}finally{LocalFree(pointer);}
  Guid video=new Guid("7516b95f-f776-4464-8c53-06167f40cc99"),monitor=new Guid("3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e");
  Guid sleep=new Guid("238c9fa8-0aad-41ed-83f4-97be242c8f20"),standby=new Guid("29f6c1db-86da-48c5-9fdb-f2b67b1f44da");
  PowerPolicyObservation result=new PowerPolicyObservation{ActiveSchemeId=scheme.ToString("D"),MonitorTimeoutAcSeconds=ReadPowerIndex(true,scheme,video,monitor),MonitorTimeoutDcSeconds=ReadPowerIndex(false,scheme,video,monitor),StandbyTimeoutAcSeconds=ReadPowerIndex(true,scheme,sleep,standby),StandbyTimeoutDcSeconds=ReadPowerIndex(false,scheme,sleep,standby)};
  IntPtr current;error=PowerGetActiveScheme(IntPtr.Zero,out current);
  if(error!=0)throw new Win32Exception((int)error,"Recheck guest active power scheme");
  if(current==IntPtr.Zero)throw new InvalidOperationException("The guest active power scheme is unavailable.");
  try{if((Guid)Marshal.PtrToStructure(current,typeof(Guid))!=scheme)throw new InvalidOperationException("The guest power scheme changed while reading its values.");}finally{LocalFree(current);}
  return result;
 }
 [StructLayout(LayoutKind.Sequential)] struct Unicode {
  public ushort Length; public ushort MaximumLength; public IntPtr Buffer;
 }
 [StructLayout(LayoutKind.Sequential)] struct ObjectAttributes {
  public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
 }
 [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system,ref ObjectAttributes attributes,uint access,out IntPtr handle);
 [DllImport("advapi32.dll")] static extern uint LsaStorePrivateData(IntPtr policy,ref Unicode key,ref Unicode value);
 [DllImport("advapi32.dll",EntryPoint="LsaStorePrivateData")] static extern uint LsaDeletePrivateData(IntPtr policy,ref Unicode key,IntPtr value);
 [DllImport("advapi32.dll")] static extern uint LsaRetrievePrivateData(IntPtr policy,ref Unicode key,out IntPtr value);
 [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
 [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
 [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr memory);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LogonUser(string user,string domain,string password,int type,int provider,out IntPtr token);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
 [DllImport("wtsapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool WTSQuerySessionInformation(IntPtr server,uint session,int information,out IntPtr buffer,out int bytes);
 [DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr memory);
 [DllImport("wtsapi32.dll",SetLastError=true)] static extern bool WTSQueryUserToken(uint session,out IntPtr token);
 static void Check(uint status){if(status!=0)throw new Win32Exception((int)LsaNtStatusToWinError(status));}
 static Unicode Allocate(string value){return new Unicode{Length=checked((ushort)(value.Length*2)),MaximumLength=checked((ushort)(value.Length*2+2)),Buffer=Marshal.StringToCoTaskMemUni(value)};}
 static void Clear(ref Unicode value){if(value.Buffer!=IntPtr.Zero){for(int i=0;i<value.MaximumLength;i++)Marshal.WriteByte(value.Buffer,i,0);Marshal.FreeCoTaskMem(value.Buffer);value.Buffer=IntPtr.Zero;}}
 static IntPtr Policy(uint access){ObjectAttributes attributes=new ObjectAttributes();attributes.Length=Marshal.SizeOf(typeof(ObjectAttributes));IntPtr policy;Check(LsaOpenPolicy(IntPtr.Zero,ref attributes,access,out policy));return policy;}
 public static bool SecretExists(){
  IntPtr policy=Policy(4),data=IntPtr.Zero;Unicode name=Allocate("DefaultPassword");
  try{uint status=LsaRetrievePrivateData(policy,ref name,out data);if(status==0xC0000034)return false;Check(status);return true;}
  finally{if(data!=IntPtr.Zero){Unicode value=(Unicode)Marshal.PtrToStructure(data,typeof(Unicode));if(value.Buffer!=IntPtr.Zero)for(int i=0;i<value.Length;i++)Marshal.WriteByte(value.Buffer,i,0);LsaFreeMemory(data);}Clear(ref name);LsaClose(policy);}
 }
 public sealed class SecretInspection {public bool Present;public bool Empty;public int MatchedCredentialIndex=-1;}
 static bool CompareSecret(Unicode value,string password){
  int difference=value.Length^(password.Length*2);
  for(int index=0;index<value.Length/2;index++){int expected=index<password.Length?password[index]:0;difference|=(ushort)Marshal.ReadInt16(value.Buffer,index*2)^expected;}
  return difference==0&&value.Length>0;
 }
 public static SecretInspection InspectSecret(string[] expectedPasswords){
  if(expectedPasswords==null||expectedPasswords.Length>3)throw new InvalidOperationException("Invalid owned baseline credential count.");
  foreach(string password in expectedPasswords)if(String.IsNullOrEmpty(password)||password.Length>1024||password.IndexOf('\0')>=0)throw new InvalidOperationException("Invalid owned baseline credential value.");
  IntPtr policy=Policy(4),data=IntPtr.Zero;Unicode name=Allocate("DefaultPassword");
  try{
   uint status=LsaRetrievePrivateData(policy,ref name,out data);if(status==0xC0000034)return new SecretInspection();Check(status);
   SecretInspection result=new SecretInspection();result.Present=true;
   if(data==IntPtr.Zero){result.Empty=true;return result;}
   Unicode value=(Unicode)Marshal.PtrToStructure(data,typeof(Unicode));
   if((value.Length&1)!=0||value.Length>value.MaximumLength||(value.Length>0&&value.Buffer==IntPtr.Zero))throw new InvalidOperationException("The baseline secret has an invalid native representation.");
   result.Empty=value.Length==0;
   for(int candidate=0;candidate<expectedPasswords.Length;candidate++){
    if(CompareSecret(value,expectedPasswords[candidate])&&result.MatchedCredentialIndex<0)result.MatchedCredentialIndex=candidate;
   }
   return result;
  }finally{if(data!=IntPtr.Zero){Unicode value=(Unicode)Marshal.PtrToStructure(data,typeof(Unicode));if(value.Buffer!=IntPtr.Zero)for(int i=0;i<Math.Min(value.Length,value.MaximumLength);i++)Marshal.WriteByte(value.Buffer,i,0);LsaFreeMemory(data);}Clear(ref name);LsaClose(policy);}
 }
 public static void StoreSecret(string password){
  IntPtr policy=Policy(32);Unicode name=Allocate("DefaultPassword"),value=new Unicode();
  try{value=Allocate(password);Check(LsaStorePrivateData(policy,ref name,ref value));}finally{Clear(ref value);Clear(ref name);LsaClose(policy);}
 }
 public static void RemoveSecret(){
  IntPtr policy=Policy(32);Unicode name=Allocate("DefaultPassword");
  try{uint status=LsaDeletePrivateData(policy,ref name,IntPtr.Zero);if(status!=0xC0000034)Check(status);}finally{Clear(ref name);LsaClose(policy);}
 }
 static void AssertStandardToken(IntPtr token,string expectedSid){
  using(WindowsIdentity identity=new WindowsIdentity(token)){
   if(identity.User.Value!=expectedSid)throw new InvalidOperationException("The logon token has the wrong user SID.");
   foreach(IdentityReference group in identity.Groups)if(group.Value=="S-1-5-32-544")throw new InvalidOperationException("The logon token includes the Administrators group.");
   if(new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))throw new InvalidOperationException("The logon token is elevated.");
  }
 }
 public static void ValidateCredentials(string user,string password,string expectedSid){
  IntPtr token;if(!LogonUser(user,Environment.MachineName,password,2,0,out token))throw new Win32Exception(Marshal.GetLastWin32Error(),"Validate dedicated local credentials");
  try{AssertStandardToken(token,expectedSid);}finally{CloseHandle(token);}
 }
 static string QueryText(uint session,int field){IntPtr buffer;int bytes;if(!WTSQuerySessionInformation(IntPtr.Zero,session,field,out buffer,out bytes))throw new Win32Exception(Marshal.GetLastWin32Error(),"Query console session");try{if(bytes<2||bytes>4096)throw new InvalidOperationException("Invalid console session text length.");return Marshal.PtrToStringUni(buffer);}finally{WTSFreeMemory(buffer);}}
 public sealed class ConsoleObservation {public uint SessionId;public string UserName;public string DomainName;public string UserSid;public bool Active;public bool StandardTokenVerified;}
 public static ConsoleObservation Console(bool inspectToken){
  uint session=WTSGetActiveConsoleSessionId();if(session==0xFFFFFFFF)throw new InvalidOperationException("No console session is attached.");
  string user=QueryText(session,5),domain=QueryText(session,7);
  if(String.IsNullOrEmpty(user)||!String.Equals(domain,Environment.MachineName,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("The active console does not belong to a local account.");
  IntPtr buffer;int bytes;if(!WTSQuerySessionInformation(IntPtr.Zero,session,8,out buffer,out bytes))throw new Win32Exception(Marshal.GetLastWin32Error(),"Query console connection state");
  try{if(bytes<4||Marshal.ReadInt32(buffer)!=0)throw new InvalidOperationException("The console session is not active.");}finally{WTSFreeMemory(buffer);}
  string sid=((SecurityIdentifier)new NTAccount(domain,user).Translate(typeof(SecurityIdentifier))).Value;
  ConsoleObservation result=new ConsoleObservation{SessionId=session,UserName=user,DomainName=domain,UserSid=sid,Active=true,StandardTokenVerified=false};
  if(inspectToken){IntPtr token;if(!WTSQueryUserToken(session,out token))throw new Win32Exception(Marshal.GetLastWin32Error(),"Query actual console token as SYSTEM");try{AssertStandardToken(token,sid);result.StandardTokenVerified=true;}finally{CloseHandle(token);}}
  return result;
 }
}
'@

function Remove-OwnedSessionConfiguration {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Owned credential cleanup is mandatory and cannot be skipped interactively inside the disposable guest.')]
    [CmdletBinding()]
    param([object]$Owner,[switch]$SkipConsoleProof,[switch]$PreserveAutoLogon)
    $record=[ordered]@{Schema='PowerShellProfile.WindowsInteractiveSessionCleanup.v1';RunId=$Owner.RunId;UserName=$Owner.UserName;UserSid=$Owner.UserSid;StartedUtc=[DateTime]::UtcNow.ToString('o');Success=$false;AutoLogonSecretsRemoved=$false;TaskRemoved=$false;Console=$null;ConsoleVerificationError=$null}
    $failure=$null
    try{
        # Remove secrets before waiting for the interactive desktop to finish logon.
        if(-not $PreserveAutoLogon){
            [ProfileAnalysisSessionNative]::RemoveSecret()
            foreach($name in 'DefaultPassword','AutoAdminLogon','AutoLogonCount','DefaultUserName','DefaultDomainName'){Remove-ItemProperty -LiteralPath $winlogonPath -Name $name -ErrorAction SilentlyContinue}
            if([ProfileAnalysisSessionNative]::SecretExists()){throw 'The owned autologon secret could not be removed.'}
            foreach($name in 'DefaultPassword','AutoAdminLogon','AutoLogonCount','DefaultUserName','DefaultDomainName'){if($null -ne (Get-SessionRegistryValue $name)){throw 'An owned autologon registry value remained after cleanup.'}}
            $record.AutoLogonSecretsRemoved=$true
        }else{$record['BaselineAutoLogonPreserved']=$true}
        if(-not $SkipConsoleProof -and -not $PreserveAutoLogon){
            # Idempotent administrative cleanup must not destroy previous SYSTEM
            # proof while the same account and console session are still active.
            if(Test-Path -LiteralPath $cleanupPath){
                try{
                    $prior=Read-SessionJson $cleanupPath;$current=[ProfileAnalysisSessionNative]::Console($false)
                    if($prior.RunId -eq $Owner.RunId -and $prior.Success -and $prior.Console -and $prior.Console.StandardTokenVerified -and $prior.Console.UserSid -eq $Owner.UserSid -and $current.UserSid -eq $Owner.UserSid -and $prior.Console.SessionId -eq $current.SessionId){$record.Console=$prior.Console}
                }catch{Write-Verbose 'Previous console proof is unavailable; requesting fresh SYSTEM proof.'}
            }
            if(-not $record.Console){
                try{
                    $record.Console=Wait-SessionProof -Probe {
                        $console=[ProfileAnalysisSessionNative]::Console($true)
                        if($console.UserSid -ne $Owner.UserSid){throw 'The console belongs to another account.'}
                        return $console
                    }
                }catch{$record.ConsoleVerificationError=$_.Exception.Message;throw}
            }
        }
    }catch{$failure=$_.Exception.Message}
    finally{
        try{
            $service=New-Object -ComObject 'Schedule.Service';$service.Connect();$folder=$service.GetFolder('\')
            $task=Get-SessionTask $folder $Owner.TaskName
            if($task){if($task.Definition.RegistrationInfo.Description -cne ('PowerShellProfile.AnalysisWindowsSession/'+$Owner.RunId)){throw 'The cleanup task does not match session ownership.'};$folder.DeleteTask($Owner.TaskName,0)}
            if(Get-SessionTask $folder $Owner.TaskName){throw 'The owned cleanup task remained registered.'}
            $record.TaskRemoved=$true
        }catch{if($failure){$failure+='; '+$_.Exception.Message}else{$failure=$_.Exception.Message}}
        $record.Success=(-not $failure -and $record.AutoLogonSecretsRemoved -and $record.TaskRemoved -and $null -ne $record.Console)
        $record.CompletedUtc=[DateTime]::UtcNow.ToString('o');$record.Error=$failure
        Write-SessionJson $cleanupPath $record
    }
    if($failure){throw $failure}
    return [pscustomobject]$record
}

if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'This guest helper requires Windows.'}
if([IO.Path]::GetFullPath($PSCommandPath) -ine $trustedScript){throw 'The session helper must run only from its fixed trusted guest path.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
try{if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'The session helper requires a trusted guest administrator or SYSTEM.'}}finally{$identity.Dispose()}
Assert-SessionRegularPath $trustedScript
if(-not ('ProfileAnalysisSessionNative' -as [type])){Add-Type -TypeDefinition $sessionNative -Language CSharp}
$lockPath=Join-Path $privateDirectory 'session.lock';Assert-SessionRegularPath $lockPath -AllowMissing
$lock=$null
# Verify reads immutable ownership and a complete cleanup marker. It never owns
# the mutation lock, so readiness polling cannot prevent SYSTEM cleanup.
if($Mode -ne 'Verify'){$lock=Enter-SessionMutationLock -Path $lockPath -Operation $Mode}
try{
    if($Mode -eq 'Configure'){
        $configuration=$null;$owner=$null;$ownershipWritten=$false;$autoLogonWritten=$false;$baselineCredentials=@()
        try{
            try{$configuration=Read-SessionJson $configurationPath}finally{if(Test-Path -LiteralPath $configurationPath -PathType Leaf){Remove-Item -LiteralPath $configurationPath -Force}}
            if($configuration.UserName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$' -or $configuration.UserPassword -isnot [string] -or $configuration.UserPassword.Length -lt 1 -or $configuration.UserPassword.Length -gt 1024){throw 'The dedicated session configuration is invalid.'}
            if($configuration.PSObject.Properties['BaselineCredentials']){$baselineCredentials=@(Get-SessionBaselineCredential $configuration.BaselineCredentials)}
            if($ExpectedUser -and $configuration.UserName -ine $ExpectedUser){throw 'The configured user differs from the requested account.'}
            if(Test-Path -LiteralPath $ownershipPath){throw 'A session ownership record already exists; refusing replacement.'}
            if(Test-Path -LiteralPath $cleanupPath){throw 'A session cleanup marker already exists; refusing replacement.'}
            $baselineLogon=Get-SessionAutoLogonBaseline -BaselineCredentials $baselineCredentials
            $user=Get-LocalUser -Name $configuration.UserName
            Assert-SessionLocalAccount $user.Name $user.SID.Value
            [ProfileAnalysisSessionNative]::ValidateCredentials($user.Name,$configuration.UserPassword,$user.SID.Value)
            $runId=[Guid]::NewGuid().ToString('N');$taskName='ProfileAnalysisSessionCleanup-'+$runId
            $owner=[pscustomobject]@{Schema='PowerShellProfile.WindowsInteractiveSession.v1';RunId=$runId;UserName=$user.Name;UserSid=$user.SID.Value;TaskName=$taskName;ScriptSHA256=(Get-FileHash -LiteralPath $trustedScript -Algorithm SHA256).Hash;BaselineAutoLogon=$baselineLogon;PowerPolicyBefore=$null;PowerPolicy=$null;CreatedUtc=[DateTime]::UtcNow.ToString('o')}
            $service=New-Object -ComObject 'Schedule.Service';$service.Connect();$folder=$service.GetFolder('\')
            if(Get-SessionTask $folder $taskName){throw 'The proposed cleanup task name is already registered.'}
            Write-SessionJson $ownershipPath $owner -CreateNew
            $ownershipWritten=$true
            $powerPolicy=Set-SessionPowerPolicy;$owner.PowerPolicyBefore=$powerPolicy.Before;$owner.PowerPolicy=$powerPolicy.Verified
            Write-SessionJson $ownershipPath $owner
            $definition=$service.NewTask(0);$definition.RegistrationInfo.Description='PowerShellProfile.AnalysisWindowsSession/'+$runId
            $definition.Principal.UserId='S-1-5-18';$definition.Principal.LogonType=5;$definition.Principal.RunLevel=1
            $definition.Settings.Enabled=$true;$definition.Settings.StartWhenAvailable=$true;$definition.Settings.DisallowStartIfOnBatteries=$false;$definition.Settings.StopIfGoingOnBatteries=$false;$definition.Settings.ExecutionTimeLimit='PT5M';$definition.Settings.MultipleInstances=2
            $trigger=$definition.Triggers.Create(9);$trigger.UserId=$user.SID.Value;$trigger.Enabled=$true;$trigger.Delay='PT1S'
            $action=$definition.Actions.Create(0);$action.Path=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$action.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProfileAnalysis\Private\WindowsGuestSession.ps1" -Mode Cleanup';$action.WorkingDirectory=$privateDirectory
            $null=$folder.RegisterTaskDefinition($taskName,$definition,2,'SYSTEM',$null,5,'D:P(A;;GA;;;SY)(A;;GA;;;BA)')
            $currentBaseline=Get-SessionAutoLogonBaseline -BaselineCredentials $baselineCredentials
            if($currentBaseline.Classification -cne $baselineLogon.Classification -or $currentBaseline.UserName -cne $baselineLogon.UserName){throw 'The baseline autologon state changed before owned secret replacement.'}
            [ProfileAnalysisSessionNative]::StoreSecret($configuration.UserPassword)
            $autoLogonWritten=$true
            $configuration.UserPassword=$null
            $null=New-ItemProperty -LiteralPath $winlogonPath -Name 'DefaultUserName' -Value $user.Name -PropertyType String -Force
            $null=New-ItemProperty -LiteralPath $winlogonPath -Name 'DefaultDomainName' -Value $env:COMPUTERNAME -PropertyType String -Force
            $null=New-ItemProperty -LiteralPath $winlogonPath -Name 'AutoLogonCount' -Value 1 -PropertyType DWord -Force
            $null=New-ItemProperty -LiteralPath $winlogonPath -Name 'AutoAdminLogon' -Value '1' -PropertyType String -Force
            [pscustomobject]@{Status='Configured';RunId=$owner.RunId;UserName=$owner.UserName;UserSid=$owner.UserSid;TaskName=$owner.TaskName;RebootRequired=$true;CredentialsInTask=$false;PowerPolicy=$owner.PowerPolicy}|ConvertTo-Json -Depth 4 -Compress
        }catch{if($ownershipWritten){try{$null=Remove-OwnedSessionConfiguration $owner -SkipConsoleProof -PreserveAutoLogon:(-not $autoLogonWritten)}catch{Write-Warning 'Session configuration failed and its automatic cleanup could not finish; do not deploy a target.'}};throw}
        finally{
            if($configuration -and $configuration.PSObject.Properties['UserPassword']){$configuration.UserPassword=$null}
            foreach($credential in $baselineCredentials){$credential.UserPassword=$null}
            if($configuration -and $configuration.PSObject.Properties['BaselineCredentials']){$configuration.BaselineCredentials=$null}
        }
    }elseif($Mode -eq 'Cleanup'){
        $owner=Read-SessionOwnership
        Remove-OwnedSessionConfiguration $owner|ConvertTo-Json -Depth 6 -Compress
    }else{
        $owner=Read-SessionOwnership;Assert-SessionLocalAccount $owner.UserName $owner.UserSid
        if(-not $owner.PowerPolicy -or $owner.PowerPolicy.Status -ne 'Verified'){throw 'The owned session has no verified power-policy configuration.'}
        Assert-SessionPowerPolicy -Policy $owner.PowerPolicy
        $powerPolicy=Get-SessionVerifiedPowerPolicy -ExpectedSchemeId $owner.PowerPolicy.ActiveSchemeId
        $cleanup=Read-SessionJson $cleanupPath
        if($cleanup.Schema -ne 'PowerShellProfile.WindowsInteractiveSessionCleanup.v1' -or $cleanup.RunId -ne $owner.RunId -or -not $cleanup.Success -or -not $cleanup.AutoLogonSecretsRemoved -or -not $cleanup.TaskRemoved){throw 'Successful owned session cleanup is not established.'}
        if([ProfileAnalysisSessionNative]::SecretExists()){throw 'An autologon LSA secret is still present.'}
        foreach($name in 'DefaultPassword','AutoAdminLogon','AutoLogonCount','DefaultUserName','DefaultDomainName'){if($null -ne (Get-SessionRegistryValue $name)){throw 'An autologon registry value is still present.'}}
        if(Test-Path -LiteralPath $configurationPath){throw 'The private credential input file remains present.'}
        $service=New-Object -ComObject 'Schedule.Service';$service.Connect();if(Get-SessionTask ($service.GetFolder('\')) $owner.TaskName){throw 'The cleanup task is still registered.'}
        $console=[ProfileAnalysisSessionNative]::Console($false)
        if($console.UserSid -ne $owner.UserSid -or $console.UserName -ine $owner.UserName -or -not $cleanup.Console -or -not $cleanup.Console.StandardTokenVerified -or $cleanup.Console.UserSid -ne $console.UserSid -or $cleanup.Console.SessionId -ne $console.SessionId){throw 'The active console does not match the verified standard-user console token.'}
        [pscustomobject]@{Status='Ready';RunId=$owner.RunId;SessionId=$console.SessionId;UserName=$console.UserName;UserSid=$console.UserSid;StandardTokenVerified=$true;TokenVerifiedUtc=$cleanup.CompletedUtc;AutoLogonSecretsRemoved=$true;TaskRemoved=$true;BaselineAutoLogon=$owner.BaselineAutoLogon;PowerPolicy=$powerPolicy;VerifiedUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 4 -Compress
    }
}finally{if($lock){$lock.Dispose()}}
