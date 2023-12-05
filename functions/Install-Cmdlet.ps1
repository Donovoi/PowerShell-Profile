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
        [Parameter(Mandatory = $true)]
        [string]
        $Url,
        [Parameter(Mandatory = $false)]
        [string]
        $CmdletToInstall = '*',
        [Parameter(Mandatory = $false)]
        [string]
        $ModuleName = {
            # We will generate a random name for the module using terms stored in memory from powershell
            # Make sure randomname is empty
            $randomName = ''
            $wordlist = 'https://raw.githubusercontent.com/sts10/generated-wordlists/main/lists/experimental/ud1.txt'
            $wordlist = Invoke-RestMethod -Uri $wordlist
            $wordarray = $($wordlist).ToString().Split("`n")
            $randomNumber = (Get-Random -Minimum 0 -Maximum $wordarray.Length)
            $randomName = $wordarray[$randomNumber]
            $randomName.Insert(0, 'Module-') 
        }
    )

    begin {
        # make sure we are given a valid url
        $searchpattern = "((ht|f)tp(s?)\:\/\/?)[0-9a-zA-Z]([-.\w]*[0-9a-zA-Z])*(:(0-9)*)*(\/?)([a-zA-Z0-9\-\.\?\,\'\/\\\+&%\$#_]*)?"
        $regexoptions = [System.Text.RegularExpressions.RegexOptions]('IgnoreCase, IgnorePatternWhitespace, Compiled')
        $compiledregex = [regex]::new($searchpattern, $regexoptions)
        if (-not($url -match $compiledregex)) {
            throw [System.ArgumentException]::new('The given url is not valid')
        }
    }
    process {
        try {
            $method = Invoke-RestMethod -Uri $Url
            $CmdletScriptBlock = [scriptblock]::Create($method.ToString() + "`nExport-ModuleMember -Function * -Alias *")
            New-Module -Name $ModuleName -ScriptBlock $CmdletScriptBlock | Import-Module -Cmdlet $CmdletToInstall
        }
        catch {
            throw $_
        }
    }
    end {
    }
}