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

function Get-Handle {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

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
                        Write-Log -Message 'Handle invalidated.' 
                    } 
                    elseif ($userDecision -eq 'K') { 
                        Stop-Process -Id $_.ProcessId -Force 
                        Write-Log -Message 'Process killed.' 
                    } 
                } while ($userDecision -ne 'I' -and $userDecision -ne 'K' -and $userDecision -ne 'Ignore') 
                $processHandler.CloseProcessHandle($procHandle)
            }
        }
        Start-Sleep -Seconds 1 
    } while ((Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%$escapedFileNameWithExtension%'").Count -gt 0)
}