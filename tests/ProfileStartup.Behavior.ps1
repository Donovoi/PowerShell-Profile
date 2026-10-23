#requires -Version 7.0
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($TestRoot)
if (Test-Path -LiteralPath $root) { throw 'Use a new disposable TestRoot.' }
$null = [IO.Directory]::CreateDirectory($root)
$repo = Split-Path $PSScriptRoot -Parent
$functions = Join-Path $repo 'functions'
$checks = [Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name,[scriptblock]$Body) { & $Body; $checks.Add($Name); Write-Host "PASS $Name" }

Test-Case 'Profile imports twice without installations, native compilation or preference changes' {
    function Invoke-RestMethod { throw 'Unexpected startup download.' }
    function Invoke-WebRequest { throw 'Unexpected startup download.' }
    function Install-Module { throw 'Unexpected startup installation.' }
    function Uninstall-Module { throw 'Unexpected startup uninstallation.' }
    function winget { throw 'Unexpected startup winget invocation.' }
    function Add-Type { throw 'Unexpected startup native compilation.' }
    function Get-CimInstance { [CmdletBinding()] param($ClassName,$Filter) [pscustomobject]@{DriveLetter='X:'} }
    function Import-Module { [CmdletBinding()] param($Name,[switch]$Force) Assert-True (-not $Force) 'Startup force-reloaded modules.' }
    $originalPath = $env:PATH
    $originalPreference = $ErrorActionPreference
    $warnings = @()
    . (Join-Path $repo 'Microsoft.PowerShell_profile.ps1') -WarningVariable +warnings
    . (Join-Path $repo 'Microsoft.PowerShell_profile.ps1') -WarningVariable +warnings
    Assert-True ($warnings.Count -eq 0) "Startup warnings: $($warnings -join '; ')"
    Assert-True ($ErrorActionPreference -eq $originalPreference) 'Startup changed the caller error preference.'
    Assert-True ($env:PATH -eq $originalPath) 'Noninteractive startup changed PATH.'
    Assert-True (-not ('ProcessHandler' -as [type])) 'Get-Handle compiled native code during import.'
    Assert-True ((Get-Command Find-ScreenTrouble).CommandType -eq 'Function') 'Screen troubleshooting has no explicit entry point.'
    Assert-True ((Get-Command Invoke-Whispercpp).ScriptBlock.File -notlike '*BACKUP*') 'Backup command overrode the current version.'
    Assert-True ((Get-Command Start-CMatrix).ScriptBlock.File -like '*Start-CMatrix.ps1') 'Duplicate matrix file was loaded.'
    Assert-True ((Get-Alias reboot).Definition -eq 'Get-NeededReboot') 'Reboot alias changed.'
    Assert-True ($XWAYSUSB -eq 'X:') 'X-Ways volume discovery result changed.'
}

