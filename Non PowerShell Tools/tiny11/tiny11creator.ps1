<#
.SYNOPSIS
    Short description
.DESCRIPTION
    Long description
.EXAMPLE
    Example of how to use this cmdlet
.EXAMPLE
    Another example of how to use this cmdlet
#>
function Set-Tiny11Image {
    [CmdletBinding()]
    [OutputType([type])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path "$_/Sources/Install.wim" })]
        [string]
        $ISOMountedPath,
        [Parameter(Mandatory = $false)]
        [string]
        $Destination = 'C:\tiny11'
    )

    begin {
        New-Item -Path 'c:\tiny11' -ItemType Directory -Force
        Write-Output 'Copying Windows image...'

        # the below command is for copying the Windows 11 image to the c:\tiny11 folder, the arguments are explained below:
        # xcopy.exe /E /I /H /R /Y /J $DriveLetter":" c:\tiny11 >$null
        # /E - Copies directories and subdirectories, including empty ones.
        # /I - If destination does not exist and copying more than one file, assumes that destination must be a directory.
        # /H - Copies hidden and system files also.
        # /R - Overwrites read-only files.
        # /Y - Suppresses prompting to confirm you want to overwrite an existing destination file.
        # /J - Copies using unbuffered I/O. Recommended for very large files.
        # To do the same thing in powershell you would need to use pinvoke and we will use ntdll. Below is an example:

        # Add the ntdll typedefinition
        Add-Type -TypeDefinition @'
        using System;
        using System.Runtime.InteropServices;

        public static class Ntdll {
            [DllImport("ntdll.dll", SetLastError = true)]
            public static extern int NtOpenFile(
                out IntPtr FileHandle,
                FileAccess DesiredAccess,
                ref OBJECT_ATTRIBUTES ObjectAttributes,
                ref IO_STATUS_BLOCK IoStatusBlock,
                FileShare ShareAccess,
                CreateFileOptions OpenOptions
            );

            [DllImport("ntdll.dll", SetLastError = true)]
            public static extern int NtCreateFile(
                out IntPtr FileHandle,
                FileAccess DesiredAccess,
                ref OBJECT_ATTRIBUTES ObjectAttributes,
                ref IO_STATUS_BLOCK IoStatusBlock,
                ref long AllocationSize,
                FileAttributes FileAttributes,
                FileShare ShareAccess,
                CreateFileMode CreateDisposition,
                CreateFileOptions CreateOptions,
                IntPtr EaBuffer,
                IntPtr EaLength
            );

            [DllImport("ntdll.dll", SetLastError = true)]
            public static extern int NtReadFile(
                IntPtr FileHandle,
                IntPtr Event,
                IntPtr ApcRoutine,
                IntPtr ApcContext,
                ref IO_STATUS_BLOCK IoStatusBlock,
                byte[] Buffer,
                int Length,
                ref LARGE_INTEGER ByteOffset,
                IntPtr Key
            );

            [DllImport("ntdll.dll", SetLastError = true)]
            public static extern int NtClose(
                IntPtr Handle
            );
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IO_STATUS_BLOCK {
            public int Status;
            public IntPtr Information;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct OBJECT_ATTRIBUTES {
            public int Length;
            public IntPtr RootDirectory;
            public IntPtr ObjectName;
            public int Attributes;
            public IntPtr SecurityDescriptor;
            public IntPtr SecurityQualityOfService;
        }

        [Flags]
        public enum CreateFileAccess : uint {
            GENERIC_READ = 0x80000000,
            GENERIC_WRITE = 0x40000000,
            GENERIC_EXECUTE = 0x20000000,
            GENERIC_ALL = 0x10000000
        }

        [Flags]
        public enum CreateFileShare : uint {
            FILE_SHARE_READ = 0x00000001,
            FILE_SHARE_WRITE = 0x00000002,
            FILE_SHARE_DELETE = 0x00000004
        }

        [Flags]
        public enum CreateFileOptions : uint {
            FILE_ATTRIBUTE_READONLY = 0x00000001,
            FILE_ATTRIBUTE_HIDDEN = 0x00000002,
            FILE_ATTRIBUTE_SYSTEM = 0x00000004,
            FILE_ATTRIBUTE_DIRECTORY = 0x00000010,
            FILE_ATTRIBUTE_ARCHIVE = 0x00000020,
            FILE_ATTRIBUTE_DEVICE = 0x00000040,
            FILE_ATTRIBUTE_NORMAL = 0x00000080,
            FILE_ATTRIBUTE_TEMPORARY = 0x00000100,
            FILE_ATTRIBUTE_SPARSE_FILE = 0x00000200,
            FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400,
            FILE_ATTRIBUTE_COMPRESSED = 0x00000800,
            FILE_ATTRIBUTE_OFFLINE = 0x00001000,
            FILE_ATTRIBUTE_NOT_CONTENT_INDEXED = 0x00002000,
            FILE_ATTRIBUTE_ENCRYPTED = 0x00004000,
            FILE_ATTRIBUTE_INTEGRITY_STREAM = 0x00008000,
            FILE_ATTRIBUTE_VIRTUAL = 0x00010000,
            FILE_ATTRIBUTE_NO_SCRUB_DATA = 0x00020000,
            FILE_ATTRIBUTE_EA = 0x00040000,
            FILE_ATTRIBUTE_PINNED = 0x00080000,
            FILE_ATTRIBUTE_UNPINNED = 0x00100000,
            FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x00040000,
            FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x00400000,
            FILE_FLAG_OPEN_NO_RECALL = 0x00100000,
            FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000,
            FILE_FLAG_POSIX_SEMANTICS = 0x01000000,
            FILE_FLAG_BACKUP_SEMANTICS = 0x02000000,
            FILE_FLAG_DELETE_ON_CLOSE = 0x04000000,
            FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000,
            FILE_FLAG_RANDOM_ACCESS = 0x10000000,
            FILE_FLAG_NO_BUFFERING = 0x20000000,
            FILE_FLAG_OVERLAPPED = 0x40000000,
            FILE_FLAG_WRITE_THROUGH = 0x80000000
        }

        [Flags]
        public enum CreateFileMode : uint {
            CREATE_NEW = 1,
            CREATE_ALWAYS = 2,
            OPEN_EXISTING = 3,
            OPEN_ALWAYS = 4,
            TRUNCATE_EXISTING = 5
        }

        [Flags]
        public enum FileAttributes : uint {
            FILE_ATTRIBUTE_READONLY = 0x00000001,
            FILE_ATTRIBUTE_HIDDEN = 0x00000002,
            FILE_ATTRIBUTE_SYSTEM = 0x00000004,
            FILE_ATTRIBUTE_DIRECTORY = 0x00000010,
            FILE_ATTRIBUTE_ARCHIVE = 0x00000020,
            FILE_ATTRIBUTE_DEVICE = 0x00000040,
            FILE_ATTRIBUTE_NORMAL = 0x00000080,
            FILE_ATTRIBUTE_TEMPORARY = 0x00000100,
            FILE_ATTRIBUTE_SPARSE_FILE = 0x00000200,
            FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400,
            FILE_ATTRIBUTE_COMPRESSED = 0x00000800,
            FILE_ATTRIBUTE_OFFLINE = 0x00001000,
            FILE_ATTRIBUTE_NOT_CONTENT_INDEXED = 0x00002000,
            FILE_ATTRIBUTE_ENCRYPTED = 0x00004000,
            FILE_ATTRIBUTE_INTEGRITY_STREAM = 0x00008000,
            FILE_ATTRIBUTE_VIRTUAL = 0x00010000,
            FILE_ATTRIBUTE_NO_SCRUB_DATA = 0x00020000,
            FILE_ATTRIBUTE_EA = 0x00040000,
            FILE_ATTRIBUTE_PINNED = 0x00080000,
            FILE_ATTRIBUTE_UNPINNED = 0x00100000,
            FILE_ATTRIBUTE_RECALL_ON_OPEN = 0x00040000,
            FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS = 0x00400000,
            FILE_FLAG_OPEN_NO_RECALL = 0x00100000,
            FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000,
            FILE_FLAG_POSIX_SEMANTICS = 0x01000000,
            FILE_FLAG_BACKUP_SEMANTICS = 0x02000000,
            FILE_FLAG_DELETE_ON_CLOSE = 0x04000000,
            FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000,
            FILE_FLAG_RANDOM_ACCESS = 0x10000000,
            FILE_FLAG_NO_BUFFERING = 0x20000000,
            FILE_FLAG_OVERLAPPED = 0x40000000,
            FILE_FLAG_WRITE_THROUGH = 0x80000000
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct LARGE_INTEGER {
            public long QuadPart;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct UNICODE_STRING {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct OBJECT_NAME_INFORMATION {
            public UNICODE_STRING Name;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_BASIC_INFORMATION {
            public LARGE_INTEGER CreationTime;
            public LARGE_INTEGER LastAccessTime;
            public LARGE_INTEGER LastWriteTime;
            public LARGE_INTEGER ChangeTime;
            public uint FileAttributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_STANDARD_INFORMATION {
            public LARGE_INTEGER AllocationSize;
            public LARGE_INTEGER EndOfFile;
            public uint NumberOfLinks;
            public byte DeletePending;
            public byte Directory;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_INTERNAL_INFORMATION {
            public LARGE_INTEGER IndexNumber;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_EA_INFORMATION {
            public uint EaSize;
        }

        [StructLayout(LayoutKind.Explicit)]
        public struct FILE_ACCESS_INFORMATION {
            [FieldOffset(0)]
            public uint AccessFlags;
            [FieldOffset(0)]
            public FileAccess AccessFlagsNative;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_POSITION_INFORMATION {
            public LARGE_INTEGER CurrentByteOffset;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_MODE_INFORMATION {
            public uint Mode;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_ALIGNMENT_INFORMATION {
            public uint AlignmentRequirement;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_NAME_INFORMATION {
            public uint FileNameLength;
            public char FileName;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_ALL_INFORMATION {
            public FILE_BASIC_INFORMATION BasicInformation;
            public FILE_STANDARD_INFORMATION StandardInformation;
            public FILE_INTERNAL_INFORMATION InternalInformation;
            public FILE_EA_INFORMATION EaInformation;
            public FILE_ACCESS_INFORMATION AccessInformation;
            public FILE_POSITION_INFORMATION PositionInformation;
            public FILE_MODE_INFORMATION ModeInformation;
            public FILE_ALIGNMENT_INFORMATION AlignmentInformation;
            public FILE_NAME_INFORMATION NameInformation;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_NETWORK_OPEN_INFORMATION {
            public LARGE_INTEGER CreationTime;
            public LARGE_INTEGER LastAccessTime;
            public LARGE_INTEGER LastWriteTime;
            public LARGE_INTEGER ChangeTime;
            public LARGE_INTEGER AllocationSize;
            public LARGE_INTEGER EndOfFile;
            public uint FileAttributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_ATTRIBUTE_TAG_INFORMATION {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_DISPOSITION_INFORMATION {
            public byte DeleteFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_END_OF_FILE_INFORMATION {
            public LARGE_INTEGER EndOfFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_VALID_DATA_LENGTH_INFORMATION {
            public LARGE_INTEGER ValidDataLength;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_LINK_INFORMATION {
            public byte ReplaceIfExists;
            public IntPtr RootDirectory;
            public uint FileNameLength;
            public char FileName;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_MOVE_CLUSTER_INFORMATION {
            public ulong ClusterCount;
            public IntPtr RootDirectory;
            public uint FileNameLength;
            public char FileName;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_RENAME_INFORMATION {
            public byte ReplaceIfExists;
            public IntPtr RootDirectory;
            public uint FileNameLength;
            public char FileName;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_STREAM_INFORMATION {
            public uint NextEntryOffset;
            public uint StreamNameLength;
            public ulong StreamSize;
            public ulong StreamAllocationSize;
            public char StreamName;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_COMPRESSION_INFORMATION {
            public LARGE_INTEGER CompressedFileSize;
            public ushort CompressionFormat;
            public byte CompressionUnitShift;
            public byte ChunkShift;
            public byte ClusterShift;
            public byte Reserved;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_COPY_ON_WRITE_INFORMATION {
            public ulong NumberOfCopiedBytes;
            public byte ResourceId;
            public char IsResourceShadow;
            public ulong CopyOnWriteState;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_IO_PRIORITY_HINT_INFORMATION {
            public uint PriorityHint;
            public IntPtr Name;
            public ulong Volume;

        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_SPARSE_ATTRIBUTE_INFORMATION {
            public byte Sparse;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_LINK_ENTRY_INFORMATION {
            public ulong NextEntryOffset;
            public ulong ParentFileId;
            public ulong FileNameLength;
            public char FileName;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_LINKS_INFORMATION {
            public ulong BytesNeeded;
            public ulong EntriesReturned;
            public FILE_LINK_ENTRY_INFORMATION Entry;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_NETWORK_PHYSICAL_NAME_INFORMATION {
            public ulong FileNameLength;
            public char FileName;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_STANDARD_LINK_INFORMATION {
            public ulong NumberOfAccessibleLinks;
            public ulong TotalNumberOfLinks;
            public byte DeletePending;
            public byte Directory;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct FILE_ID_INFORMATION {
            public ulong Volume
'@

        # Create a new file
        $result = [Ntdll]::NtCreateFile([ref] $destinationHandle, [CreateFileAccess]::GENERIC_WRITE, [ref] $objectAttributes, [ref] $ioStatusBlock, [ref] $allocationSize, [FileAttributes]::FILE_ATTRIBUTE_NORMAL, [CreateFileShare]::FILE_SHARE_READ, [CreateFileMode]::CREATE_ALWAYS, [CreateFileOptions]::FILE_NON_DIRECTORY_FILE, [IntPtr]::Zero, 0)
        if ($result -ne 0) {
            throw "Failed to create destination file. Error code: $result"
        }

        # Read the source file and write it to the destination file
        $result = [Ntdll]::NtReadFile($sourceHandle, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [ref] $ioStatusBlock, $buffer, $buffer.Length, [ref] $byteOffset, [IntPtr]::Zero)
        while ($result -eq 0 -and $ioStatusBlock.Information -gt 0) {
            $result = [Ntdll]::NtWriteFile($destinationHandle, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [ref] $ioStatusBlock, $buffer, $ioStatusBlock.Information, [ref] $byteOffset, [IntPtr]::Zero)
            $result = [Ntdll]::NtReadFile($sourceHandle, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [ref] $ioStatusBlock, $buffer, $buffer.Length, [ref] $byteOffset, [IntPtr]::Zero)
        }

        # Close the handles
        [Ntdll]::NtClose($sourceHandle)
        [Ntdll]::NtClose($destinationHandle)

        # Unmount the image
        dism /unmount-image /mountdir:c:\scratchdir /discard >$null 2>&1

        # Make sure there are no images mounted
        dism /cleanup-wim >$null 2>&1

        #Delete any existing scratch directory
        Remove-Item -Recurse -Force 'c:\scratchdir' -ErrorAction SilentlyContinue

        # Remove existing destination directory
        Remove-Item -Recurse -Force $destination -ErrorAction SilentlyContinue

        # Get the source path
        $source = $(Resolve-Path -Path "$ISOMountedPath\Sources\Install.wim").Path


        $ioStatusBlock = New-Object IO_STATUS_BLOCK
        $byteOffset = New-Object LARGE_INTEGER
        $byteOffset.QuadPart = 0  # Starting at the beginning of the file
        $buffer = New-Object byte[] 4096  # Buffer size
        $objectAttributes = New-Object OBJECT_ATTRIBUTES
        $objectAttributes.Length = [Runtime.InteropServices.Marshal]::SizeOf($objectAttributes)
        $objectAttributes.Attributes = 0x00000040  # OBJ_CASE_INSENSITIVE
        $objectAttributes.ObjectName = [Runtime.InteropServices.Marshal]::AllocHGlobal([Runtime.InteropServices.Marshal]::SizeOf([IntPtr]::Zero))
        $objectAttributes.RootDirectory = [IntPtr]::Zero
        $allocationSize = 0
        $sourceHandle = [IntPtr]::Zero
        $destinationHandle = [IntPtr]::Zero

        # create a valid pointer to the source file name
        $sourceNamePointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([Runtime.InteropServices.Marshal]::SizeOf([char[]] $source))
        [Runtime.InteropServices.Marshal]::Copy($source.ToCharArray(), 0, $sourceNamePointer, $source.Length * 2)
        $objectAttributes.ObjectName = $sourceNamePointer

        # get a handle to the source file
        $result = [Ntdll]::NtOpenFile($objectAttributes.ObjectName, [CreateFileAccess]::GENERIC_READ, [ref] $objectAttributes, [ref] $ioStatusBlock, [CreateFileShare]::FILE_SHARE_READ, [CreateFileOptions]::FILE_ATTRIBUTE_NORMAL)
        if ($result -ne 0) {
            throw "Failed to open source file. Error code: $result"
        }


        # Read the source file and write to the destination file
        $destinationHandle = [IntPtr]::Zero
        $result = [Ntdll]::NtCreateFile([ref] $destinationHandle, [CreateFileAccess]::GENERIC_WRITE, [ref] $objectAttributes, [ref] $ioStatusBlock, [ref] $allocationSize, [CreateFileOptions]::FILE_ATTRIBUTE_NORMAL, [CreateFileShare]::FILE_SHARE_READ, [CreateFileMode]::CREATE_ALWAYS, [CreateFileOptions]::FILE_ATTRIBUTE_NORMAL, [IntPtr]::Zero, [IntPtr]::Zero)
        if ($result -ne 0) {
            throw "Failed to create destination file. Error code: $result"
        }

        $result = [Ntdll]::NtReadFile($sourceHandle, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [ref] $ioStatusBlock, $buffer, 4096, [ref] $byteOffset, [IntPtr]::Zero)
        while ($result -eq 0 -and $ioStatusBlock.Information -gt 0) {
            [void][System.Runtime.InteropServices.Marshal]::Copy($buffer, 0, $destinationHandle, $ioStatusBlock.Information)
            $result = [Ntdll]::NtReadFile($sourceHandle, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [ref] $ioStatusBlock, $buffer, 4096, [ref] $byteOffset, [IntPtr]::Zero)
        }

        # Close the handles
        [CreateFile]::CloseHandle($sourceHandle)
        [CreateFile]::CloseHandle($destinationHandle)

        # Unmount the image
        dism /unmount-image /mountdir:c:\scratchdir /discard >$null 2>&1

        # Delete the scratch directory
        Remove-Item -Recurse -Force 'c:\scratchdir' -ErrorAction SilentlyContinue
    }
    process {
        Write-Output 'Getting image information:'
        dism /Get-WimInfo /wimfile:c:\tiny11\sources\install.wim
        $index = Read-Host -Prompt 'Please enter the image index'
        Write-Output 'Mounting Windows image. This may take a while.'
        mkdir 'c:\scratchdir' >$null 2>&1
        dism /mount-image /imagefile:c:\tiny11\sources\install.wim /index:$index /mountdir:c:\scratchdir
        Write-Output 'Mounting complete! Performing removal of applications...'
        $appxfind = 'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.GamingApp', `
            'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub', `
            'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop', `
            'Microsoft.Todos', 'Microsoft.WindowsAlarms', 'microsoft.windowscommunicationsapps', `
            'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.WindowsSoundRecorder', `
            'Microsoft.Xbox.TCUI', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay', `
            'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.YourPhone', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', `
            'MicrosoftCorporationII.MicrosoftFamily', 'MicrosoftCorporationII.QuickAssist', 'MicrosoftTeams', `
            'Microsoft.549981C3F5F10'
        $appxlist = dism /image:c:\scratchdir /Get-ProvisionedAppxPackages | Select-String -Pattern 'PackageName : ' -CaseSensitive -SimpleMatch
        $appxlist = $appxlist -split 'PackageName : ' | Where-Object { $_ }

        foreach ( $appxlookup in $appxfind ) {
            Write-Output "Finding $appxlookup ..."
            $appxremove = $appxlist | Select-String -Pattern $appxlookup -CaseSensitive -SimpleMatch
            foreach ( $appx in $appxremove ) {
                Write-Output "Removing $appx"
                dism /image:c:\scratchdir /Remove-ProvisionedAppxPackage /PackageName:$appx >$null
            }
            if ( -not ( $appxremove ) ) {
                Write-Output "$appxlookup was not found!"
            }
        }

        Write-Output 'Removing of system apps complete! Now proceeding to removal of system packages...'
        Start-Sleep -Seconds 1

        $packagefind = 'Microsoft-Windows-InternetExplorer-Optional-Package', 'Microsoft-Windows-Kernel-LA57-FoD-Package', `
            'Microsoft-Windows-LanguageFeatures-Handwriting', 'Microsoft-Windows-LanguageFeatures-OCR', `
            'Microsoft-Windows-LanguageFeatures-Speech', 'Microsoft-Windows-LanguageFeatures-TextToSpeech', `
            'Microsoft-Windows-MediaPlayer-Package', 'Microsoft-Windows-TabletPCMath-Package', `
            'Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package'
        $packagelist = dism /image:c:\scratchdir /Get-Packages /Format:List | Select-String -Pattern 'Package Identity : ' -CaseSensitive -SimpleMatch
        $packagelist = $packagelist -split 'Package Identity : ' | Where-Object { $_ }

        foreach ( $packagelookup in $packagefind ) {
            Write-Output "Finding $packagelookup ..."
            $packageremove = $packagelist | Select-String -Pattern $packagelookup -CaseSensitive -SimpleMatch
            foreach ( $package in $packageremove ) {
                Write-Output "Removing $package"
                dism /image:c:\scratchdir /Remove-Package /PackageName:$package >$null
            }
            if ( -not ( $packageremove ) ) {
                Write-Output "$packagelookup was not found!"
            }
        }

        Write-Output 'Removing Edge:'
        Remove-Item -Recurse -Force 'C:\scratchdir\Program Files (x86)\Microsoft\Edge'
        Remove-Item -Recurse -Force 'C:\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate'
        Write-Output 'Removing OneDrive:'
        takeown /f C:\scratchdir\Windows\System32\OneDriveSetup.exe
        icacls C:\scratchdir\Windows\System32\OneDriveSetup.exe /grant Administrators:F /T /C
        Remove-Item -Force 'C:\scratchdir\Windows\System32\OneDriveSetup.exe'
        Write-Output 'Removal complete!'
        Start-Sleep -Seconds 2

        Write-Output 'Loading registry...'
        reg load HKLM\zCOMPONENTS 'c:\scratchdir\Windows\System32\config\COMPONENTS' >$null
        reg load HKLM\zDEFAULT 'c:\scratchdir\Windows\System32\config\default' >$null
        reg load HKLM\zNTUSER 'c:\scratchdir\Users\Default\ntuser.dat' >$null
        reg load HKLM\zSOFTWARE 'c:\scratchdir\Windows\System32\config\SOFTWARE' >$null
        reg load HKLM\zSYSTEM 'c:\scratchdir\Windows\System32\config\SYSTEM' >$null
        Write-Output 'Bypassing system requirements(on the system image):'
        Reg add 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV1' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV2' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV1' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV2' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassCPUCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassRAMCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassSecureBootCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassStorageCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassTPMCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\MoSetup' /v 'AllowUpgradesWithUnsupportedTPMOrCPU' /t REG_DWORD /d '1' /f >$null 2>&1
        Write-Output 'Disabling Teams:'
        Reg add 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Communications' /v 'ConfigureChatAutoInstall' /t REG_DWORD /d '0' /f >$null 2>&1
        Write-Output 'Disabling Sponsored Apps:'
        Reg add 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'OemPreInstalledAppsEnabled' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'PreInstalledAppsEnabled' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' /v 'SilentInstalledAppsEnabled' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' /v 'DisableWindowsConsumerFeatures' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' /v 'ConfigureStartPins' /t REG_SZ /d '{\'pinnedList\": [{}]}" /f >$null 2>&1
        Write-Output 'Enabling Local Accounts on OOBE:'
        Reg add 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' /v 'BypassNRO' /t REG_DWORD /d '1' /f >$null 2>&1
        Copy-Item $pwd\autounattend.xml c:\scratchdir\Windows\System32\Sysprep\autounattend.xml
        Write-Output 'Disabling Reserved Storage:'
        Reg add 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' /v 'ShippedWithReserves' /t REG_DWORD /d '0' /f >$null 2>&1
        Write-Output 'Disabling Chat icon:'
        Reg add 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' /v 'ChatIcon' /t REG_DWORD /d '3' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' /v 'TaskbarMn' /t REG_DWORD /d '0' /f >$null 2>&1
        Write-Output 'Tweaking complete!'
        Write-Output 'Unmounting Registry...'
        reg unload HKLM\zCOMPONENTS >$null 2>&1
        reg unload HKLM\zDRIVERS >$null 2>&1
        reg unload HKLM\zDEFAULT >$null 2>&1
        reg unload HKLM\zNTUSER >$null 2>&1
        reg unload HKLM\zSCHEMA >$null 2>&1
        reg unload HKLM\zSOFTWARE >$null 2>&1
        reg unload HKLM\zSYSTEM >$null 2>&1
        Write-Output 'Cleaning up image...'
        dism /image:c:\scratchdir /Cleanup-Image /StartComponentCleanup /ResetBase
        Write-Output 'Cleanup complete.'
        Write-Output 'Unmounting image...'
        dism /unmount-image /mountdir:c:\scratchdir /commit
        Write-Output 'Exporting image...'
        Dism /Export-Image /SourceImageFile:c:\tiny11\sources\install.wim /SourceIndex:$index /DestinationImageFile:c:\tiny11\sources\install2.wim /compress:max
        Remove-Item c:\tiny11\sources\install.wim
        Rename-Item c:\tiny11\sources\install2.wim install.wim
        Write-Output 'Windows image completed. Continuing with boot.wim.'
        Start-Sleep -Seconds 2

        Write-Output 'Mounting boot image:'
        dism /mount-image /imagefile:c:\tiny11\sources\boot.wim /index:2 /mountdir:c:\scratchdir
        Write-Output 'Loading registry...'
        reg load HKLM\zCOMPONENTS 'c:\scratchdir\Windows\System32\config\COMPONENTS' >$null
        reg load HKLM\zDEFAULT 'c:\scratchdir\Windows\System32\config\default' >$null
        reg load HKLM\zNTUSER 'c:\scratchdir\Users\Default\ntuser.dat' >$null
        reg load HKLM\zSOFTWARE 'c:\scratchdir\Windows\System32\config\SOFTWARE' >$null
        reg load HKLM\zSYSTEM 'c:\scratchdir\Windows\System32\config\SYSTEM' >$null
        Write-Output 'Bypassing system requirements(on the setup image):'
        Reg add 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV1' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV2' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV1' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' /v 'SV2' /t REG_DWORD /d '0' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassCPUCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassRAMCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassSecureBootCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassStorageCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\LabConfig' /v 'BypassTPMCheck' /t REG_DWORD /d '1' /f >$null 2>&1
        Reg add 'HKLM\zSYSTEM\Setup\MoSetup' /v 'AllowUpgradesWithUnsupportedTPMOrCPU' /t REG_DWORD /d '1' /f >$null 2>&1
        Write-Output 'Tweaking complete!'
        Write-Output 'Unmounting Registry...'
        reg unload HKLM\zCOMPONENTS >$null 2>&1
        reg unload HKLM\zDRIVERS >$null 2>&1
        reg unload HKLM\zDEFAULT >$null 2>&1
        reg unload HKLM\zNTUSER >$null 2>&1
        reg unload HKLM\zSCHEMA >$null 2>&1
        reg unload HKLM\zSOFTWARE >$null 2>&1
        reg unload HKLM\zSYSTEM >$null 2>&1
        Write-Output 'Unmounting image...'
        dism /unmount-image /mountdir:c:\scratchdir /commit

        Write-Output 'the tiny11 image is now completed. Proceeding with the making of the ISO...'
        Write-Output 'Copying unattended file for bypassing MS account on OOBE...'
        Copy-Item $pwd\autounattend.xml c:\tiny11\autounattend.xml
        Write-Output ''
        Write-Output 'Creating ISO image...'
        & $pwd\oscdimg.exe -m -o -u2 -udfver102 -bootdata:2#p0, e, bc:\tiny11\boot\etfsboot.com#pEF, e, bc:\tiny11\efi\microsoft\boot\efisys.bin c:\tiny11 $pwd\tiny11.iso
        Write-Output 'Creation completed! Press any key to exit the script...'

    }

    end {

        Write-Output 'Performing Cleanup...'
        Remove-Item -Recurse -Force 'c:\scratchdir'
        Remove-Item -Recurse -Force 'c:\tiny11'
    }
}