function Initialize-CmdletDependencies {
    <#
    .SYNOPSIS
    Makes requested commands available to the caller, installing missing commands.
    .DESCRIPTION
    Existing commands are reused unless Force is specified. PreferLocal first uses
    an adjacent source file, then the persistent Install-Cmdlet cache. Imports are
    explicitly global so commands remain available after this function returns.
    Failures terminate instead of reporting a dependency as successfully loaded.
    .PARAMETER NoLocalFallback
    Bypasses local source files and the persistent cache.
    .PARAMETER LocalModuleFolder
    Optional cache override, passed to Install-Cmdlet.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()] [string[]]$RequiredCmdlets,
        [ValidateRange(1, 100)] [int]$MaxRetries = 3,
        [ValidateRange(0, 60)] [int]$RetryDelaySeconds = 5,
        [ValidateNotNullOrEmpty()] [string]$RepositoryUrl = 'https://raw.githubusercontent.com/Donovoi/PowerShell-Profile/main/functions',
        [ValidateRange(5, 300)] [int]$TimeoutSeconds = 30,
        [switch]$PreferLocal,
        [switch]$Force,
        [switch]$NoLocalFallback,
        [string]$LocalModuleFolder
    )
    begin {
        function Invoke-DependencyRetry {
            param([scriptblock]$Action, [int]$MaxAttempts, [int]$DelaySeconds)
            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                try { return (& $Action) }
                catch {
                    if ($attempt -eq $MaxAttempts) { throw }
                    Write-Verbose "Dependency attempt $attempt failed: $($_.Exception.Message)"
                    Start-Sleep -Seconds $DelaySeconds
                }
            }
        }
        function Import-DependencySource {
            param([string]$Name, [string]$Path, [string]$Content)
            if ($Path) {
                $errorsFound = $null
                $null = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errorsFound)
                if ($errorsFound.Count) { throw "Invalid dependency '$Path': $($errorsFound -join '; ')" }
                $module = New-Module -Name "ProfileDependency_$Name" -ArgumentList $Path -ScriptBlock {
                    param($SourcePath)
                    . $SourcePath
                    Export-ModuleMember -Function * -Alias *
                }
            }
            else {
                if ([string]::IsNullOrWhiteSpace($Content)) { throw "Dependency '$Name' was empty." }
                $module = New-Module -Name "ProfileDependency_$Name" -ScriptBlock ([scriptblock]::Create($Content))
            }
            if (-not $module.ExportedCommands.ContainsKey($Name)) {
                throw "Dependency source did not export '$Name'."
            }
            $module | Import-Module -Global -Force -ErrorAction Stop
        }
        function Find-DependencySource {
            param([string]$Name)
            $directories = @($PSScriptRoot)
            foreach ($frame in (Get-PSCallStack | Where-Object ScriptName)) {
                $callerDirectory = Split-Path -Parent $frame.ScriptName
                $directories += $callerDirectory
                $directories += Join-Path $callerDirectory 'Cmdlets'
            }
            foreach ($directory in ($directories | Where-Object { $_ } | Select-Object -Unique)) {
                $candidate = Join-Path $directory "$Name.ps1"
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }
        $repository = $null
        if (-not [uri]::TryCreate($RepositoryUrl, [UriKind]::Absolute, [ref]$repository) -or $repository.Scheme -notin @('http', 'https')) {
            throw 'RepositoryUrl must be an absolute HTTP or HTTPS URL.'
        }
    }
    process {
        foreach ($name in $RequiredCmdlets) {
            if ($name -notmatch '^[A-Za-z][\w-]*$') { throw "Invalid command name '$name'." }
            if (-not $Force -and (Get-Command -Name $name -ErrorAction Ignore)) { continue }
            if (-not $PSCmdlet.ShouldProcess($name, 'Load or install dependency')) { continue }

            $source = if ($PreferLocal -and -not $NoLocalFallback) { Find-DependencySource $name }
            if ($source) {
                Import-DependencySource -Name $name -Path $source
                continue
            }
            if (-not (Get-Command Install-Cmdlet -ErrorAction Ignore)) {
                $installerSource = if (-not $NoLocalFallback) { Find-DependencySource 'Install-Cmdlet' }
                if ($installerSource) {
                    Import-DependencySource -Name 'Install-Cmdlet' -Path $installerSource
                }
                else {
                    $installerCode = Invoke-DependencyRetry -MaxAttempts $MaxRetries -DelaySeconds $RetryDelaySeconds -Action {
                        Invoke-RestMethod -Uri ($RepositoryUrl.TrimEnd('/') + '/Install-Cmdlet.ps1') -TimeoutSec $TimeoutSeconds -ErrorAction Stop
                    }
                    Import-DependencySource -Name 'Install-Cmdlet' -Content $installerCode
                }
            }
            $installParameters = @{
                RepositoryCmdlets = $name
                GitHubRepositoryUrl = $RepositoryUrl
                TimeoutSeconds = $TimeoutSeconds
                PreferLocal = ($PreferLocal -and -not $NoLocalFallback)
                Force = $Force
                ErrorAction = 'Stop'
                Confirm = $false
            }
            if ($LocalModuleFolder) { $installParameters.LocalModuleFolder = $LocalModuleFolder }
            $null = Invoke-DependencyRetry -MaxAttempts $MaxRetries -DelaySeconds $RetryDelaySeconds -Action { Install-Cmdlet @installParameters }
            if (-not (Get-Command -Name $name -ErrorAction Ignore)) {
                throw "Installation completed without making '$name' available."
            }
        }
    }
}
