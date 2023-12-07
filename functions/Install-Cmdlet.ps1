# help comment block below very detailed
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
        [string[]]$donovoicmdlets
    )
    begin {
        if ($donovoicmdlets) {
            $sburls = [System.Text.StringBuilder]::new()
            foreach ($cmdlet in $donovoicmdlets) {
                # build the array of urls for invoke-restmethod
                $sburls.AppendLine("https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/$cmdlet.ps1")
            }
            # clean up and remove any empty lines
            $urls = $sburls.ToString().Split("`n").Trim() | Where-Object { $_ }
        }

    }
    process {
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
                    $Cmdletsarraysb.AppendLine($(Invoke-RestMethod -Uri $link.ToString()))
                }
                catch {
                    throw $_
                }
            }
            $modulescriptblock = [scriptblock]::Create($Cmdletsarraysb.ToString())
            return . $modulescriptblock
        }
        catch {
            throw $_
        }
    }
}