<#
.SYNOPSIS
    Download/import one or more PowerShell cmdlets – from a URL or a
    local cache – with preview-safe manifest handling.

.DESCRIPTION
    • URL mode:  fetch each .ps1 file, optionally cache on disk, then
      create an *in-memory* module that you can unload at will.
    • Repository mode: same idea but you pass bare cmdlet names and the
      function builds GitHub raw URLs for you.
    • Prefer-local: always check (or save to) the cache folder first.
#>

function Install-Cmdlet {

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium',
        DefaultParameterSetName = 'Repository')]
    [OutputType([System.Management.Automation.PSModuleInfo],   # when -PreferLocal:$false
        [System.IO.FileInfo])]                         # when -PreferLocal
    param(
        # ------- PARAMETER-SET: Url -----------------------------------------
        [Parameter(Mandatory, ParameterSetName = 'Url', Position = 0)]
        [Alias('Url', 'Uri')]
        [string[]]$Urls,

        [Parameter(ParameterSetName = 'Url', Position = 1)]
        [Alias('Cmdlet', 'CmdletToInstall')]
        [string[]]$CmdletNames = '*',

        [Parameter(ParameterSetName = 'Url', Position = 2)]
        [string]$ModuleName = 'InMemoryModule',

        # ------- PARAMETER-SET: Repository ----------------------------------
        [Parameter(Mandatory, ParameterSetName = 'Repository',
            ValueFromPipeline = $true,
            ValueFromPipelineByPropertyName = $true)]
        [Alias('CmdletName')]
        [string[]]$RepositoryCmdlets,

        # ------- Common switches / settings ---------------------------------
        [switch]$PreferLocal,
        [string]$LocalModuleFolder =
        "$ENV:USERPROFILE\PowerShellScriptsAndResources\Modules\cmdletCollection\",
        [switch]$Force,
        [ValidateRange(5, 300)][int]$TimeoutSeconds = 30,
        [switch]$RequireHttps,
        [string]$GitHubRepositoryUrl =
        'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/'
    )

    # ---------------------------------------------------------------------- #
    #  BEGIN – runs once; holds helper functions and one-time prep           #
    # ---------------------------------------------------------------------- #
    begin {

        # -- Helper: validate URL format + enforce https (optional) ----------
        function Test-ValidUrl {
            param([string]$Url, [switch]$RequireHttps)
            $re = '^(https?):\/\/[-\w+&@#/%?=~_|!:,.;]+[-\w+&@#/%=~_|]$'
            if ($Url -notmatch $re) {
                return $false
            }
            if ($RequireHttps -and -not $Url.StartsWith('https://')) {
                return $false
            }
            return $true
        }

        # -- Helper: strip BOM / zero-width chars; quick AST check -----------
        function Get-CleanScriptContent {
            param([string]$Content)
            $clean = $Content -replace ([char]0xFEFF), ''
            -replace ([char]0x200B), ''
            try {
                [System.Management.Automation.Language.Parser]::ParseInput(
                    $clean, [ref]$null, [ref]$null) | Out-Null
            }
            catch {
                Write-Verbose 'Code parsed with non-fatal errors.'
            }
            return $clean
        }

        # -- Helper: create cache folder and preview-safe manifest -----------
        function Initialize-LocalModuleEnvironment {
            param([string]$Folder)

            if (-not (Test-Path $Folder)) {
                New-Item -Path $Folder -ItemType Directory -Force | Out-Null
            }

            # Autoloader .psm1
            $psm1 = Join-Path $Folder 'cmdletCollection.psm1'
            if (-not (Test-Path $psm1)) {
                @'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem $here -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Export-ModuleMember -Function * -Alias *
'@ | Set-Content $psm1 -Encoding UTF8
            }

            # Manifest .psd1 (only once)
            $psd1 = Join-Path $Folder 'cmdletCollection.psd1'
            if (-not (Test-Path $psd1)) {
                $vObj = $PSVersionTable.PSVersion
                $numeric = '{0}.{1}.{2}' -f $vObj.Major, $vObj.Minor, $vObj.Build
                if ([version]::TryParse($numeric, [ref]([version]::new()))) {
                    New-ModuleManifest -Path $psd1 `
                        -RootModule 'cmdletCollection.psm1' `
                        -ModuleVersion '1.0.0' `
                        -Author 'Auto-generated' `
                        -Description 'Cached cmdlet collection' `
                        -PowerShellVersion $numeric
                }
                else {
                    # Fallback: omit key if somehow unparsable
                    New-ModuleManifest -Path $psd1 `
                        -RootModule 'cmdletCollection.psm1' `
                        -ModuleVersion '1.0.0' `
                        -Author 'Auto-generated' `
                        -Description 'Cached cmdlet collection'
                }
            }

            return (Get-Item $psm1)
        }

        # -- Helper: save script to cache, ensuring UTF-8 w/o BOM ------------
        function Save-CmdletToLocalFolder {
            param(
                [string]$Code,
                [string]$Name,
                [string]$Folder
            )
            $path = Join-Path $Folder "$Name.ps1"
            $clean = Get-CleanScriptContent $Code
            [IO.File]::WriteAllText($path, $clean)   # BOM-less UTF-8 by default
            return $path
        }

        # One-time init objects for this invocation
        $needsDownload = [System.Collections.Generic.List[string]]::new()
        $sbInMemory = [System.Text.StringBuilder]::new()
        $importResult = $null

        # Prepare cache folder early if we *might* use it
        if ($PreferLocal -or $PSCmdlet.ParameterSetName -eq 'Repository') {
            $psm1File = Initialize-LocalModuleEnvironment $LocalModuleFolder
        }
    } # end begin

    # ---------------------------------------------------------------------- #
    #  PROCESS – invoked once per pipeline input (or once if none)          #
    # ---------------------------------------------------------------------- #
    process {

        # Respect -WhatIf/-Confirm globally
        return unless $PSCmdlet.ShouldProcess(
            'Input data', 'Install cmdlet(s)')

        switch ($PSCmdlet.ParameterSetName) {

            # ----- REPOSITORY MODE -----------------------------------------
            'Repository' {

                foreach ($name in $RepositoryCmdlets) {

                    $local = Join-Path $LocalModuleFolder "$name.ps1"
                    $exists = Test-Path $local

                    if (!$exists -or $Force) {
                        $needsDownload.Add($name)
                    }
                    elseif ($PreferLocal) {
                        Import-Module $local -Force
                    }
                }

                foreach ($item in $needsDownload) {
                    $url = "$GitHubRepositoryUrl$item.ps1"
                    if (-not (Test-ValidUrl $url -RequireHttps:$RequireHttps)) {
                        Write-Warning "Bad URL skipped: $url"; continue
                    }

                    $code = Invoke-RestMethod $url -TimeoutSec $TimeoutSeconds
                    $clean = Get-CleanScriptContent $code

                    if ($PreferLocal) {
                        Save-CmdletToLocalFolder $clean $item $LocalModuleFolder | Out-Null
                    }
                    else {
                        $null = $sbInMemory.AppendLine($clean)
                    }
                }
            }

            # ----- URL MODE ------------------------------------------------
            'Url' {
                foreach ($u in $Urls) {

                    if (-not (Test-ValidUrl $u -RequireHttps:$RequireHttps)) {
                        Write-Warning "Bad URL skipped: $u"; continue
                    }

                    $name = ($u.Split('/')[-1]).Split('.')[0]
                    $code = Invoke-RestMethod $u -TimeoutSec $TimeoutSeconds
                    $clean = Get-CleanScriptContent $code

                    if ($PreferLocal) {
                        Save-CmdletToLocalFolder $clean $name $LocalModuleFolder | Out-Null
                    }
                    else {
                        $null = $sbInMemory.AppendLine($clean)
                    }
                }
            }
        }

        # Build a dynamic module if we have memory-only code
        if (($sbInMemory.Length -gt 0) -and (-not $PreferLocal)) {
            $modSB = [scriptblock]::Create($sbInMemory.ToString())
            $importResult = New-Module -Name $ModuleName -ScriptBlock $modSB |
                Import-Module -Force -Global -PassThru
        }
        # Or re-import the cache loader if we just wrote new scripts
        elseif ($PreferLocal -and $needsDownload.Count -gt 0) {
            $importResult = Import-Module $psm1File.FullName -Force -Global -PassThru
        }
    } # end process

    # ---------------------------------------------------------------------- #
    #  END – final clean-up & return value                                   #
    # ---------------------------------------------------------------------- #
    end {
        if ($PreferLocal) {
            # return list of *.ps1 we actually have on disk
            $paths = Get-ChildItem $LocalModuleFolder -Filter '*.ps1' |
                Select-Object -ExpandProperty FullName
            return $paths
        }
        else {
            return $importResult
        }
    }
}
