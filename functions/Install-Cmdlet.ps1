<#
.SYNOPSIS
    Install-Cmdlet is a function that installs a cmdlet from a given url.

.DESCRIPTION
    The Install-Cmdlet function takes a url as input and installs a cmdlet from the content obtained from the url.
    It creates a new PowerShell module from the content obtained from the URI.
    'Invoke-RestMethod' is used to download the script content.
    The script content is encapsulated in a script block and a new module is created from it.
    'Export-ModuleMember' exports all functions and aliases from the module.
    The function can be used to install cmdlets from a given url.

.PARAMETER Url
    The url from which the cmdlet should be installed.

.PARAMETER CmdletToInstall
    The cmdlet that should be installed from the given url.
    If no cmdlet is specified, all cmdlets from the given url will be installed.

.EXAMPLE
    Install-Cmdlet -Url 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/Write-Logg.ps1' -CmdletToInstall 'Write-Logg'
    This example installs the Write-Logg cmdlet from the given url.
#>
function Install-Cmdlet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Url')]
        [string[]]$Urls,
        [Parameter(Mandatory = $false, ParameterSetName = 'Url')]
        [string[]]$CmdletToInstall = '*',
        [Parameter(Mandatory = $false)]
        [string]$ModuleName = 'InMemoryModule',
        [Parameter(Mandatory = $true, ParameterSetName = 'Donovoicmdlets')]
        [string[]]$donovoicmdlets,
        [Parameter(Mandatory = $false, ParameterSetName = 'Donovoicmdlets')]
        [switch]$PreferLocal,
        [Parameter(Mandatory = $false)]
        [string]$LocalModuleFolder = "$PSScriptRoot\PowerShellScriptsAndResources\Modules\cmdletCollection\"
    )
    if ($donovoicmdlets -and $PreferLocal) {
        $cmdletsToDownload = @()
        foreach ($cmdlet in $donovoicmdlets) {
            if (-not (Test-Path -Path "$LocalModuleFolder\$cmdlet.ps1")) {
                Write-Error -Message "The cmdlet $cmdlet was not found locally"
                Write-Warning -Message "The cmdlet $cmdlet was not found locally"
                Write-Information -MessageData "Downloading $cmdlet now..."
                Write-Information -MessageData "All cmdlets will be downloaded to $PSScriptRoot/Modules/"
                $cmdletsToDownload += $cmdlet
                continue
            }
            else {
                # import existing local module
                Import-Module -Name "$LocalModuleFolder\$cmdlet.ps1" -Force
                Write-Information -MessageData "The cmdlet $cmdlet was found locally and imported"
            }
        }
        $urls = @()
        if ($donovoicmdlets -and ( (-not $PreferLocal) -or ($cmdletsToDownload.Length -gt 0) )) {
            $sburls = [System.Text.StringBuilder]::new()
            foreach ($cmdlet in $donovoicmdlets) {
                # build the array of urls for invoke-restmethod
                $sburls.AppendLine("https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/$cmdlet.ps1") | Out-Null
            }
            # clean up and remove any empty lines
            $urls += $sburls.ToString().Split("`n").Trim() | Where-Object { $_ }



            try {
                $Cmdletsarraysb = [System.Text.StringBuilder]::new()
                $urls | ForEach-Object -Process {
                    $link = $_
                    # make sure we are given a valid url
                    $searchpattern = "((ht|f)tp(s?)\:\/\/?)[0-9a-zA-Z]([-.\w]*[0-9a-zA-Z])*(:(0-9)*)*(\/?)([a-zA-Z0-9\-\.\?\,\'\/\\\+&%\$#_]*)?"
                    $regexoptions = [System.Text.RegularExpressions.RegexOptions]('IgnoreCase, IgnorePatternWhitespace, Compiled')
                    $compiledregex = [regex]::new($searchpattern, $regexoptions)
                    if (-not($Link -match $compiledregex)) {
                        throw [System.ArgumentException]::new('The given url is not valid')
                    }

                    try {
                        $Cmdletsarraysb.AppendLine($(Invoke-RestMethod -Uri $link.ToString())) | Out-Null
                    }
                    catch {
                        Write-Error -Message "Make sure the casing is correctFailed to download the cmdlet from $link"
                        Write-Error -Message 'Make sure the casing is correct'
                        throw $_
                    }
                }
                $modulescriptblock = [scriptblock]::Create($Cmdletsarraysb.ToString())
                $module = New-Module -Name $ModuleName -ScriptBlock $modulescriptblock

                # write the module to the filesystem if it does not exist and preferlocal is set
                if ($PreferLocal) {
                    if (-not (Test-Path -Path "$PSScriptRoot\Modules\$ModuleName")) {
                        $module | Out-File -FilePath $LocalModuleFolder
                    }
                }

            }
            catch {
                throw $_
            }
        }
        return $module
    }
}