<#
    .SYNOPSIS

        Downloads symbols from the Microsoft store.

    .DESCRIPTION

        This function downloads symbols from the Microsoft store.
        It is based on the PDB-Downloader application.
        It was optimized to run in a console with huge file lists.
        It was also optimized for fast recovery, in case of premature termination.

    .PARAMETER Path

        The path(s) to the image we want to donwload the symbol.

    .PARAMETER DestinationStore

        The path where we want to store the symbols.
        Default value is 'C:\Symbols'.

    .PARAMETER ReadTimeout

        Timeout in seconds the for the binary read operation.
        If no debug information is found within the timeout, the file is marked as 'No Debug Info'.
        Input '0' is infinite.
        Default is 60 seconds.

    .PARAMETER DownloadTimeout

        Timeout in seconds for the download.
        The timeout stopwatch only starts if the download is stuck in the same progress percentage.
        If a download times out, it's added to a retry list.
        Input '0' is infinite.
        Default is 15 seconds.

    .PARAMETER Retry

        The number of retries for timed out downloads.
        Default is 3 times.

    .EXAMPLE

        PS C:\>_ [string[]]$fileList = (Get-ChildItem -Path 'C:\Windows\System32' -Recurse -Force -File | Where-Object {
            ($PSItem.Name -like '*.exe') -or ($PSItem.Name -like '*.dll')
        }).FullName

        PS C:\>_ Get-PdbSymbol -Path $fileList -DestinationStore 'C:\Symbols' -ReadTimeout 30 -DownloadTimeout 10 -Retry 0

    .NOTES

        This script is provided under the MIT license.
        Version: 1.3.1
        Release date: 13-JUN-2023
        Author: Francisco Nabas

    .LINK

        https://github.com/rajkumar-rangaraj/PDB-Downloader
        https://learn.microsoft.com/en-us/archive/blogs/webtopics/pdb-downloader
        https://github.com/FranciscoNabas
#>