Test-Case 'Installed UI tools keep final bindings and do not duplicate PATH or initialize the prompt twice' {
    . (Join-Path $functions 'Initialize-ProfileAppearance.ps1')
    $oldLocalAppData = $env:LOCALAPPDATA
    $oldPath = $env:PATH
    try {
        $env:LOCALAPPDATA = Join-Path $root 'local'
        $bin = Join-Path $env:LOCALAPPDATA 'Programs\oh-my-posh\bin'
        $null = [IO.Directory]::CreateDirectory($bin)
        $env:PATH = $oldPath + ';' + $bin + '\'
        $script:bindings = @{}
        $script:promptCalls = 0
        $script:ProfilePromptInitialized = $false
        function Get-Command {
            [CmdletBinding()] param($Name,$CommandType)
            if ($Name -in @('Set-PSReadLineKeyHandler','oh-my-posh')) { [pscustomobject]@{Name=$Name} }
            else { Microsoft.PowerShell.Core\Get-Command @PSBoundParameters }
        }
        function Set-PSReadLineOption { [CmdletBinding()] param($EditMode) $script:bindings.Clear(); Assert-True ($EditMode -eq 'Windows') 'Wrong editing mode.' }
        function Invoke-SamplePSReadLineProfile { [CmdletBinding()] param($EditMode) Set-PSReadLineOption -EditMode $EditMode; $script:bindings['('] = 'SamplePairInsertion' }
        function Set-PSReadLineKeyHandler { [CmdletBinding()] param($Key,$Function) $script:bindings[$Key]=$Function }
        function Invoke-OhMyPoshRandomTheme { [CmdletBinding()] param([switch]$LocalOnly,[switch]$PassThru) Assert-True ($LocalOnly -and $PassThru) 'Startup did not require a local initialization result.'; $script:promptCalls++; $true }
        Initialize-ProfileAppearance
        Initialize-ProfileAppearance
        Assert-True ($script:promptCalls -eq 1) 'Prompt initialized repeatedly.'
        Assert-True ($script:bindings['('] -eq 'SelfInsert' -and $script:bindings['"'] -eq 'SelfInsert' -and $script:bindings['Tab'] -eq 'Complete') 'Final key bindings reset.'
        Assert-True (@($env:PATH -split ';' | Where-Object { $_.TrimEnd('\') -ieq $bin }).Count -eq 1) 'PATH entry duplicated.'
    }
    finally { $env:LOCALAPPDATA=$oldLocalAppData; $env:PATH=$oldPath }
}

Test-Case 'Missing optional UI tools are a clean no-op; explicit theme invocation installs them' {
    . (Join-Path $functions 'Invoke-OhMyPoshRandomTheme.ps1')
    $script:poshInstalled = $false
    $script:poshInstallCalls = 0
    function Get-Command {
        [CmdletBinding()] param($Name,$CommandType)
        if ($Name -eq 'oh-my-posh') {
            if ($script:poshInstalled) { [pscustomobject]@{Name='oh-my-posh'} }
        }
        elseif ($Name -ne 'Set-PSReadLineKeyHandler') { Microsoft.PowerShell.Core\Get-Command @PSBoundParameters }
    }
    function winget { $script:poshInstallCalls++; $script:poshInstalled=$true; $global:LASTEXITCODE=0 }
    function Invoke-RestMethod { throw 'LocalOnly attempted a network request.' }
    function oh-my-posh { 'function global:prompt { "fixture prompt> " }' }
    $oldLocal = $env:LOCALAPPDATA
    $oldThemes = $env:POSH_THEMES_PATH
    $oldPath = $env:PATH
    try {
        $env:LOCALAPPDATA = Join-Path $root 'missing-ui'
        $env:POSH_THEMES_PATH = Join-Path $root 'themes'
        $null = [IO.Directory]::CreateDirectory($env:POSH_THEMES_PATH)
        [IO.File]::WriteAllText((Join-Path $env:POSH_THEMES_PATH 'fixture.omp.json'),'{}')
        Invoke-OhMyPoshRandomTheme -LocalOnly
        Assert-True ($script:poshInstallCalls -eq 0) 'LocalOnly installed a missing executable.'
        Invoke-OhMyPoshRandomTheme
        Assert-True ($script:poshInstallCalls -eq 1 -and (prompt) -eq 'fixture prompt> ') 'Explicit theme invocation did not install/configure the prompt.'
    }
    finally { $env:LOCALAPPDATA=$oldLocal; $env:POSH_THEMES_PATH=$oldThemes; $env:PATH=$oldPath }
}

Test-Case 'Administrator-only operations fail before repair or installation when invoked unelevated' {
    foreach ($name in @('Set-SOE','Restore-WinMgmt','Get-SYSTEM')) { . (Join-Path $functions "$name.ps1") }
    function Test-IsAdministrator { $false }
    function Start-Process { throw 'Unexpected process launch.' }
    function Install-Module { throw 'Unexpected installation.' }
    function Get-Disk { throw 'Unexpected repair probe.' }
    foreach ($name in @('Set-SOE','Restore-WinMgmt','Get-SYSTEM')) {
        $caught = $false
        try { & $name }
        catch { $caught = $_.Exception.Message -like '*requires an elevated PowerShell session*' }
        Assert-True $caught "$name did not reject an unelevated invocation cleanly."
    }
}

Test-Case 'Screen diagnostics return real matching events and handle an empty event log' {
    . (Join-Path $functions 'Find-ScreenTrouble.ps1')
    function Get-WinEvent {
        [CmdletBinding()] param($FilterHashtable,$MaxEvents)
        Assert-True ($FilterHashtable.LogName -eq 'System' -and $MaxEvents -eq 12) 'Event filter was not passed.'
        @([pscustomobject]@{Id=1;Message='Display stopped responding'},[pscustomobject]@{Id=2;Message='Other event'})
    }
    $events = @(Find-ScreenTrouble -MaxEvents 12)
    Assert-True ($events.Count -eq 1 -and $events[0].Id -eq 1) 'Screen event filtering failed.'
    function Get-WinEvent {
        [CmdletBinding()] param($FilterHashtable,$MaxEvents)
        Write-Error -Message 'No events' -ErrorId NoMatchingEventsFound
    }
    Assert-True (@(Find-ScreenTrouble).Count -eq 0) 'Empty event log was not handled.'
    function Get-WinEvent { [CmdletBinding()] param($FilterHashtable,$MaxEvents) throw 'Access denied fixture' }
    $caught=$false
    try { Find-ScreenTrouble } catch { $caught=$_.Exception.Message -eq 'Access denied fixture' }
    Assert-True $caught 'Log access failure was hidden.'
}
. (Join-Path $functions 'Test-IsAdministrator.ps1')
[pscustomobject]@{Passed=$checks.Count;Checks=$checks;NativeTokenElevated=(Test-IsAdministrator);TestRoot=$root} | ConvertTo-Json -Depth 4
