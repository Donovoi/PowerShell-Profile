function Invoke-emulatechkdsk() {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True, Position = 0)]
        [string]$driveletter
    )
    $drive = Invoke-CimMethod -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_Volume -MethodName SetOffline -Arguments @{DriveLetter = $driveletter } -ErrorAction Stop
    $drive | Format-List
}
# Add-Type to compile C# code
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class DiskUtils
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateFile(
        string lpFileName,
        uint dwDesiredAccess,
        uint dwShareMode,
        IntPtr lpSecurityAttributes,
        uint dwCreationDisposition,
        uint dwFlagsAndAttributes,
        IntPtr hTemplateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetVolumeInformation(
        string lpRootPathName,
        System.Text.StringBuilder lpVolumeNameBuffer,
        uint nVolumeNameSize,
        out uint lpVolumeSerialNumber,
        out uint lpMaximumComponentLength,
        out uint lpFileSystemFlags,
        System.Text.StringBuilder lpFileSystemNameBuffer,
        uint nFileSystemNameSize);

    public const uint GENERIC_READ = 0x80000000;
    public const uint FILE_SHARE_READ = 0x1;
    public const uint OPEN_EXISTING = 3;
}

'@ -Language CSharp

try {
    $driveLetter = 'J:' # Change this to the letter of the drive you want to check

    # Open the volume
    $handle = [DiskUtils]::CreateFile(
        "\\.\$driveLetter",
        [DiskUtils]::GENERIC_READ,
        [DiskUtils]::FILE_SHARE_READ,
        [IntPtr]::Zero,
        [DiskUtils]::OPEN_EXISTING,
        0,
        [IntPtr]::Zero)

    if ($handle -eq [IntPtr]::MinusOne) {
        throw 'Failed to access drive. Error code: ' + [Marshal]::GetLastWin32Error()
    }

    # Get volume information
    $sbVolumeName = New-Object System.Text.StringBuilder 256
    $sbFileSystemName = New-Object System.Text.StringBuilder 256
    $result = [DiskUtils]::GetVolumeInformation(
        $driveLetter + '\',
        $sbVolumeName,
        256,
        [ref] $serialNumber,
        [ref] $maxComponentLength,
        [ref] $fileSystemFlags,
        $sbFileSystemName,
        256)

    if ($result -eq $false) {
        throw 'Failed to get volume information. Error code: ' + [Marshal]::GetLastWin32Error()
    }

    # Output the information
    'Volume Name: ' + $sbVolumeName.ToString()
    'File System: ' + $sbFileSystemName.ToString()
    'File System Flags: ' + $fileSystemFlags
}
catch {
    Write-Error $_.Exception.Message
}
finally {
    # Close handle if it's open
    if ($handle -ne [IntPtr]::Zero -and $handle -ne [IntPtr]::MinusOne) {
        [DiskUtils]::CloseHandle($handle)
    }
}
}