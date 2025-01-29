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
        # Collect any cmdlets that need downloading if using -PreferLocal
        $cmdletsToDownload = @()

        if ($donovoicmdlets -and $PreferLocal) {
            # Ensure local modules folder exists
            if (-not (Test-Path -Path $LocalModuleFolder)) {
                New-Item -Path $LocalModuleFolder -ItemType Directory -Force | Out-Null
            }

            # Create or overwrite a local .psm1 file that imports all .ps1 files in the folder
            $modulefile = Join-Path $LocalModuleFolder 'cmdletCollection.psm1'
            if (-not (Test-Path -Path $modulefile)) {
                New-Item -Path $modulefile -ItemType File -Force | Out-Null
            }
            $modulecontent = @'
$ActualScriptName = Get-PSCallStack | Select-Object -First 1 -ExpandProperty ScriptName
$ScriptParentPath = Split-Path -Path (Resolve-Path -Path $ActualScriptName) -Parent
Get-ChildItem -Path $ScriptParentPath -Filter *.ps1 | ForEach-Object {
    . $_.FullName
}
Export-ModuleMember -Function * -Alias *
'@
            Set-Content -Path $modulefile -Value $modulecontent -Force

            foreach ($cmdlet in $donovoicmdlets) {
                if (-not (Test-Path -Path (Join-Path $LocalModuleFolder "$cmdlet.ps1"))) {
                    Write-Warning -Message "The cmdlet $cmdlet was not found locally."
                    Write-Information -MessageData "Downloading $cmdlet now..."
                    Write-Information -MessageData "All cmdlets will be downloaded to $LocalModuleFolder"
                    $cmdletsToDownload += $cmdlet
                }
                else {
                    # If found locally, just import it directly
                    Import-Module (Join-Path $LocalModuleFolder "$cmdlet.ps1") -Force
                    Write-Information -MessageData "The cmdlet $cmdlet was found locally and imported."
                }
            }
        }

        # Convert $url to an array if it doesn't exist or is empty
        if (-not $(Get-Variable -Name 'url' -ErrorAction SilentlyContinue) -or ([string]::IsNullOrEmpty($url))) {
            $Urls = @()
        }

        # If user specified donovoicmdlets & either doesn't prefer local OR some cmdlets were missing and need to be downloaded
        if (
            $donovoicmdlets -and (
                (-not $PreferLocal) -or
                ($cmdletsToDownload.Count -gt 0)
            )
        ) {
            $sburls = [System.Text.StringBuilder]::new()
            foreach ($cmdlet in $donovoicmdlets) {
                $sburls.AppendLine("https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/$cmdlet.ps1") | Out-Null
            }

            # Collect all URLs (cleanup any empty lines)
            $urls += $sburls.ToString().Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }

            if ([string]::IsNullOrEmpty($urls)) {
                throw [System.ArgumentException]::new('Nothing to download, exiting...')
            }
            else {
                # Prepare a StringBuilder for the combined script content
                $Cmdletsarraysb = [System.Text.StringBuilder]::new()
                foreach ($link in $urls) {
                    # Validate the URL
                    $searchpattern = "((ht|f)tp(s?)\:\/\/?)[0-9a-zA-Z]([-.\w]*[0-9a-zA-Z])*(:(0-9)*)*(\/?)([a-zA-Z0-9\-\.\?\,\'\/\\\+&%\$#_]*)?"
                    $regexoptions = [System.Text.RegularExpressions.RegexOptions]('IgnoreCase, IgnorePatternWhitespace, Compiled')
                    $compiledregex = [regex]::new($searchpattern, $regexoptions)
                    if (-not ($link -match $compiledregex)) {
                        throw [System.ArgumentException]::new("The given URL is not valid: $link")
                    }

                    try {
                        # If we prefer local AND we have cmdlets to download, write them to disk BOM-less
                        if ($PreferLocal -and $cmdletsToDownload.Count -gt 0) {
                            $cmdlet = ($link.Split('/')[-1]).Split('.')[0]
                            Write-Information -MessageData "Downloading $cmdlet now..."

                            $moduleContentRaw = Invoke-RestMethod -Uri $link
                            # Remove BOM or zero-width chars
                            $moduleContentClean = $moduleContentRaw `
                                -replace ([char]0xFEFF), '' `
                                -replace ([char]0x200B), ''

                            # Out-File adds a BOM in Windows PowerShell 5.1, so we do a two-step approach:
                            $tempFile = Join-Path $LocalModuleFolder "$cmdlet.ps1"
                            $moduleContentClean | Out-File -FilePath $tempFile -Force -Encoding UTF8
                            # Now strip any BOM that may have been reintroduced:
                            (Get-Content $tempFile -Raw) `
                                -replace ([char]0xFEFF), '' `
                                -replace ([char]0x200B), '' |
                                Set-Content -Encoding UTF8 -Force $tempFile

                            Write-Information -MessageData "The cmdlet $cmdlet was downloaded and saved to $LocalModuleFolder"
                        }
                        else {
                            # In-memory approach
                            $responseRaw = Invoke-RestMethod -Uri $link

                            # Explicitly remove BOM / zero-width chars
                            $responseClean = $responseRaw `
                                -replace ([char]0xFEFF), '' `
                                -replace ([char]0x200B), ''

                            # Append to our combined scripts
                            $Cmdletsarraysb.AppendLine($responseClean) | Out-Null
                        }
                    }
                    catch {
                        Write-Error -Message "Failed to download the cmdlet from $link"
                        Write-Error -Message 'Make sure the casing is correct'
                        throw $_
                    }
                }

                if (-not $PreferLocal) {
                    # Create an in-memory module from the combined scripts, stripping BOM again
                    $combinedScript = $Cmdletsarraysb.ToString() `
                        -replace ([char]0xFEFF), '' `
                        -replace ([char]0x200B), ''

                    $modulescriptblock = [scriptblock]::Create($combinedScript)
                    $module = New-Module -Name $ModuleName -ScriptBlock $modulescriptblock
                }
            }
        }

        if ($PreferLocal) {
            # Import all local cmdlets via the .psm1 file
            $modulefile = Join-Path $LocalModuleFolder 'cmdletCollection.psm1'
            Import-Module -Name $modulefile -Force
            Write-Information -MessageData "Local cmdlets $donovoicmdlets were imported from $modulefile"
        }

        return $module ? $module : $modulefile
    }
    catch {
        Write-Error -Message 'Failed to install the cmdlets'
        throw $_
    }
}