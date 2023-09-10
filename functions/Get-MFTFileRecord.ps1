# function Get-MFTFileRecord {
#     [CmdletBinding()]
#     param (
#         [Parameter(Mandatory = $true)]
#         [string]$SearchPattern,

#         [Parameter(Mandatory = $false)]
#         [switch]$IsRegex
#     )

#     Add-Type @'
#         using System;
#         using System.Runtime.InteropServices;
#         public class VolumeAPI {
#             [DllImport("kernel32.dll", SetLastError = true)]
#             public static extern IntPtr CreateFile(
#                 string lpFileName, 
#                 uint dwDesiredAccess, 
#                 uint dwShareMode, 
#                 IntPtr lpSecurityAttributes, 
#                 uint dwCreationDisposition, 
#                 uint dwFlagsAndAttributes, 
#                 IntPtr hTemplateFile);

#             [DllImport("kernel32.dll", SetLastError = true)]
#             public static extern int DeviceIoControl(
#                 IntPtr hDevice, 
#                 uint dwIoControlCode, 
#                 IntPtr lpInBuffer, 
#                 uint nInBufferSize, 
#                 ref uint lpOutBuffer, 
#                 uint nOutBufferSize, 
#                 ref uint lpBytesReturned, 
#                 IntPtr lpOverlapped);
#         }
# '@

#     # Define necessary constants
#     $GENERIC_READ = 0x80000000
#     $FILE_SHARE_READ = 1
#     $OPEN_EXISTING = 3
#     $FSCTL_GET_NTFS_FILE_RECORD = 0x00090068

#     # Open a handle to the volume
#     $volumeHandle = [VolumeAPI]::CreateFile(
#         '\\.\C:', 
#         $GENERIC_READ, 
#         $FILE_SHARE_READ, 
#         [IntPtr]::Zero, 
#         $OPEN_EXISTING, 
#         0, 
#         [IntPtr]::Zero)

#     if ($volumeHandle -eq -1) {
#         throw 'Unable to open volume handle.'
#     }

#     try {
#         # Initialize an index to keep track of the current MFT record
#         $index = 0
        
#         while ($true) {
#             # Set up the input buffer with the current index
#             $inBuffer = [BitConverter]::GetBytes($index)
#             $outBuffer = New-Object Byte[] 1024
#             $bytesReturned = New-Object UInt32
        
#             # Call DeviceIoControl to get the current MFT record
#             $result = [VolumeAPI]::DeviceIoControl(
#                 $volumeHandle, 
#                 $FSCTL_GET_NTFS_FILE_RECORD, 
#                 [System.Runtime.InteropServices.Marshal]::UnmanagedAddrOfPinnedArrayElement($inBuffer, 0), 
#                 [uint32]$inBuffer.Length, 
#                 [ref]$outBuffer, 
#                 [uint32]$outBuffer.Length, 
#                 [ref]$bytesReturned, 
#                 [IntPtr]::Zero)
        
#             if ($result -eq 0) {
#                 # No more records to read, break out of the loop
#                 break
#             }
        
#             # Parse the MFT record to extract the file name
             
#             $fileName = '...'  # Replace with actual parsing logic
        
#             # Match the file name against the search pattern
#             if ($IsRegex -and $fileName -match $SearchPattern) {
#                 Write-Output $fileName
#             }
#             elseif ($fileName -like $SearchPattern) {
#                 Write-Output $fileName
#             }
        
#             # Increment the index to read the next record
#             $index++
#         }
#     }
#     finally {
#         # Close the handle
#         [void][Runtime.InteropServices.Marshal]::CloseHandle($volumeHandle)
#     }
# }
