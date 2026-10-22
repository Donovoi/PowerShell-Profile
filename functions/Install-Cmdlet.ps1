function Install-Cmdlet {
    <#
    .SYNOPSIS
    Downloads and imports PowerShell commands, optionally using a persistent cache.
    .DESCRIPTION
    Commands are imported into global scope. A warm cache is imported without a
    download. Force refreshes cached scripts only after successful download and
    syntax validation; a failed refresh leaves the previous cache file intact.
    Use trusted sources: importing a script executes its top-level statements.
    .OUTPUTS
    System.String with PreferLocal (cached script paths); otherwise PSModuleInfo.
    .EXAMPLE
    Install-Cmdlet -RepositoryCmdlets Format-Bytes -PreferLocal
    .EXAMPLE
    'Format-Bytes', 'Test-InPath' | Install-Cmdlet
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Repository')]
    [OutputType([string], [System.Management.Automation.PSModuleInfo])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Url', Position = 0)]
        [Alias('Url', 'Uri')] [ValidateNotNullOrEmpty()] [string[]]$Urls,
        [Parameter(ParameterSetName = 'Url', Position = 2)]
        [ValidatePattern('^[A-Za-z][\w-]*$')] [string]$ModuleName = 'InMemoryModule',
        [Parameter(Mandatory, ParameterSetName = 'Repository', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('CmdletName')] [ValidateNotNullOrEmpty()] [string[]]$RepositoryCmdlets,
        [switch]$PreferLocal,
        [ValidateNotNullOrEmpty()]
        [string]$LocalModuleFolder = "$env:USERPROFILE\PowerShellScriptsAndResources\Modules\cmdletCollection",
        [switch]$Force,
        [ValidateRange(5, 300)] [int]$TimeoutSeconds = 30,
        [switch]$RequireHttps,
        [ValidateNotNullOrEmpty()]
        [string]$GitHubRepositoryUrl = 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions/'
    )
    begin {
        $scripts = [Collections.Generic.List[string]]::new()
        $paths = [Collections.Generic.List[string]]::new()
        $expectedCommands = [Collections.Generic.List[string]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        function Assert-CmdletUri {
            param([string]$Address, [bool]$HttpsOnly)
            $uri = $null
            if (-not [uri]::TryCreate($Address, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -notin @('http', 'https') -or ($HttpsOnly -and $uri.Scheme -ne 'https')) {
                throw "Invalid script URL '$Address'. An absolute HTTP(S) URL is required."
            }
            return $uri
        }
        function Assert-CmdletContent {
            param([string]$Code, [string]$Source)
            if ([string]::IsNullOrWhiteSpace($Code)) { throw "Empty script from '$Source'." }
            # Strip only the leading BOM; never rewrite characters inside code.
            $clean = $Code.TrimStart([char]0xFEFF)
            $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($clean, [ref]$null, [ref]$parseErrors)
            if ($parseErrors.Count) { throw "Invalid script from '$Source': $($parseErrors -join '; ')" }
            return $clean
        }
        if ($PreferLocal -and -not [IO.Path]::IsPathFullyQualified($LocalModuleFolder)) {
            throw 'LocalModuleFolder must be an absolute filesystem path.'
        }
        $null = Assert-CmdletUri $GitHubRepositoryUrl -HttpsOnly $RequireHttps
    }
    process {
        $items = if ($PSCmdlet.ParameterSetName -eq 'Repository') {
            foreach ($name in $RepositoryCmdlets) {
                if ($name -notmatch '^[A-Za-z][\w-]*$') { throw "Invalid command name '$name'." }
                [pscustomobject]@{ Name = $name; Uri = $GitHubRepositoryUrl.TrimEnd('/') + "/$name.ps1"; Expected = $name }
            }
        }
        else {
            foreach ($address in $Urls) {
                $uri = Assert-CmdletUri $address -HttpsOnly $RequireHttps
                $name = [IO.Path]::GetFileNameWithoutExtension($uri.AbsolutePath)
                if ($name -notmatch '^[A-Za-z][\w-]*$') { throw "URL has no safe script filename: '$address'." }
                [pscustomobject]@{ Name = $name; Uri = $address; Expected = $null }
            }
        }
        foreach ($item in $items) {
            $null = Assert-CmdletUri $item.Uri -HttpsOnly $RequireHttps
            if (-not $seen.Add($item.Name)) { continue }
            if (-not $PSCmdlet.ShouldProcess($item.Uri, 'Install and import command')) { continue }
            $localPath = if ($PreferLocal) { Join-Path $LocalModuleFolder ($item.Name + '.ps1') }
            if ($PreferLocal -and -not $Force -and (Test-Path -LiteralPath $localPath -PathType Leaf)) {
                $null = Assert-CmdletContent -Code ([IO.File]::ReadAllText($localPath)) -Source $localPath
            }
            else {
                $code = Invoke-RestMethod -Uri $item.Uri -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                $code = Assert-CmdletContent -Code $code -Source $item.Uri
                if ($PreferLocal) {
                    $null = [IO.Directory]::CreateDirectory($LocalModuleFolder)
                    $temporaryPath = $localPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
                    try {
                        [IO.File]::WriteAllText($temporaryPath, $code, [Text.UTF8Encoding]::new($false))
                        [IO.File]::Move($temporaryPath, $localPath, $true)
                    }
                    finally { if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) } }
                }
                else { $scripts.Add($code) }
            }
            if ($PreferLocal) { $paths.Add($localPath) }
            if ($item.Expected) { $expectedCommands.Add($item.Expected) }
        }
    }
    end {
        if (-not $paths.Count -and -not $scripts.Count) { return }
        if ($PreferLocal) {
            # Import requested cache files, not every unrelated file in the cache.
            # Dot-sourcing physical files preserves PSScriptRoot for helper lookup.
            $imported = New-Module -Name ('ProfileCmdlets_' + [guid]::NewGuid().ToString('N')) -ArgumentList (,$paths.ToArray()) -ScriptBlock {
                param([string[]]$SourcePaths)
                foreach ($sourcePath in $SourcePaths) { . $sourcePath }
                Export-ModuleMember -Function * -Alias *
            } | Import-Module -Global -PassThru -ErrorAction Stop
        }
        else {
            $imported = New-Module -Name $ModuleName -ScriptBlock ([scriptblock]::Create($scripts -join [Environment]::NewLine)) |
                Import-Module -Global -Force -PassThru -ErrorAction Stop
        }
        foreach ($name in $expectedCommands) {
            if (-not $imported.ExportedCommands.ContainsKey($name)) {
                throw "Downloaded source did not export the requested command '$name'."
            }
        }
        if ($PreferLocal) { $paths.ToArray() }
        else { $imported }
    }
}
