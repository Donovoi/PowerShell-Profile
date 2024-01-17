<#
.SYNOPSIS
Invalidates file handles for a given path.

.DESCRIPTION
The Set-InvalidHandle function takes a path as input, searches for any file handles associated with that path, and attempts to invalidate them. If an error occurs, the function will return a verbose error message. This function uses low-level system calls to ensure high reliability.

.PARAMETER Path
The path to the file for which to invalidate handles. This parameter is mandatory.

.OUTPUTS
Returns a boolean indicating success or failure.

.EXAMPLE
Set-InvalidHandle -Path "C:\Path\To\File.txt"

#>
function Set-InvalidHandle {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $Path
    )

    begin {
        $Error.Clear()
        $HandlePath = Resolve-Path -Path $Path | Select-Object -ExpandProperty Path
        $Handle = $null

        $NtSetInformationFile = @'
                [DllImport("ntdll.dll", SetLastError = true)]
                public static extern int NtSetInformationFile(IntPtr FileHandle, ref IO_STATUS_BLOCK IoStatusBlock, IntPtr FileInformation, int Length, int FileInformationClass);
'@
        $Kernel32 = @'
                [DllImport("kernel32.dll", SetLastError = true)]
                public static extern int CloseHandle(IntPtr hObject);
'@
        $CloseHandle = Add-Type -MemberDefinition $Kernel32 -Name 'CloseHandleWin32' -Namespace Win32Functions -PassThru
        $SetInformationFile = Add-Type -MemberDefinition $NtSetInformationFile -Name 'NtSetInformationFileWin32' -Namespace Win32Functions -PassThru
    }

    process {
        $success = $false

        try {
            $Handle = Get-Handle -Path $HandlePath
            $success = $true
        }
        catch {
            Write-Error "Failed to get handle: $($_.Exception.Message)"
        }

        if ($Handle) {
            $Handle | ForEach-Object -Process {
                $ProcessHandle = $_.Handle
                $IoStatusBlock = New-Object IO_STATUS_BLOCK

                try {
                    $CloseHandle::CloseHandle($ProcessHandle) | Out-Null
                    $SetInformationFile::NtSetInformationFile($ProcessHandle, [ref]$IoStatusBlock, [IntPtr]::Zero, 0, 11) | Out-Null
                    $success = $true
                }
                catch {
                    Write-Error "Failed to close handle: $($_.Exception.Message)"
                    $success = $false
                }
            }
        }
        else {
            Write-Error "Failed to get handle for $HandlePath"
            $success = $false
        }

        return $success
    }
}