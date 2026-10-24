# Trusted function-only asset. Load/release functions are for the owned guest only.
# Dot-sourcing this file and compiling its C# do not call any profile or token API.
#requires -Version 5.1
function Initialize-AnalysisWindowsDeploymentProfileType {
    [CmdletBinding()]
    param()
    if('ProfileAnalysisDeploymentProfile.Lease' -as [type]){return}
    $native=@'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.ExceptionServices;
using System.Security.Principal;
using Microsoft.Win32;
namespace ProfileAnalysisDeploymentProfile {
 public interface IProfileApi : IDisposable {
  string UserSid {get;} string AccountName {get;} bool IsAdministrator {get;} bool IsLocalAccount {get;} bool IsImpersonating {get;}
  bool HiveExists(); int ProfileType(out uint flags); string ProfileDirectory();
  object EnablePrivilege(string name); void RestorePrivilege(object previous);
  IntPtr Load(string userName); void Unload(IntPtr profile);
 }
 [Serializable] public sealed class Proof {
  public string Status="Preparing",UserSid,AccountName,ProfileDirectory,StartedUtc=DateTime.UtcNow.ToString("o"),VerifiedUtc,ReleasedUtc,CleanupError;
  public uint ProfileType; public bool WasHiveLoaded,LoadedByThisRun,PrivilegesRestored=true,Released;
  public int PendingPrivilegeRestorations,PrivilegeRestorationFailures; public string[] PendingPrivilegeNames=new string[0];
 }
 public sealed class Lease : IDisposable {
  private IProfileApi api; private IntPtr profile=IntPtr.Zero; private bool released;
  private sealed class PendingPrivilege {public string Name;public object Original;}
  private readonly List<PendingPrivilege> pendingPrivileges=new List<PendingPrivilege>();
  public Proof Proof {get;private set;}
  private Lease(IProfileApi value){api=value;Proof=new Proof();}
  public static Lease AcquireCurrent(string expectedSid){return Acquire(expectedSid,new NativeApi());}
  public static Lease Acquire(string expectedSid,IProfileApi api){
   if(api==null)throw new ArgumentNullException("api");
   Lease lease=new Lease(api);
   try{
    new SecurityIdentifier(expectedSid);
    if(api.UserSid!=expectedSid || !api.IsAdministrator || !api.IsLocalAccount || api.IsImpersonating)throw new InvalidOperationException("Deployment profile requires the expected local administrator process token without impersonation.");
    string[] account=api.AccountName.Split('\\');
    if(account.Length!=2 || String.IsNullOrWhiteSpace(account[1]))throw new InvalidOperationException("Deployment account name is invalid.");
    lease.Proof.UserSid=api.UserSid;lease.Proof.AccountName=api.AccountName;lease.Proof.WasHiveLoaded=api.HiveExists();
    uint flags;int error=api.ProfileType(out flags);
    if(error==0 && flags!=0)throw new InvalidOperationException("Deployment requires a normal local profile, not a temporary, roaming, or mandatory profile.");
    if(error!=0 || !lease.Proof.WasHiveLoaded){
     lease.WithPrivileges(delegate{lease.profile=api.Load(account[1]);if(lease.profile==IntPtr.Zero)throw new InvalidOperationException("LoadUserProfile returned no owned profile handle.");lease.Proof.LoadedByThisRun=true;});
    }
    error=api.ProfileType(out flags);
    if(error!=0)throw new Win32Exception(error,"GetProfileType after deployment profile preparation");
    if(flags!=0 || !api.HiveExists())throw new InvalidOperationException("The expected normal local profile and HKU hive were not verified after loading.");
    lease.Proof.ProfileDirectory=api.ProfileDirectory();lease.Proof.ProfileType=flags;
    lease.Proof.Status="Ready";lease.Proof.VerifiedUtc=DateTime.UtcNow.ToString("o");return lease;
   }catch(Exception primary){
    try{lease.Release();}catch(Exception cleanup){primary.Data["DeploymentProfileCleanupError"]=cleanup.Message;}
    primary.Data["DeploymentProfileProof"]=lease.Proof;
    ExceptionDispatchInfo.Capture(primary).Throw();throw;
   }
  }
  private void EnablePrivilege(string name){
   object previous=api.EnablePrivilege(name);
   // If a restoration failed, keep the first original state. A later cleanup
   // scope can observe an enabled privilege that was originally disabled.
   if(!pendingPrivileges.Exists(delegate(PendingPrivilege entry){return entry.Name==name;}))pendingPrivileges.Add(new PendingPrivilege{Name=name,Original=previous});
   UpdatePrivilegeProof();
  }
  private void UpdatePrivilegeProof(){
   Proof.PendingPrivilegeRestorations=pendingPrivileges.Count;
   Proof.PendingPrivilegeNames=pendingPrivileges.ConvertAll(delegate(PendingPrivilege entry){return entry.Name;}).ToArray();
   Proof.PrivilegesRestored=pendingPrivileges.Count==0;
  }
  private List<Exception> RestorePendingPrivileges(){
   List<Exception> errors=new List<Exception>();
   for(int i=pendingPrivileges.Count-1;i>=0;i--){
    try{api.RestorePrivilege(pendingPrivileges[i].Original);pendingPrivileges.RemoveAt(i);}
    catch(Exception error){errors.Add(error);Proof.PrivilegeRestorationFailures++;}
   }
   UpdatePrivilegeProof();return errors;
  }
  private static string RestorationMessages(List<Exception> errors){return String.Join("; ",errors.ConvertAll(delegate(Exception error){return error.Message;}).ToArray());}
  private static void ThrowRestorationFailure(List<Exception> errors){
   if(errors.Count==0)return;
   Exception first=errors[0];first.Data["PrivilegeRestorationErrors"]=RestorationMessages(errors);ExceptionDispatchInfo.Capture(first).Throw();
  }
  private void WithPrivileges(Action action){
   List<Exception> restoreErrors;Exception failure=null;
   try{EnablePrivilege("SeBackupPrivilege");EnablePrivilege("SeRestorePrivilege");action();}
   catch(Exception error){failure=error;}
   finally{restoreErrors=RestorePendingPrivileges();}
   if(failure!=null){if(restoreErrors.Count!=0)failure.Data["PrivilegeRestorationErrors"]=RestorationMessages(restoreErrors);ExceptionDispatchInfo.Capture(failure).Throw();}
   ThrowRestorationFailure(restoreErrors);
  }
  public void Release(){
   if(released)return;
   try{
    if(profile!=IntPtr.Zero){WithPrivileges(delegate{api.Unload(profile);profile=IntPtr.Zero;});}
    else if(pendingPrivileges.Count!=0){ThrowRestorationFailure(RestorePendingPrivileges());}
    Proof.Released=true;Proof.Status="Released";
   }catch(Exception error){Proof.CleanupError=error.Message;Proof.Status="CleanupFailed";throw;}
   finally{released=true;Proof.ReleasedUtc=DateTime.UtcNow.ToString("o");api.Dispose();}
  }
  public void Dispose(){Release();}
  public static string ValidateProfileDirectory(string nativePath,string registeredPath){
   if(String.IsNullOrWhiteSpace(nativePath) || nativePath.Length>32767 || nativePath.Length<3 || nativePath[1]!=':' || nativePath[2]!='\\' || !Char.IsLetter(nativePath[0]))throw new InvalidOperationException("The deployment profile is not a local absolute drive path.");
   string full=Path.GetFullPath(nativePath).TrimEnd('\\');
   if(full.Length<4)throw new InvalidOperationException("The deployment profile cannot be a drive root.");
   if(String.IsNullOrWhiteSpace(registeredPath) || !String.Equals(full,Path.GetFullPath(Environment.ExpandEnvironmentVariables(registeredPath)).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("Native profile directory differs from the expected SID's ProfileList mapping.");
   if(!Directory.Exists(full) || !File.Exists(Path.Combine(full,"NTUSER.DAT")))throw new InvalidOperationException("The local deployment profile directory or user hive file is missing.");
   string cursor=full;
   while(!String.IsNullOrEmpty(cursor)){if((File.GetAttributes(cursor)&FileAttributes.ReparsePoint)!=0)throw new InvalidOperationException("The deployment profile path traverses a reparse point.");cursor=Path.GetDirectoryName(cursor);}
   if((File.GetAttributes(Path.Combine(full,"NTUSER.DAT"))&FileAttributes.ReparsePoint)!=0)throw new InvalidOperationException("The deployment profile hive file is a reparse point.");
   return full;
  }
 }
 internal sealed class NativeApi : IProfileApi {
  [StructLayout(LayoutKind.Sequential)] struct Luid {public uint Low;public int High;}
  [StructLayout(LayoutKind.Sequential)] struct Privileges {public uint Count;public Luid Luid;public uint Attributes;}
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct ProfileInfo {public uint Size,Flags;public string UserName,ProfilePath,DefaultPath,ServerName,PolicyPath;public IntPtr Profile;}
  [StructLayout(LayoutKind.Sequential)] struct UserInfo3 {
   public IntPtr Name,Password;public uint PasswordAge,Privilege;public IntPtr HomeDirectory,Comment;public uint Flags;public IntPtr ScriptPath;public uint AuthFlags;
   public IntPtr FullName,UserComment,Parameters,Workstations;public uint LastLogon,LastLogoff,AccountExpires,MaxStorage,UnitsPerWeek;public IntPtr LogonHours;
   public uint BadPasswordCount,LogonCount;public IntPtr LogonServer;public uint CountryCode,CodePage,UserId,PrimaryGroupId;public IntPtr Profile,HomeDrive;public uint PasswordExpired;
  }
  [DllImport("kernel32.dll",ExactSpelling=true)] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll",ExactSpelling=true,SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("advapi32.dll",ExactSpelling=true,SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
  [DllImport("advapi32.dll",EntryPoint="LookupPrivilegeValueW",ExactSpelling=true,CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out Luid luid);
  [DllImport("advapi32.dll",ExactSpelling=true,SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disableAll,ref Privileges state,uint size,out Privileges previous,out uint needed);
  [DllImport("advapi32.dll",EntryPoint="AdjustTokenPrivileges",ExactSpelling=true,SetLastError=true)] static extern bool RestoreTokenPrivileges(IntPtr token,bool disableAll,ref Privileges state,uint size,IntPtr previous,IntPtr needed);
  [DllImport("userenv.dll",ExactSpelling=true,CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LoadUserProfileW(IntPtr token,ref ProfileInfo info);
  [DllImport("userenv.dll",ExactSpelling=true,SetLastError=true)] static extern bool UnloadUserProfile(IntPtr token,IntPtr profile);
  [DllImport("userenv.dll",ExactSpelling=true,SetLastError=true)] static extern bool GetProfileType(out uint flags);
  [DllImport("userenv.dll",ExactSpelling=true,CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserProfileDirectoryW(IntPtr token,StringBuilder directory,ref uint length);
  [DllImport("netapi32.dll",ExactSpelling=true,CharSet=CharSet.Unicode)] static extern uint NetUserGetInfo(string server,string user,uint level,out IntPtr info);
  [DllImport("netapi32.dll",ExactSpelling=true)] static extern uint NetApiBufferFree(IntPtr buffer);
  private IntPtr token;
  public string UserSid {get;private set;} public string AccountName {get;private set;} public bool IsAdministrator {get;private set;} public bool IsLocalAccount {get;private set;} public bool IsImpersonating {get;private set;}
  private static void Check(bool success,string operation){if(!success)throw new Win32Exception(Marshal.GetLastWin32Error(),operation);}
  public NativeApi(){
   try{
    Check(OpenProcessToken(GetCurrentProcess(),0x2E,out token),"Open current deployment process token"); // QUERY | IMPERSONATE | DUPLICATE | ADJUST_PRIVILEGES
    using(WindowsIdentity thread=WindowsIdentity.GetCurrent(true)){IsImpersonating=thread!=null;}
    using(WindowsIdentity identity=new WindowsIdentity(token)){UserSid=identity.User.Value;AccountName=identity.Name;IsAdministrator=new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);}
    string[] account=AccountName.Split('\\');IsLocalAccount=account.Length==2 && String.Equals(account[0],Environment.MachineName,StringComparison.OrdinalIgnoreCase);
    if(IsLocalAccount){
     IntPtr info=IntPtr.Zero;uint code=NetUserGetInfo(null,account[1],3,out info);
     try{if(code!=0)throw new Win32Exception((int)code,"Read local deployment account profile configuration");UserInfo3 value=(UserInfo3)Marshal.PtrToStructure(info,typeof(UserInfo3));if(value.Profile!=IntPtr.Zero && !String.IsNullOrEmpty(Marshal.PtrToStringUni(value.Profile)))throw new InvalidOperationException("The deployment account has an explicitly configured roaming profile; this helper supports the default local profile only.");}
     finally{if(info!=IntPtr.Zero)NetApiBufferFree(info);}
    }
   }catch{Dispose();throw;}
  }
  public bool HiveExists(){using(RegistryKey hive=Registry.Users.OpenSubKey(UserSid,false)){return hive!=null;}}
  public int ProfileType(out uint flags){return GetProfileType(out flags)?0:Marshal.GetLastWin32Error();}
  public string ProfileDirectory(){
   uint length=0;bool first=GetUserProfileDirectoryW(token,null,ref length);int error=Marshal.GetLastWin32Error();
   if(first || error!=122 || length<4 || length>32768)throw new Win32Exception(error,"GetUserProfileDirectory size");
   StringBuilder directory=new StringBuilder((int)length);Check(GetUserProfileDirectoryW(token,directory,ref length),"GetUserProfileDirectory");
   using(RegistryKey key=Registry.LocalMachine.OpenSubKey("SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\"+UserSid,false)){
    if(key==null)throw new InvalidOperationException("The current deployment SID has no ProfileList entry.");
    return Lease.ValidateProfileDirectory(directory.ToString(),key.GetValue("ProfileImagePath",null,RegistryValueOptions.DoNotExpandEnvironmentNames) as string);
   }
  }
  public object EnablePrivilege(string name){
   Luid luid;Check(LookupPrivilegeValue(null,name,out luid),"Lookup "+name);Privileges desired=new Privileges{Count=1,Luid=luid,Attributes=2},previous;uint needed;
   bool success=AdjustTokenPrivileges(token,false,ref desired,(uint)Marshal.SizeOf(typeof(Privileges)),out previous,out needed);int error=Marshal.GetLastWin32Error();
   if(!success || error!=0){if(previous.Count!=0)RestorePrivilege(previous);throw new Win32Exception(error,"Enable existing "+name);}
   return previous;
  }
  public void RestorePrivilege(object state){Privileges previous=(Privileges)state;if(previous.Count==0)return;bool success=RestoreTokenPrivileges(token,false,ref previous,0,IntPtr.Zero,IntPtr.Zero);int error=Marshal.GetLastWin32Error();if(!success || error!=0)throw new Win32Exception(error,"Restore original deployment privilege state");}
  public IntPtr Load(string userName){ProfileInfo info=new ProfileInfo{Size=(uint)Marshal.SizeOf(typeof(ProfileInfo)),Flags=1,UserName=userName};Check(LoadUserProfileW(token,ref info),"Load current deployment administrator profile");return info.Profile;}
  public void Unload(IntPtr profile){Check(UnloadUserProfile(token,profile),"Unload owned deployment profile handle");}
  public void Dispose(){if(token!=IntPtr.Zero){CloseHandle(token);token=IntPtr.Zero;}}
 }
}
'@
    Add-Type -TypeDefinition $native -Language CSharp
}

function Enter-AnalysisWindowsDeploymentProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^S-1-5-21-(?:\d+-){3}\d+$')][string]$ExpectedUserSid)
    Initialize-AnalysisWindowsDeploymentProfileType
    [ProfileAnalysisDeploymentProfile.Lease]::AcquireCurrent($ExpectedUserSid)
}

function Exit-AnalysisWindowsDeploymentProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Lease)
    if($Lease.GetType().FullName -ne 'ProfileAnalysisDeploymentProfile.Lease'){throw 'A deployment profile lease returned by Enter is required.'}
    $Lease.Release()
    $Lease.Proof
}