function Get-PdbSymbol {

    [CmdletBinding()]
    param (
        [Parameter(
            Mandatory,
            Position = 0,
            HelpMessage = 'The file path(s).')]
        [ValidateScript({
                if (!$PSItem -or $PSItem.Count -lt 1) { throw [System.ArgumentException]::new('"Path" needs to have at least one file path.') }
                return $true
            })]
        [string[]]$Path,

        [Parameter(
            Position = 1,
            HelpMessage = 'The path to store the downloaded symbols')]
        [ValidateNotNullOrEmpty()]
        [string]$DestinationStore = 'C:\Symbols',

        [Parameter(HelpMessage = 'The timeout, in seconds, for the bynary read operation.')]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$ReadTimeout = 60,

        [Parameter(
            HelpMessage = 'The timeoout, in seconds, for the download operation.')]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$DownloadTimeout = 15,

        [Parameter(
            HelpMessage = 'The number of retries for timed out downloads.')]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$Retry = 3
    )

    Begin {

        try {
            ## Native structures to read binary debug information.
            $nativeTypes = Add-Type -PassThru -TypeDefinition @'
            using System;
            using System.IO;
            using System.Runtime.InteropServices;

            [StructLayout(LayoutKind.Sequential, Pack = 1)]
            public struct IMAGE_DEBUG_DIRECTORY_RAW
            {
                [MarshalAs(UnmanagedType.ByValArray, SizeConst = 4)]
                public char[] format;
                public Guid guid;
                public uint age;
                [MarshalAs(UnmanagedType.ByValArray, SizeConst = 255)]
                public char[] name;
            }

            [StructLayout(LayoutKind.Sequential, Pack = 1)]
            public struct IMAGE_DEBUG_DIRECTORY
            {
                public UInt32 Characteristics;
                public UInt32 TimeDateStamp;
                public UInt16 MajorVersion;
                public UInt16 MinorVersion;
                public UInt32 Type;
                public UInt32 SizeOfData;
                public UInt32 AddressOfRawData;
                public UInt32 PointerToRawData;
            }

            [StructLayout(LayoutKind.Sequential)]
            public struct IMAGE_DOS_HEADER
            {
                public UInt16 e_magic;              // Magic number
                public UInt16 e_cblp;               // Bytes on last page of file
                public UInt16 e_cp;                 // Pages in file
                public UInt16 e_crlc;               // Relocations
                public UInt16 e_cparhdr;            // Size of header in paragraphs
                public UInt16 e_minalloc;           // Minimum extra paragraphs needed
                public UInt16 e_maxalloc;           // Maximum extra paragraphs needed
                public UInt16 e_ss;                 // Initial (relative) SS value
                public UInt16 e_sp;                 // Initial SP value
                public UInt16 e_csum;               // Checksum
                public UInt16 e_ip;                 // Initial IP value
                public UInt16 e_cs;                 // Initial (relative) CS value
                public UInt16 e_lfarlc;             // File address of relocation table
                public UInt16 e_ovno;               // Overlay number
                public UInt16 e_res_0;              // Reserved words
                public UInt16 e_res_1;              // Reserved words
                public UInt16 e_res_2;              // Reserved words
                public UInt16 e_res_3;              // Reserved words
                public UInt16 e_oemid;              // OEM identifier (for e_oeminfo)
                public UInt16 e_oeminfo;            // OEM information; e_oemid specific
                public UInt16 e_res2_0;             // Reserved words
                public UInt16 e_res2_1;             // Reserved words
                public UInt16 e_res2_2;             // Reserved words
                public UInt16 e_res2_3;             // Reserved words
                public UInt16 e_res2_4;             // Reserved words
                public UInt16 e_res2_5;             // Reserved words
                public UInt16 e_res2_6;             // Reserved words
                public UInt16 e_res2_7;             // Reserved words
                public UInt16 e_res2_8;             // Reserved words
                public UInt16 e_res2_9;             // Reserved words
                public UInt32 e_lfanew;             // File address of new exe header
            }
            [StructLayout(LayoutKind.Sequential)]
            public struct IMAGE_DATA_DIRECTORY
            {
                public UInt32 VirtualAddress;
                public UInt32 Size;
            }
            [StructLayout(LayoutKind.Sequential, Pack = 1)]
            public struct IMAGE_OPTIONAL_HEADER32
            {
                public UInt16 Magic;
                public Byte MajorLinkerVersion;
                public Byte MinorLinkerVersion;
                public UInt32 SizeOfCode;
                public UInt32 SizeOfInitializedData;
                public UInt32 SizeOfUninitializedData;
                public UInt32 AddressOfEntryPoint;
                public UInt32 BaseOfCode;
                public UInt32 BaseOfData;
                public UInt32 ImageBase;
                public UInt32 SectionAlignment;
                public UInt32 FileAlignment;
                public UInt16 MajorOperatingSystemVersion;
                public UInt16 MinorOperatingSystemVersion;
                public UInt16 MajorImageVersion;
                public UInt16 MinorImageVersion;
                public UInt16 MajorSubsystemVersion;
                public UInt16 MinorSubsystemVersion;
                public UInt32 Win32VersionValue;
                public UInt32 SizeOfImage;
                public UInt32 SizeOfHeaders;
                public UInt32 CheckSum;
                public UInt16 Subsystem;
                public UInt16 DllCharacteristics;
                public UInt32 SizeOfStackReserve;
                public UInt32 SizeOfStackCommit;
                public UInt32 SizeOfHeapReserve;
                public UInt32 SizeOfHeapCommit;
                public UInt32 LoaderFlags;
                public UInt32 NumberOfRvaAndSizes;
                public IMAGE_DATA_DIRECTORY ExportTable;
                public IMAGE_DATA_DIRECTORY ImportTable;
                public IMAGE_DATA_DIRECTORY ResourceTable;
                public IMAGE_DATA_DIRECTORY ExceptionTable;
                public IMAGE_DATA_DIRECTORY CertificateTable;
                public IMAGE_DATA_DIRECTORY BaseRelocationTable;
                public IMAGE_DATA_DIRECTORY Debug;
                public IMAGE_DATA_DIRECTORY Architecture;
                public IMAGE_DATA_DIRECTORY GlobalPtr;
                public IMAGE_DATA_DIRECTORY TLSTable;
                public IMAGE_DATA_DIRECTORY LoadConfigTable;
                public IMAGE_DATA_DIRECTORY BoundImport;
                public IMAGE_DATA_DIRECTORY IAT;
                public IMAGE_DATA_DIRECTORY DelayImportDescriptor;
                public IMAGE_DATA_DIRECTORY CLRRuntimeHeader;
                public IMAGE_DATA_DIRECTORY Reserved;
            }
            [StructLayout(LayoutKind.Sequential, Pack = 1)]
            public struct IMAGE_OPTIONAL_HEADER64
            {
                public UInt16 Magic;
                public Byte MajorLinkerVersion;
                public Byte MinorLinkerVersion;
                public UInt32 SizeOfCode;
                public UInt32 SizeOfInitializedData;
                public UInt32 SizeOfUninitializedData;
                public UInt32 AddressOfEntryPoint;
                public UInt32 BaseOfCode;
                public UInt64 ImageBase;
                public UInt32 SectionAlignment;
                public UInt32 FileAlignment;
                public UInt16 MajorOperatingSystemVersion;
                public UInt16 MinorOperatingSystemVersion;
                public UInt16 MajorImageVersion;
                public UInt16 MinorImageVersion;
                public UInt16 MajorSubsystemVersion;
                public UInt16 MinorSubsystemVersion;
                public UInt32 Win32VersionValue;
                public UInt32 SizeOfImage;
                public UInt32 SizeOfHeaders;
                public UInt32 CheckSum;
                public UInt16 Subsystem;
                public UInt16 DllCharacteristics;
                public UInt64 SizeOfStackReserve;
                public UInt64 SizeOfStackCommit;
                public UInt64 SizeOfHeapReserve;
                public UInt64 SizeOfHeapCommit;
                public UInt32 LoaderFlags;
                public UInt32 NumberOfRvaAndSizes;
                public IMAGE_DATA_DIRECTORY ExportTable;
                public IMAGE_DATA_DIRECTORY ImportTable;
                public IMAGE_DATA_DIRECTORY ResourceTable;
                public IMAGE_DATA_DIRECTORY ExceptionTable;
                public IMAGE_DATA_DIRECTORY CertificateTable;
                public IMAGE_DATA_DIRECTORY BaseRelocationTable;
                public IMAGE_DATA_DIRECTORY Debug;
                public IMAGE_DATA_DIRECTORY Architecture;
                public IMAGE_DATA_DIRECTORY GlobalPtr;
                public IMAGE_DATA_DIRECTORY TLSTable;
                public IMAGE_DATA_DIRECTORY LoadConfigTable;
                public IMAGE_DATA_DIRECTORY BoundImport;
                public IMAGE_DATA_DIRECTORY IAT;
                public IMAGE_DATA_DIRECTORY DelayImportDescriptor;
                public IMAGE_DATA_DIRECTORY CLRRuntimeHeader;
                public IMAGE_DATA_DIRECTORY Reserved;
            }
            [StructLayout(LayoutKind.Sequential, Pack = 1)]
            public struct IMAGE_FILE_HEADER
            {
                public UInt16 Machine;
                public UInt16 NumberOfSections;
                public UInt32 TimeDateStamp;
                public UInt32 PointerToSymbolTable;
                public UInt32 NumberOfSymbols;
                public UInt16 SizeOfOptionalHeader;
                public UInt16 Characteristics;
            }
            [StructLayout(LayoutKind.Explicit)]
            public struct IMAGE_SECTION_HEADER
            {
                [FieldOffset(0)]
                [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
                public char[] Name;
                [FieldOffset(8)]
                public UInt32 VirtualSize;
                [FieldOffset(12)]
                public UInt32 VirtualAddress;
                [FieldOffset(16)]
                public UInt32 SizeOfRawData;
                [FieldOffset(20)]
                public UInt32 PointerToRawData;
                [FieldOffset(24)]
                public UInt32 PointerToRelocations;
                [FieldOffset(28)]
                public UInt32 PointerToLinenumbers;
                [FieldOffset(32)]
                public UInt16 NumberOfRelocations;
                [FieldOffset(34)]
                public UInt16 NumberOfLinenumbers;
                [FieldOffset(36)]
                public DataSectionFlags Characteristics;
                public string Section
                {
                    get { return new string(Name); }
                }
            }
            [Flags]
            public enum DataSectionFlags : uint
            {

                TypeReg = 0x00000000,
                TypeDsect = 0x00000001,
                TypeNoLoad = 0x00000002,
                TypeGroup = 0x00000004,
                TypeNoPadded = 0x00000008,
                TypeCopy = 0x00000010,
                ContentCode = 0x00000020,
                ContentInitializedData = 0x00000040,
                ContentUninitializedData = 0x00000080,
                LinkOther = 0x00000100,
                LinkInfo = 0x00000200,
                TypeOver = 0x00000400,
                LinkRemove = 0x00000800,
                LinkComDat = 0x00001000,
                NoDeferSpecExceptions = 0x00004000,
                RelativeGP = 0x00008000,
                MemPurgeable = 0x00020000,
                Memory16Bit = 0x00020000,
                MemoryLocked = 0x00040000,
                MemoryPreload = 0x00080000,
                Align1Bytes = 0x00100000,
                Align2Bytes = 0x00200000,
                Align4Bytes = 0x00300000,
                Align8Bytes = 0x00400000,
                Align16Bytes = 0x00500000,
                Align32Bytes = 0x00600000,
                Align64Bytes = 0x00700000,
                Align128Bytes = 0x00800000,
                Align256Bytes = 0x00900000,
                Align512Bytes = 0x00A00000,
                Align1024Bytes = 0x00B00000,
                Align2048Bytes = 0x00C00000,
                Align4096Bytes = 0x00D00000,
                Align8192Bytes = 0x00E00000,
                LinkExtendedRelocationOverflow = 0x01000000,
                MemoryDiscardable = 0x02000000,
                MemoryNotCached = 0x04000000,
                MemoryNotPaged = 0x08000000,
                MemoryShared = 0x10000000,
                MemoryExecute = 0x20000000,
                MemoryRead = 0x40000000,
                MemoryWrite = 0x80000000
            }
'@
        }
        catch { }

        ## Download fail list. Used for retrying at the end.
        [System.Collections.ArrayList]$Global:failedDownload = @()
        [System.Collections.ArrayList]$Global:cacheObject = @()

        <#
            This function manages file download and progress display.
            Based on: https://stackoverflow.com/questions/21422364/is-there-any-way-to-monitor-the-progress-of-a-download-using-a-webclient-object
        #>
        function Invoke-FileDownloadWithProgress($Url, $TargetFile, $ParentProgressBarId = -1, $OriginFileName) {
            $scriptBlock = {

                ## Creates a HTTP request based on the symbol download URL.
                $uri = [System.Uri]::new($Url)
                $request = [System.Net.HttpWebRequest]::Create($uri)
                $request.Timeout = 15000

                try {

                    ## Gets the firs response and set values for the progress bar.
                    $response = $request.GetResponse()
                    $totalLength = [System.Math]::Floor($response.ContentLength / 1024)
                    $responseStream = $response.GetResponseStream()

                    ## Creating target directory. Doing this here avoids unecessary cleanup.
                    $targetDir = [System.IO.Path]::GetDirectoryName($TargetFile)
                    if (!(Test-Path -Path $targetDir)) {
                        [void](New-Item -Path $targetDir -ItemType Directory)
                    }

                    ## Creates the file.
                    $targetStream = [System.IO.FileStream]::new($TargetFile, [System.IO.FileMode]::Create)
                    $buffer = [byte[]]::new(10KB)
                    $count = $responseStream.Read($buffer, 0, $buffer.length)

                    ## File download.
                    $downloadedBytes = $count
                    while ($count -gt 0) {

                        $targetStream.Write($buffer, 0, $count)
                        $count = $responseStream.Read($buffer, 0, $buffer.length)
                        $downloadedBytes = $downloadedBytes + $count

                        ## Sending progress status to the main thread.
                        $sync.Activity = "Downloading file '$([System.IO.Path]::GetFileName($TargetFile))'"
                        $sync.Status = "Downloaded ($([System.Math]::Floor($downloadedBytes/1024))K of $($totalLength)K): "
                        $sync.PercentComplete = (([System.Math]::Floor($downloadedBytes / 1024) / $totalLength) * 100)

                        if ([System.Math]::Floor($downloadedBytes / 1024) -eq $totalLength) {
                            break
                        }
                    }

                    $sync.IsComplete = $true
                    [void]$cacheObject.Add("$OriginFileName;$([System.IO.Path]::GetFileName($TargetFile));OK")
                    [void]$Global:existingFilenames.Add($OriginFileName)
                }
                catch {
                    if ($PSItem.Exception.Message -like '*404*Not*Found*') {
                        [void]$cacheObject.Add("$OriginFileName;$([System.IO.Path]::GetFileName($TargetFile));NotFound")
                        [void]$Global:existingFilenames.Add($OriginFileName)
                    }
                    else {
                        [void]$cacheObject.Add("$OriginFileName;$([System.IO.Path]::GetFileName($TargetFile));$($PSItem.Exception.Message)")
                    }
                }
                finally {

                    ## Cleanup
                    if ($targetStream) {
                        $targetStream.Flush()
                        $targetStream.Dispose()
                    }
                    if ($responseStream) { $responseStream.Dispose() }
                }
            }

            <#
                We want to monitor the download job from outsite, so we can enforce a timeout.
                If a file download percentage stays the same for more than $DownloadTimeout,
                we terminate it and add the URL in the failed list for retrying later.
            #>

            ## A synchronized hashtable is a thread safe table we use to display progress of a task running in another runspace.
            ## https://learn.microsoft.com/en-us/powershell/scripting/learn/deep-dives/write-progress-across-multiple-threads?view=powershell-7.3
            $sync = [hashtable]::Synchronized(@{
                Activity        = ''
                Status          = ''
                PercentComplete = 0
                IsComplete      = $false
            })

            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
            $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
            $runspace.Open()
            $runspace.SessionStateProxy.SetVariable('existingFilenames', $Global:existingFilenames)
            $runspace.SessionStateProxy.SetVariable('cacheObject', $Global:cacheObject)
            $runspace.SessionStateProxy.SetVariable('OriginFileName', $OriginFileName)
            $runspace.SessionStateProxy.SetVariable('TargetFile', $TargetFile)
            $runspace.SessionStateProxy.SetVariable('Url', $Url)
            $runspace.SessionStateProxy.SetVariable('sync', $sync)

            $powershell = [powershell]::Create()
            $powershell.Runspace = $runspace
            [void]$powershell.AddScript($scriptBlock)
            [void]$powershell.BeginInvoke()

            $previousPercentage = 0
            $progId = $ParentProgressBarId + 1
            $stopwatch = [System.Diagnostics.Stopwatch]::new()
            do {
                ## Making a copy of $sync to display the progress. If it gets modified in the loop, PS throws and exception.
                $_isComplete = $sync['IsComplete']
                $syncCopy = @{
                    Id              = $progId
                    ParentId        = $ParentProgressBarId
                    Activity        = $sync['Activity']
                    Status          = $sync['Status']
                    PercentComplete = $sync['PercentComplete']
                }
                if (![string]::IsNullOrEmpty($syncCopy.Status)) {
                    Write-Progress @syncCopy
                }

                if ($DownloadTimeout -gt 0) {
                    try {
                        if ($previousPercentage -eq $syncCopy.PercentComplete) { $stopwatch.Start() }
                        else {
                            $stopwatch.Reset()
                            $previousPercentage = $syncCopy.PercentComplete
                        }

                        if ($stopwatch.Elapsed.Seconds -ge $DownloadTimeout) {
                            $Global:failedDownload.Add([PSCustomObject]@{
                                FileName = [System.IO.Path]::GetFileName($TargetFile)
                                Url      = $Url
                            })
                            break
                        }
                        if ($_isComplete -or $syncCopy.PercentComplete -eq 100) {
                            break
                        }
                    }
                    catch {
                        throw $PSItem
                    }
                }

            } while ($powershell.InvocationStateInfo.State -eq 'Running')

            if (![string]::IsNullOrEmpty($sync.Activity)) {
                if ($sync.IsComplete) {
                    Write-Progress -Id $progId -ParentId $ParentProgressBarId -Activity $sync.Activity -Status $sync.Status -PercentComplete 100
                }
                else {
                    Write-Progress -Id $progId -ParentId $ParentProgressBarId -Activity $sync.Activity -Status 'Error downloading file' -PercentComplete 0
                }
            }

            $powershell.Dispose()
            $runspace.Dispose()
        }

        <#
            This function reads bytes from the file stream and marshals it to it's corresponding structure.
        #>
        function Get-ObjectFromStreamBytes([System.IO.BinaryReader]$Reader, [type]$Type) {

            try {
                $bytes = $Reader.ReadBytes([System.Runtime.InteropServices.Marshal]::SizeOf(([type]$Type)))
                if ($bytes.Count -gt 0) {

                    # Technically we don't need to pin the address of 'bytes' because 'PtrToStructure' is going to copy the data before it goes out of scope. Maybe?
                    $hBytes = [System.Runtime.InteropServices.Marshal]::UnsafeAddrOfPinnedArrayElement($bytes, 0)
                    return [System.Runtime.InteropServices.Marshal]::PtrToStructure($hBytes, ([type]$Type))
                }
            }
            catch {

                if ($PSItem.Exception.InnerException.GetType() -ne [System.ObjectDisposedException]) {
                    throw $PSItem
                }
            }
        }

        <#
            This function advances the stream position to the given value.
        #>
        function Invoke-StreamSeek($Stream, $Offset, $Origin) {

            try {
                [void]$Stream.Seek($Offset, $Origin)
            }
            catch {
                if ($PSItem.Exception.InnerException.GetType() -ne [System.ObjectDisposedException]) {
                    throw $PSItem
                }
            }
        }
    }

    Process {

        if (!(Test-Path -Path $DestinationStore -PathType Container)) {
            [void](New-Item -Path $DestinationStore -ItemType Directory)
        }

        ## Creating cache file with header.
        [System.Collections.Generic.HashSet[string]]$Global:existingFilenames = @()
        if (!(Test-Path -Path "$DestinationStore\.DownloadStatusCache.log" -PathType Leaf)) {
            'OriginFile;SymbolFile;DownloadStatus' | Out-File -FilePath "$DestinationStore\.DownloadStatusCache.log"
        }
        else {
            ## Getting all files that either were download or not found. We want to retry other errors.
            $cacheContent = Get-Content -Path "$DestinationStore\.DownloadStatusCache.log" | ConvertFrom-Csv -Delimiter ';'
            [System.Collections.Generic.HashSet[string]]$Global:existingFilenames = ($cacheContent | Where-Object { $PSItem.DownloadStatus -in 'OK', 'NotFound', 'NoDebugInfo' }).OriginFile
        }

        $processedFileCount = 0
        foreach ($file in $Path) {

            $fileName = [System.IO.Path]::GetFileName($file)
            Write-Progress -Id 0 -Activity 'Get PDB Symbol' -Status "Processed files: $processedFileCount/$($Path.Count). $fileName" -PercentComplete (($processedFileCount / $Path.Count) * 100)

            ## Skipping already existing files, or previous failed downloads.
            if ($Global:existingFilenames) {
                if ($Global:existingFilenames.Contains($fileName)) {
                    Write-Progress -Id 0 -Activity 'Get PDB Symbol' -Status "Processed files: $processedFileCount/$($Path.Count). $fileName" -PercentComplete (($processedFileCount / $Path.Count) * 100)
                    $processedFileCount++
                    continue
                }
            }

            ## Loading file in memory, and creating the BinaryReader.
            try {
                $fileStream = [System.IO.FileStream]::new($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
                $reader = [System.IO.BinaryReader]::new($fileStream, [System.Text.Encoding]::UTF8)
            }
            # Not good, I know.
            catch { continue }

            ## Reading IMAGE_DOS_HEADER.
            $dosHeader = Get-ObjectFromStreamBytes -Reader $reader -Type ([type][IMAGE_DOS_HEADER])

            ## Advancing stream position.
            Invoke-StreamSeek -Stream $fileStream -Offset $dosHeader.e_lfanew -Origin ([System.IO.SeekOrigin]::Begin)
            try { [void]$reader.ReadUInt32() }
            # Not good, I know.
            catch { continue }

            ## Reading IMAGE_FILE_HEADER and IMAGE_OPTIONAL_HEADER64/IMAGE_OPTIONAL_HEADER32.
            $fileHeader = Get-ObjectFromStreamBytes -Reader $reader -Type ([type][IMAGE_FILE_HEADER])
            if ($fileHeader.Machine -eq 0x14C) {
                $optHeader = Get-ObjectFromStreamBytes -Reader $reader -Type ([type][IMAGE_OPTIONAL_HEADER32])
            }
            else {
                $optHeader = Get-ObjectFromStreamBytes -Reader $reader -Type ([type][IMAGE_OPTIONAL_HEADER64])
            }

            $offDebug = 0
            $cbFromHeader = 0
            [UInt64]$cbDebug = $optHeader.Debug.Size
            $imgSecHeader = [IMAGE_SECTION_HEADER[]]::new($fileHeader.NumberOfSections)

            ## Reading all section headers.
            for ($headerNo = 0; $headerNo -lt $imgSecHeader.Length; $headerNo++) {

                $imgSecHeader[$headerNo] = Get-ObjectFromStreamBytes -Reader $reader -Type ([type][IMAGE_SECTION_HEADER])

                if (($imgSecHeader[$headerNo].PointerToRawData -ne 0) -and ($imgSecHeader[$headerNo].SizeOfRawData -ne 0) -and ($cbFromHeader -lt ($imgSecHeader[$headerNo].PointerToRawData + $imgSecHeader[$headerNo].SizeOfRawData))) {
                    $cbFromHeader = ($imgSecHeader[$headerNo].PointerToRawData + $imgSecHeader[$headerNo].SizeOfRawData)
                }

                if ($cbDebug -ne 0) {
                    if (($imgSecHeader[$headerNo].VirtualAddress -le $optHeader.Debug.VirtualAddress) -and (($imgSecHeader[$headerNo].VirtualAddress + $imgSecHeader[$headerNo].SizeOfRawData -gt $imgSecHeader[$headerNo].PointerToRawData))) {
                        $offDebug = $optHeader.Debug.VirtualAddress - $imgSecHeader[$headerNo].VirtualAddress + $imgSecHeader[$headerNo].PointerToRawData
                    }
                }

            }

            ## Advancing stream position.
            Invoke-StreamSeek -Stream $fileStream -Offset $offDebug -Origin ([System.IO.SeekOrigin]::Begin)

            <#
                Reading debug information.
            #>
            try {

                ## Creating a synchronized hashtable to easily exchange data with the thread.
                $debugInfo = New-Object -TypeName IMAGE_DEBUG_DIRECTORY_RAW
                $syncedObjects = [hashtable]::Synchronized(@{
                    DebugInfo    = [ref]$debugInfo
                    FileStream   = [ref]$fileStream
                    BinaryReader = [ref]$reader
                    CbDebug      = $cbDebug
                    Success      = $false
                    Timeout      = $ReadTimeout
                    NativeTypes  = $nativeTypes
                })

                ## Creating runspace.
                $readRunspace = [runspacefactory]::CreateRunspace()
                $readRunspace.ApartmentState = [System.Threading.ApartmentState]::STA
                $readRunspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
                $readRunspace.Open()
                $readRunspace.SessionStateProxy.SetVariable('syncedObjects', $syncedObjects)

                ## Creating PowerShell instance and executing it.
                $readPowershell = [powershell]::Create()
                $readPowershell.Runspace = $readRunspace
                [void]$readPowershell.AddScript({
                    function Get-ObjectFromStreamBytes([System.IO.BinaryReader]$Reader, [type]$Type) {

                        try {
                            $bytes = $Reader.ReadBytes([System.Runtime.InteropServices.Marshal]::SizeOf(([type]$Type)))
                            if ($bytes.Count -gt 0) {

                                # Technically we don't need to pin the address of 'bytes' because 'PtrToStructure' is going to copy the data before it goes out of scope. Maybe?
                                $hBytes = [System.Runtime.InteropServices.Marshal]::UnsafeAddrOfPinnedArrayElement($bytes, 0)
                                return [System.Runtime.InteropServices.Marshal]::PtrToStructure($hBytes, ([type]$Type))
                            }
                        }
                        catch {

                            if ($PSItem.Exception.InnerException.GetType() -ne [System.ObjectDisposedException]) {
                                throw $PSItem
                            }
                        }
                    }

                    function Invoke-StreamSeek($Stream, $Offset, $Origin) {

                        try {
                            [void]$Stream.Seek($Offset, $Origin)
                        }
                        catch {
                            if ($PSItem.Exception.InnerException.GetType() -ne [System.ObjectDisposedException]) {
                                throw $PSItem
                            }
                        }
                    }

                    $IMAGE_DEBUG_DIRECTORY = $syncedObjects.NativeTypes.Where({ $PSItem.Name -eq 'IMAGE_DEBUG_DIRECTORY' }).UnderlyingSystemType
                    $IMAGE_DEBUG_DIRECTORY_RAW = $syncedObjects.NativeTypes.Where({ $PSItem.Name -eq 'IMAGE_DEBUG_DIRECTORY_RAW' }).UnderlyingSystemType

                    $stopwatch = [System.Diagnostics.Stopwatch]::new()
                    $stopwatch.Start()
                    while ($syncedObjects.CbDebug -ge [System.Runtime.InteropServices.Marshal]::SizeOf([type]$IMAGE_DEBUG_DIRECTORY)) {
                        if ($syncedObjects.Timeout -gt 0 -and $stopwatch.Elapsed.Seconds -ge $syncedObjects.Timeout) {
                            break
                        }
                        if (!$syncedObjects.Success) {

                            $imgDebugDir = Get-ObjectFromStreamBytes -Reader $syncedObjects.BinaryReader.Value -Type ([type]$IMAGE_DEBUG_DIRECTORY)

                            $seekPosition = $syncedObjects.FileStream.Value.Position

                            if ($imgDebugDir.Type -eq 2) {

                                ## Advancing stream position.
                                Invoke-StreamSeek -Stream $syncedObjects.FileStream.Value -Offset $imgDebugDir.PointerToRawData -Origin ([System.IO.SeekOrigin]::Begin)
                                $syncedObjects.DebugInfo.Value = Get-ObjectFromStreamBytes -Reader $syncedObjects.BinaryReader.Value -Type ([type]$IMAGE_DEBUG_DIRECTORY_RAW)

                                $syncedObjects.Success = $true
                                if ([string]::new($syncedObjects.DebugInfo.Value).Contains('.ni.')) {

                                    ## Advancing stream position.
                                    Invoke-StreamSeek -Stream $syncedObjects.FileStream.Value -Offset $seekPosition -Origin ([System.IO.SeekOrigin]::Begin)
                                    $syncedObjects.Success = $false
                                }
                            }
                        }

                        $syncedObjects.CbDebug -= [System.Runtime.InteropServices.Marshal]::SizeOf([type]$IMAGE_DEBUG_DIRECTORY)
                    }
                    $stopwatch.Stop()
                })
                [void]$readPowershell.InvokeAsync()

                $displayTimeout = 0
                do {

                    switch ($displayTimeout) {
                        { $PSItem -lt 100 } { Write-Progress -Id 1 -ParentId 0 -Activity "Reading file $fileName" -Status 'Looking for debug information.' }
                        { $PSItem -ge 100 -and $PSItem -lt 200 } { Write-Progress -Id 1 -ParentId 0 -Activity "Reading file $fileName" -Status 'Looking for debug information..' }
                        { $PSItem -ge 200 -and $PSItem -lt 300 } { Write-Progress -Id 1 -ParentId 0 -Activity "Reading file $fileName" -Status 'Looking for debug information...' }
                        { $PSItem -ge 300 } { $displayTimeout = 0 }
                    }

                    Start-Sleep -Milliseconds 1
                    $displayTimeout++

                } while ($readPowershell.InvocationStateInfo.State -eq 'Running')

                if ($readPowershell.InvocationStateInfo.State -eq 'Failed') {
                    throw $readPowershell.InvocationStateInfo.Reason
                }
            }
            catch { throw $PSItem }
            finally {
                [void]$readPowershell.StopAsync($null, $null)
                $readPowershell.Dispose()
                $readRunspace.Dispose()
            }

            ## Download stage.
            if ($syncedObjects.Success) {
                $pdbName = [string]::new($debugInfo.name)
                if (![string]::IsNullOrEmpty($pdbName)) {

                    $pdbName = $pdbName.Remove(($pdbName | Select-String -Pattern '\0').Matches[0].Index).Split('\')[$pdbName.Split('\').Length - 1]

                    if (![string]::IsNullOrEmpty($pdbName)) {
                        ## Debug file age.
                        $pdbAge = $debugInfo.age.ToString('X')

                        ## Creating the destination path. Here we try to mimic SymChk.exe directory structure.
                        $pdbCode = "$($debugInfo.guid.ToString('N').ToUpper())$pdbAge"

                        if ($DestinationStore.EndsWith('\')) { $destinationPath = "$DestinationStore$pdbName\$pdbCode" }
                        else { $destinationPath = "$DestinationStore\$pdbName\$pdbCode" }

                        ## Assembling the download URL.
                        $downloadUrl = "http://msdl.microsoft.com/download/symbols/$pdbName/$pdbCode/$pdbName"

                        ## Download job.
                        Invoke-FileDownloadWithProgress -Url $downloadUrl -TargetFile "$destinationPath\$pdbName" -ParentProgressBarId 1 -OriginFileName $fileName
                    }
                }
            }
            else {
                [void]$cacheObject.Add("$fileName;NoDebugInfo;NoDebugInfo")
                [void]$Global:existingFilenames.Add($OriginFileName)
            }

            ## Cleanup.
            $fileStream.Flush()
            $fileStream.Dispose()
            $reader.Dispose()

            $processedFileCount++
        }

        ## Managing retries.
        if ($Global:failedDownload.Count -gt 0 -and $Retry -gt 0) {

            ## Moving the list so we can compare after retries.
            $currentFailedList = $Global:failedDownload
            $Global:failedDownload = [System.Collections.ArrayList]::new()

            do {
                foreach ($failure in $currentFailedList) {
                    $retries = 0
                    Write-Progress -Id 1 -Activity 'Retrying download.' -Status "File: $($failure.FileName). Retries: $($retries + 1)/$Retry." -PercentComplete (($retries / $Retry) * 100)
                }

                ## If list count it's still 0, all retries succeeded.
                if ($Global:failedDownload.Count -eq 0) {
                    break
                }

                $retries++

            } while ($retries -lt $Retry)
        }
    }

    # Clean {
    #     ## Saving progress to the cache.
    #     $Global:cacheObject | Out-File -FilePath "$DestinationStore\.DownloadStatusCache.log" -Append

    #     if ($readPowershell.InvocationStateInfo.State -eq 'Running') {
    #         [void]$readPowershell.StopAsync($null, $null)
    #         $readPowershell.Dispose()
    #         $readRunspace.Dispose()
    #     }
    # }
}