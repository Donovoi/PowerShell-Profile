function Install-Profile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $profileURL = 'https://github.com/Donovoi/PowerShell-Profile.git'
    )

    $myDocuments = [System.Environment]::GetFolderPath('MyDocuments')
    $powerShell7ProfilePath = Join-Path -Path $myDocuments -ChildPath 'PowerShell'

    function Install-PowerShell7 {
        if (-not (Get-Command -Name pwsh -ErrorAction SilentlyContinue)) {
            if (Get-Command -Name winget -ErrorAction SilentlyContinue) {
                Write-Host 'PowerShell 7 is not installed. Installing now...' -ForegroundColor Yellow
                winget install --id=Microsoft.PowerShell
                Write-Host 'PowerShell 7 installed successfully!' -ForegroundColor Green
            }
            else {
                Write-Host 'winget is not available. Please install winget first.' -ForegroundColor Red
                exit
            }
        }
    }

    function New-ProfileFolder {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )
        if (Test-Path -Path $path) {
            Invoke-RemoveItem -Path $path
        }
        New-Item -Path $path -ItemType Directory -Force
        Write-Host "Profile folder created successfully at $path" -ForegroundColor Green
    }

    function Import-Functions {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )
        $functionPath = Join-Path -Path $path -ChildPath 'functions'
        if (Test-Path -Path $functionPath) {
            $FunctionsFolder = Get-ChildItem -Path (Join-Path -Path $functionPath -ChildPath '*.ps*') -Recurse
            $FunctionsFolder.ForEach{
                try {
                    . $_.FullName
                }
                catch {
                    Write-Host "Error importing function from $($_.FullName): $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }

    function Install-Git {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            if (Get-Command -Name winget -ErrorAction SilentlyContinue) {
                winget install --id=Git.Git
            }
            else {
                Write-Host 'winget is not available. Please install winget first.' -ForegroundColor Red
                exit
            }
        }
    }

    function Clone-Repo {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )
        if (Test-Path -Path $path) {
            Set-Location -Path $path
            $repoPath = Join-Path -Path $path -ChildPath 'powershellprofile'
            if (Test-Path -Path $repoPath) {
                Remove-Item -Path $repoPath -Recurse -Force
            }
            try {
                git clone --recursive $profileURL $repoPath
                Copy-Item -Path "$repoPath\*" -Destination $path -Force -Recurse
            }
            catch {
                Write-Host "Error cloning repository: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    function Invoke-RemoveItem {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string[]]$Path
        )

        begin {
            # Check if the file is removable and if not, try to make it removable
            $Path | ForEach-Object {
                if (-not (Test-IsRemovable -Path $_)) {
                    Set-Removable -Path $_
                }
            }
        }

        process {
            # Attempt to remove the file
            $Path | ForEach-Object {
                try {
                    if (Test-IsRemovable -Path $_) {
                        Remove-Item $_ -ErrorAction Stop -Recurse -Force
                    }
                    else {
                        Write-Error "Failed to remove the file: $_"

                    }

                }
                catch {
                    Write-Warning "Unable to delete item, error: $_"

                }
                Write-Output 'Now trying to take ownership and grant full control access...'
                Write-Host -Object ' and maybe get a HANDLE on things..👌' -ForegroundColor Green
                Set-Removable -Path $_.FullName

            }
        }
    }

    function Test-IsRemovable {
        [CmdletBinding()]
        [OutputType([bool])]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        try {
            Remove-Item $Path -Force -Recurse
            return $true
        }
        catch {
            return $false
        }
    }

    function Set-Removable {
        [CmdletBinding(SupportsShouldProcess)]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        if ($PSCmdlet.ShouldProcess($Path, 'Take ownership and grant full control')) {
            try {
                takeown /f $Path
                icacls $Path /grant "${env:USERNAME}:(F)"
                Set-InvalidHandle -Path $Path
            }
            catch {
                Write-Error "Failed to make the file removable: $($_.Exception.Message)"
            }
        }
    }
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
                    $script:success = $false

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


    function Get-Handle {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$FilePath
        )
        Add-Type -TypeDefinition @'
        using System;
        using System.Diagnostics;
        using System.ComponentModel;
        using System.Runtime.InteropServices;

        public class ProcessHandler
        {
            [DllImport("kernel32.dll")]
            public static extern IntPtr OpenProcess(uint processAccess, bool bInheritHandle, int processId);
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern bool CloseHandle(IntPtr hObject);

            public IntPtr GetProcessHandle(int pid)
            {
                return OpenProcess(0x0400 | 0x0010, false, pid);
            }

            public void CloseProcessHandle(IntPtr handle)
            {
                CloseHandle(handle);
            }
        }
'@ -Language CSharp

        $processHandler = New-Object ProcessHandler
        $escapedFilePath = $FilePath -replace '\\', '\\\\'
        $escapedFileNameWithExtension = Split-Path $escapedFilePath -Leaf

        do {
            $processes = Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%$escapedFileNameWithExtension%'"

            $processes | ForEach-Object {
                $procHandle = $processHandler.GetProcessHandle($_.ProcessId)

                if ($procHandle -ne [IntPtr]::Zero) {
                    $userDecision = $null
                    do {
                        $userDecision = Read-Host "Invalidate handles or Kill Process($($_.Caption) - $($_.ExecutablePath))?(I/K/Ignore)"
                        if ($userDecision -eq 'I') {
                            $processHandler.CloseProcessHandle($procHandle)
                            Write-Logg -Message 'Handle invalidated.'
                        }
                        elseif ($userDecision -eq 'K') {
                            Stop-Process -Id $_.ProcessId -Force
                            Write-Logg -Message 'Process killed.'
                        }
                    } while ($userDecision -ne 'I' -and $userDecision -ne 'K' -and $userDecision -ne 'Ignore')
                    $processHandler.CloseProcessHandle($procHandle)
                }
            }
            Start-Sleep -Seconds 1
        } while ((Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%$escapedFileNameWithExtension%'").Count -gt 0)
    }

    Install-PowerShell7

    New-ProfileFolder -Path $powerShell7ProfilePath
    Import-Functions -Path $powerShell7ProfilePath

    Install-Git

    $folderarray = $powerShell7ProfilePath
    $folderarray | ForEach-Object -Process {
        Clone-Repo -Path $_
        Import-Functions -Path $_
    }
}

# Install-Profile
