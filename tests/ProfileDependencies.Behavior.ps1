#requires -Version 7.0
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath($TestRoot)
if (Test-Path -LiteralPath $root) { throw 'Use a new disposable TestRoot.' }
$null=[IO.Directory]::CreateDirectory($root)
$functions=Join-Path (Split-Path $PSScriptRoot -Parent) 'functions'
$checks=[Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name,[scriptblock]$Body) { & $Body; $checks.Add($Name); Write-Host "PASS $Name" }
Test-Case 'Dependency orchestration installs requested/default modules without implicit elevation' {
    . (Join-Path $functions 'Install-Dependencies.ps1')
    function Initialize-CmdletDependencies { [CmdletBinding()] param($RequiredCmdlets,[switch]$PreferLocal) }
    function Invoke-RunAsAdmin { throw 'Unexpected elevation.' }
    function Get-PackageProvider { [CmdletBinding()] param($Name) 'fixture provider' }
    function Update-SessionEnvironment { }
    $script:moduleRequest=$null
    function Install-PSModule {
        [CmdletBinding()] param($PSModule,$InstallDefaultPSModules,$LocalModulesDirectory,[switch]$RemoveAllLocalModules,[switch]$RemoveAllInMemoryModules)
        $script:moduleRequest=$PSBoundParameters
    }
    Install-Dependencies -PSModule 'ReviewFixtureModule' -NoNugetPackage
    Assert-True ($script:moduleRequest.PSModule -contains 'ReviewFixtureModule') 'Requested module was not installed.'
    Install-Dependencies -InstallDefaultPSModules -NoNugetPackage
    Assert-True $script:moduleRequest.InstallDefaultPSModules 'Default-only module request was dropped.'
    function Install-PSModule { [CmdletBinding()] param($PSModule,$InstallDefaultPSModules,$LocalModulesDirectory,[switch]$RemoveAllLocalModules,[switch]$RemoveAllInMemoryModules) throw 'Module installation fixture failure' }
    $caught=$false
    try { Install-Dependencies -PSModule 'ReviewFixtureModule' -NoNugetPackage } catch { $caught=$_.Exception.Message -eq 'Module installation fixture failure' }
    Assert-True $caught 'Failed installation was hidden from the caller.'
}
Test-Case 'PowerShell module installation uses CurrentUser, exports globally and propagates failures' {
    . (Join-Path $functions 'Install-PSModule.ps1')
    function Initialize-CmdletDependencies { [CmdletBinding()] param($RequiredCmdlets,[switch]$PreferLocal) }
    function Write-Logg { param($Message,$Level) }
    $script:installs=[Collections.Generic.List[string]]::new()
    $script:imports=[Collections.Generic.List[string]]::new()
    function Get-Module { [CmdletBinding()] param($Name,[switch]$ListAvailable) }
    function Install-Module {
        [CmdletBinding(SupportsShouldProcess)] param($Name,$Scope,[switch]$Force,[switch]$AllowClobber,[switch]$SkipPublisherCheck)
        Assert-True ($Scope -eq 'CurrentUser') 'Installation requested admin-level scope.'
        $script:installs.Add($Name)
    }
    function Import-Module {
        [CmdletBinding()] param($Name,[switch]$Force,[switch]$Global)
        Assert-True $Global 'Installed module was only imported in the helper scope.'
        $script:imports.Add($Name)
    }
    Install-PSModule -InstallDefaultPSModules $true -PSModule 'ReviewFixtureModule','PSReadLine' -LocalModulesDirectory $root
    Assert-True ($script:installs.Count -eq 2 -and 'PSReadLine' -in $script:installs -and 'ReviewFixtureModule' -in $script:installs -and $script:imports.Count -eq 2) 'Default and explicit modules were not installed once each.'
    function Install-Module { [CmdletBinding(SupportsShouldProcess)] param($Name,$Scope,[switch]$Force,[switch]$AllowClobber,[switch]$SkipPublisherCheck) throw 'Gallery unavailable fixture' }
    $caught=$false
    try { Install-PSModule -PSModule 'ReviewMissingModule' -LocalModulesDirectory $root } catch { $caught=$_.Exception.Message -eq 'Gallery unavailable fixture' }
    Assert-True $caught 'Gallery failure was hidden.'
}
Test-Case 'Default NuGet packages work without an explicit package table and respect overrides' {
    . (Join-Path $functions 'Install-NugetDeps.ps1')
    function Initialize-CmdletDependencies { [CmdletBinding()] param($RequiredCmdlets,[switch]$PreferLocal,[switch]$Force) }
    function Write-Logg { param($Message,$Level) }
    function Install-PackageProviders { }
    $script:packages=@{}
    function Add-NuGetDependencies {
        [CmdletBinding()] param($NugetPackage,[switch]$SaveLocally,$LocalNugetDirectory)
        foreach ($item in $NugetPackage.GetEnumerator()) { $script:packages[$item.Key]=$item.Value }
    }
    Install-NugetDeps -InstallDefaultNugetPackage
    Assert-True ($script:packages.Count -eq 4 -and $script:packages['HtmlAgilityPack'] -eq '1.12.0') 'Default-only NuGet request did not install defaults.'
    $script:packages.Clear()
    Install-NugetDeps -InstallDefaultNugetPackage -NugetPackage @{'HtmlAgilityPack'='1.11.46';'ReviewPackage'='1.0.0'}
    Assert-True ($script:packages.Count -eq 5 -and $script:packages['HtmlAgilityPack'] -eq '1.11.46') 'Explicit NuGet overrides were lost.'
}
Test-Case 'Corrected dependency call sites bind against the real parameter contract' {
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $functions 'Install-Dependencies.ps1'),[ref]$null,[ref]$null)
    $definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-Dependencies'},$true)
    # Keep the real parameter contract, replace all effects with a capture.
    $capture=[scriptblock]::Create($definition.Body.ParamBlock.Extent.Text+'; $script:boundDependencyParameters = $PSBoundParameters')
    Set-Item Function:Install-Dependencies -Value $capture
    foreach ($file in @('Get-GenerateddllFunc.ps1','Get-WSATranslation.ps1')) {
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $functions $file),[ref]$null,[ref]$null)
        foreach ($command in $ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Install-Dependencies'},$true)) {
            & ([scriptblock]::Create($command.Extent.Text))
            Assert-True $script:boundDependencyParameters.InstallDefaultNugetPackage 'Default NuGet switch did not bind.'
            if ($file -eq 'Get-GenerateddllFunc.ps1') {
                Assert-True ($script:boundDependencyParameters.NugetPackage -is [hashtable] -and $script:boundDependencyParameters.NugetPackage['Microsoft.Windows.CsWin32'] -eq '0.3.366') 'NuGet package table did not bind.'
            }
        }
    }
}
Test-Case 'Screen-recorder local dependency path is passed through' {
    . (Join-Path $functions 'Invoke-ScreenRecord.ps1')
    $script:recordingDependency=$null
    function Get-Command { [CmdletBinding()] param($Name) [pscustomobject]@{Name=$Name} }
    function Install-Dependencies { [CmdletBinding()] param($PSModule,$LocalModulesDirectory,[switch]$NoNugetPackage) $script:recordingDependency=$PSBoundParameters }
    Install-psScreenRecorder -LocalDependencies -LocalPath $root
    Assert-True ($script:recordingDependency.LocalModulesDirectory -eq (Join-Path $root 'Modules') -and $script:recordingDependency.PSModule -eq 'psScreenRecorder') 'Recorder ignored the local dependency directory.'
    $caught=$false
    try { Install-psScreenRecorder -LocalDependencies } catch { $caught=$_.Exception.Message -like 'LocalPath is required*' }
    Assert-True $caught 'Recorder accepted an incomplete local path request.'
}
Test-Case 'SYSTEM launcher honors the selected executable and disposes the token; forensic caller binds' {
    . (Join-Path $functions 'Get-SYSTEM.ps1')
    Add-Type -TypeDefinition @'
namespace NtCoreLib.Win32.Process {
    public class FixtureProcess { public int Id=123; public string ApplicationName; public string CommandLine; }
    public class Win32ProcessConfig {
        public string ApplicationName; public string CommandLine; public object Token;
        public FixtureProcess Create() { return new FixtureProcess { ApplicationName=ApplicationName, CommandLine=CommandLine }; }
    }
}
'@
    function Test-IsAdministrator { $true }
    function Get-Module { [CmdletBinding()] param($Name,[switch]$ListAvailable) 'fixture module' }
    function Import-Module { [CmdletBinding()] param($Name) }
    $script:tokenDisposed=$false
    function Get-NtToken {
        param($Service,[switch]$WithTcb)
        $token=[pscustomobject]@{}
        $token | Add-Member ScriptMethod Dispose { $script:tokenDisposed=$true } -PassThru
    }
    $result=Get-SYSTEM -PowerShellPath 'C:\Fixture Selected Host\chosen.exe' -PowerShellArgs '-NoProfile -Command fixture'
    Assert-True ($result.ApplicationName -eq 'C:\Fixture Selected Host\chosen.exe' -and $result.CommandLine -like '*-Command fixture' -and $script:tokenDisposed) 'SYSTEM launch ignored path/arguments or leaked token.'
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $functions 'Write-ForensicReport.ps1'),[ref]$null,[ref]$null)
    $command=$ast.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-SYSTEM'},$true)
    $powershellPath='C:\Fixture Selected Host\chosen.exe'
    $systemArgs='-NoProfile -Command fixture'
    $result=& ([scriptblock]::Create($command.Extent.Text))
    Assert-True ($result.ApplicationName -eq $powershellPath) 'Forensic caller failed to bind Get-SYSTEM parameters.'
}
Test-Case 'Every repaired bootstrap URL points at an existing tracked function source' {
    $urls=@()
    foreach ($file in Get-ChildItem -LiteralPath $functions -Filter '*.ps1') {
        $text=[IO.File]::ReadAllText($file.FullName)
        Assert-True (-not $text.Contains('/functions/cmdlets/Initialize-CmdletDependencies.ps1')) "Stale bootstrap URL in $($file.Name)."
        if ($text.Contains('/functions/Initialize-CmdletDependencies.ps1')) { $urls += $file.Name }
    }
    Assert-True ($urls.Count -ge 12 -and (Test-Path (Join-Path $functions 'Initialize-CmdletDependencies.ps1'))) 'Canonical bootstrap source is missing.'
}
[pscustomobject]@{Passed=$checks.Count;Checks=$checks;TestRoot=$root} | ConvertTo-Json -Depth 4
