<#
.SYNOPSIS
    Captures a memory dump of the system process.

.DESCRIPTION
    The Get-MemoryCapture function captures a memory dump of the system process and saves it to a specified location. It uses P/Invoke to call the MiniDumpWriteDump function from the DbgHelp.dll. This function requires administrative privileges to execute.

.PARAMETER OutputPath
    The file path where the memory dump will be saved.

.EXAMPLE
    Get-MemoryCapture -OutputPath "C:\path\to\output.dmp"
    Captures a memory dump of the system process and saves it to "C:\path\to\output.dmp".

.INPUTS
    None

.OUTPUTS
    File
    Outputs a memory dump file to the specified location.

.NOTES
    This script requires administrative privileges.
    Ensure that error handling is appropriately managed in production environments.

.LINK
    https://docs.microsoft.com/en-us/windows/win32/api/minidumpapiset/nf-minidumpapiset-minidumpwritedump

#>
function Get-MemoryCapture {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true, HelpMessage="Specify the output path for the memory dump.")]
        [string]$OutputPath
    )

    Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;

        public class MiniDump {
            [DllImport("DbgHelp.dll")]
            public static extern bool MiniDumpWriteDump(IntPtr hProcess, int ProcessId, IntPtr hFile, int DumpType, IntPtr ExceptionParam, IntPtr UserStreamParam, IntPtr CallbackParam);
        }
"@

    try {
        # Process handle and process ID for the system process or any target process
        $process = Get-Process -Name 'System'
        $processHandle = $process.Handle
        $processId = $process.Id

        # File handle for output
        $fileStream = New-Object System.IO.FileStream($OutputPath, [System.IO.FileMode]::Create)
        $fileHandle = $fileStream.SafeFileHandle

        # Dump type - 2 for full memory dump
        $dumpType = 2

        # Call MiniDumpWriteDump
        $result = [MiniDump]::MiniDumpWriteDump($processHandle, $processId, $fileHandle.DangerousGetHandle(), $dumpType, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)

        if (-not $result) {
            throw "Memory dump failed."
        }

        Write-Verbose "Memory dump successfully created at $OutputPath"
    } catch {
        Write-Error $_.Exception.Message
    } finally {
        if ($fileStream) {
            $fileStream.Dispose()
        }
    }
}
