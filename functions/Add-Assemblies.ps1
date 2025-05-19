function Add-Assemblies ([bool]$UseDefault, [string[]]$CustomAssemblies) {
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
            Write-Logg -Message "Successfully added assembly: $assembly" -Level Verbose
        }
        catch {
            Write-Logg -Message "Failed to add assembly: $assembly. Error: $_" -Level Verbose
        }
    }
}