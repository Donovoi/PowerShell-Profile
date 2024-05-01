

# Example function to load a DLL and potentially enumerate exported functions
function Get-ExportedFunctions {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path
    )
    # Import the required cmdlets
    $neededcmdlets = @('Install-Dependencies')
    $neededcmdlets | ForEach-Object {
        if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose -Message "Importing cmdlet: $_"
            $Cmdletstoinvoke = Install-Cmdlet -donovoicmdlets $_
            $Cmdletstoinvoke | Import-Module -Force
        }
    }

    Install-Dependencies -PSModule 'PSReflect-Functions' -NoNugetPackage -Verbose

    # Prompt user to select file if no path is provided
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Type -AssemblyName System.Windows.Forms
        $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $fileDialog.Filter = 'Executable files (*.exe;*.dll)|*.exe;*.dll'
        $fileDialog.Title = 'Select an Executable File'
        if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $Path = $fileDialog.FileName
        }
        else {
            Write-Error 'No file selected, exiting function.'
            return
        }
    }



    # Load the library
    $libHandle = LoadLibrary($Path)
    if ($libHandle -eq [IntPtr]::Zero) {
        Write-Error "Failed to load library from path: $Path"
        return
    }

    try {
        # Here you might enumerate functions
        Write-Output "Library loaded, handle: $libHandle"
        # enumerate functions
        $exportedFunctions = @()
        $currentFunction = 0
        while ($true) {
            $functionPtr = [NativeMethods]::GetProcAddress($libHandle, $currentFunction.ToString())
            if ($functionPtr -eq [IntPtr]::Zero) {
                $stderror = [NativeMethods]::GetLastError()
                if ($error -eq 0) {
                    break
                }
                else {
                    Write-Error "Failed to get function pointer for function number: $currentFunction, error code: $stderror"
                    break
                }
            }
            $exportedFunctions += @{
                FunctionNumber  = $currentFunction
                FunctionPointer = $functionPtr
            }
            $currentFunction++
        }
    }
    finally {
        if ($libHandle -ne [IntPtr]::Zero) {
            [bool]$freed = [NativeMethods]::FreeLibrary($libHandle)
            if ($freed) {
                Write-Output 'Library successfully freed.'
            }
            else {
                Write-Output 'Failed to free the library.'
            }
        }
    }
}
