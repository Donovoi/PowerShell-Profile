<#
.SYNOPSIS
Installs cmdlets from URLs or locally.

.DESCRIPTION
The Install-Cmdlet function installs cmdlets either from URLs or locally. It supports downloading cmdlets from URLs and saving them to a local module folder, as well as importing existing local cmdlets. The function can be used to install multiple cmdlets at once.

.PARAMETER Urls
Specifies the URLs of the cmdlets to download. This parameter is mandatory when using the 'Url' parameter set.

.PARAMETER CmdletToInstall
Specifies the names of the cmdlets to install. By default, all cmdlets in the URLs will be installed. This parameter is optional when using the 'Url' parameter set.

.PARAMETER ModuleName
Specifies the name of the in-memory module to create when installing cmdlets from URLs. The default value is 'InMemoryModule'. This parameter is optional.

.PARAMETER Donovoicmdlets
Specifies the names of the cmdlets to install from the local module folder. This parameter is mandatory when using the 'Donovoicmdlets' parameter set.

.PARAMETER PreferLocal
Indicates whether to prefer locally installed cmdlets over downloading from URLs. If set to $true, the function will import existing local cmdlets instead of downloading them. This parameter is optional.

.PARAMETER LocalModuleFolder
Specifies the path to the local module folder where cmdlets will be saved. The default value is "$PSScriptRoot\PowerShellScriptsAndResources\Modules\cmdletCollection\". This parameter is optional.

.OUTPUTS
System.Management.Automation.PSModuleInfo or System.IO.FileInfo
Returns the imported in-memory module or the path to the local module file.

.EXAMPLE
Install-Cmdlet -Urls 'https://example.com/MyCmdlet.ps1' -CmdletToInstall 'MyCmdlet' -ModuleName 'MyModule'

This example downloads the 'MyCmdlet' from the specified URL and saves it as an in-memory module named 'MyModule'.

.EXAMPLE
Install-Cmdlet -Donovoicmdlets 'MyCmdlet' -PreferLocal

This example imports the 'MyCmdlet' from the local module folder if it exists, otherwise it displays a warning message.

#>
function Install-Cmdlet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Url')]
        [string[]]$url,
        [Parameter(Mandatory = $false, ParameterSetName = 'Url')]
        [string[]]$CmdletToInstall = '*',
        [Parameter(Mandatory = $false)]
        [string]$ModuleName = 'InMemoryModule',
        [Parameter(Mandatory = $true, ParameterSetName = 'Donovoicmdlets')]
        [string[]]$donovoicmdlets,
        [Parameter(Mandatory = $false, ParameterSetName = 'Donovoicmdlets')]
        [switch]$PreferLocal,
        [Parameter(Mandatory = $false)]
        [string]$LocalModuleFolder = "$PSScriptRoot\PowerShellScriptsAndResources\Modules\cmdletCollection\",
        [Parameter(Mandatory = $false)]
        [switch]$ContainsClass
    )
    try {

        $cmdletsToDownload = @()
        if ($donovoicmdlets -and $PreferLocal) {
            # make sure local modules folder exists
            if (-not (Test-Path -Path $LocalModuleFolder)) {
                New-Item -Path $LocalModuleFolder -ItemType Directory -Force
            }

            # create local module file that imports the cmdlet by glob search file path so we add all at once
            $modulefile = [System.IO.Path]::Combine($LocalModuleFolder, 'cmdletCollection.psm1')
            # if the module file does not exist, create it, otherwise overwrite the first line with "Import-module -Name .\*.ps1 -Force"
            if (-not (Test-Path -Path $modulefile)) {
                New-Item -Path $modulefile -ItemType File -Force
            }
            $modulecontent = @'
            $ActualScriptName = Get-PSCallStack | Select-Object -First 1 -ExpandProperty ScriptName
            $ScriptParentPath = Split-Path -Path $(Resolve-Path -Path $($ActualScriptName.foreach{ $_ }) ) -Parent
            Get-ChildItem -Path $ScriptParentPath | ForEach-Object {
                . $_.FullName
            }
            Export-ModuleMember -Function * -Alias *
'@
            Set-Content -Path $modulefile -Value $modulecontent -Force

            foreach ($cmdlet in $donovoicmdlets) {
                if (-not (Test-Path -Path "$LocalModuleFolder\$cmdlet.ps1")) {
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
        }
        if (-not $(Get-Variable -Name 'Url' -ErrorAction SilentlyContinue) -or ([string]::IsNullOrEmpty($url))) {
            $Urls = @()
        }
        if ($donovoicmdlets -and ( (-not $PreferLocal) -or ($cmdletsToDownload.Count -gt 0) )) {
            $sburls = [System.Text.StringBuilder]::new()
            foreach ($cmdlet in $donovoicmdlets) {
                # build the array of urls for invoke-restmethod
                $sburls.AppendLine("https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/$cmdlet.ps1") | Out-Null
            }
            # clean up and remove any empty lines
            $urls += $sburls.ToString().Split("`n").Trim() | Where-Object { $_ }

            # validate the urls especially if the user has provided a custom url, and then process the urls
            $Cmdletsarraysb = [System.Text.StringBuilder]::new()
            # $urls should not be empty
            if ([string]::IsNullOrEmpty($urls)) {
                throw [System.ArgumentException]::new('Nothing To Download, Exiting...')
            }
            else {
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
                        # if preferlocal and cmdletstodownload is set then download the cmdlet as per the path
                        # no need to keep it in memory as one script block, we will create and import all local cmdlets individually
                        if ($PreferLocal -and $cmdletsToDownload -gt 0) {
                            $cmdlet = $link.Split('/')[-1].Split('.')[0]
                            $module = Invoke-RestMethod -Uri $link.ToString()
                            Write-Information -MessageData "Downloading $cmdlet now..."
                            $module | Out-File -FilePath "$LocalModuleFolder\$cmdlet.ps1" -Force
                            Write-Information -MessageData "The cmdlet $cmdlet was downloaded and saved to $LocalModuleFolder"
                        }
                        else {
                            # Just download and import the cmdlet all in memory
                            $Cmdletsarraysb.AppendLine($(Invoke-RestMethod -Uri $link.ToString())) | Out-Null
                        }
                    }
                    catch {
                        Write-Error -Message "Failed to download the cmdlet from $link"
                        Write-Error -Message 'Make sure the casing is correct'
                        throw $_
                    }
                }
            }
        }
        if (-not $PreferLocal) {
            #  do the rest of the needed in memory stuff
            $modulescriptblock = [scriptblock]::Create($Cmdletsarraysb.ToString())
            $module = New-Module -Name $ModuleName -ScriptBlock $modulescriptblock
        }
        else {
            # import all local cmdlets
            Import-Module -Name $moduleFile -Force
            Write-Information -MessageData "The cmdlets $donovoicmdlets were imported"
        }
        return $module ? $module : $modulefile

    }
    catch {
        Write-Error -Message 'Failed to install the cmdlets'
        throw $_
    }
}