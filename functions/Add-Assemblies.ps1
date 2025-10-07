<#
.SYNOPSIS
    Loads .NET assemblies into the current PowerShell session.

.DESCRIPTION
    The Add-Assemblies function loads specified .NET assemblies into the current PowerShell session.
    It can load a default set of common assemblies or custom assemblies specified by the user.
    Commonly used for adding WPF, Windows Forms, and other .NET Framework assemblies.

.PARAMETER UseDefault
    If set to $true, loads a default set of commonly used assemblies including:
    - PresentationFramework (WPF)
    - PresentationCore (WPF)
    - WindowsBase (WPF)
    - System.Windows.Forms
    - System.Drawing
    - System.Data
    - System.Data.DataSetExtensions
    - System.Xml

.PARAMETER CustomAssemblies
    An array of assembly names to load. These are loaded in addition to default assemblies if UseDefault is true.
    Assembly names should be short names (e.g., 'System.Windows.Forms') not full paths.

.EXAMPLE
    Add-Assemblies -UseDefault $true
    
    Loads all default assemblies (WPF, Windows Forms, etc.).

.EXAMPLE
    Add-Assemblies -CustomAssemblies @('System.Net.Http', 'System.Json')
    
    Loads only the specified custom assemblies.

.EXAMPLE
    Add-Assemblies -UseDefault $true -CustomAssemblies @('System.Management.Automation')
    
    Loads default assemblies plus additional custom assemblies.

.OUTPUTS
    None. Assemblies are loaded into the session and verbose messages are written via Write-Logg.

.NOTES
    If an assembly fails to load, an error is logged via Write-Logg but execution continues.
    Requires Write-Logg cmdlet for logging.
#>
function Add-Assemblies ([bool]$UseDefault, [string[]]$CustomAssemblies) {
    [CmdletBinding()]
    [OutputType([void])]
    $neededcmdlets = @(
        'Write-Logg'

    )
    $neededcmdlets | ForEach-Object {
        if (-not (Get-Command -Name $_ -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose -Message "Importing cmdlet: $_"
            $Cmdletstoinvoke = Install-Cmdlet -RepositoryCmdlets $_
            $Cmdletstoinvoke | Import-Module -Force
        }
    }
    # Initialize the list of assemblies
    $assembliesToAdd = @()
    if ($UseDefault) {
        $assembliesToAdd += @(
            'PresentationFramework',
            'PresentationCore',
            'WindowsBase',
            'System.Windows.Forms',
            'System.Drawing',
            'System.Data',
            'System.Data.DataSetExtensions',
            'System.Xml'
        )
    }
    if ($CustomAssemblies) {
        $assembliesToAdd += $CustomAssemblies
    }

    foreach ($assembly in $assembliesToAdd) {
        try {
            Add-Type -AssemblyName $assembly -ErrorAction Stop
            Write-Logg -Message "Successfully added assembly: $assembly" -Level VERBOSE
        }
        catch {
            Write-Logg -Message "Failed to add assembly: $assembly. Error: $_" -Level VERBOSE
        }
    }
}