function Update-DotNetSDK {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]
        $SearchPattern = 'Microsoft.DotNet.SDK'
    )
    $FileScriptBlock = ''
    $neededcmdlets = @('Write-Logg')
    foreach ($cmd in $neededcmdlets) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            if (-not (Get-Command -Name 'Install-Cmdlet' -ErrorAction SilentlyContinue)) {
                $method = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Install-Cmdlet.ps1'
                $finalstring = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
                New-Module -Name 'InstallCmdlet' -ScriptBlock $finalstring | Import-Module
            }
            Write-Verbose "Importing cmdlet: $cmd"
            $scriptBlock = Install-Cmdlet -RepositoryCmdlets $cmd -PreferLocal -Force

            # Check if the returned value is a ScriptBlock and import it properly
            if ($scriptBlock -is [scriptblock]) {
                $moduleName = "Dynamic_$cmd"
                New-Module -Name $moduleName -ScriptBlock $scriptBlock | Import-Module -Force
                Write-Verbose "Imported $cmd as dynamic module: $moduleName"
            }
            elseif ($scriptBlock -is [System.Management.Automation.PSModuleInfo]) {
                # If a module info was returned, it's already imported
                Write-Verbose "Module for $cmd was already imported: $($scriptBlock.Name)"
            }
            elseif ($($scriptBlock | Get-Item) -is [System.IO.FileInfo]) {
                # If a file path was returned, import it
                $FileScriptBlock += $(Get-Content -Path $scriptBlock -Raw) + "`n"
                Write-Verbose "Imported $cmd from file: $scriptBlock"
            }
            else {
                Write-Warning "Could not import $cmd`: Unexpected return type from Install-Cmdlet"
                Write-Warning "Returned: $($scriptBlock)"
            }
        }
    }
    $finalFileScriptBlock = [scriptblock]::Create($FileScriptBlock.ToString() + "`nExport-ModuleMember -Function * -Alias *")
    New-Module -Name 'cmdletCollection' -ScriptBlock $finalFileScriptBlock | Import-Module -Force


    # Search for available .NET SDKs using winget
    $availableSDKs = winget search $SearchPattern | Where-Object { $_ -match 'Microsoft\.DotNet\.SDK\.' }

    # Extract the version or identifier part of the SDK from the search results
    $DotNetVersions = $availableSDKs -replace '.*Microsoft\.DotNet\.SDK\.([^\s]+).*', '$1'

    foreach ($DotNetVersion in $DotNetVersions) {
        Write-Logg -Message "Installing .NET SDK version $DotNetVersion"
        winget install $('Microsoft.DotNet.SDK.' + $DotNetVersion) --force --accept-source-agreements --accept-package-agreements
        Write-Logg -Message "Finished installing .NET SDK version $DotNetVersion"
    }
}