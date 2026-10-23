#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new fixture directory.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$functions=Join-Path (Split-Path $PSScriptRoot -Parent) functions
foreach($name in 'Invoke-OhMyPoshRandomTheme','Initialize-ProfileAppearance','Invoke-SamplePSReadLineProfile'){. (Join-Path $functions ($name+'.ps1'))}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Assert-Fails([scriptblock]$Body){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Assert $failed 'Expected initialization failure'}
$originalPrompt=(Get-Item Function:prompt).ScriptBlock
$savedEnvironment=@{}
foreach($name in 'LOCALAPPDATA','ProgramFiles','POSH_PATH','POSH_THEMES_PATH'){$savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try {
    $env:LOCALAPPDATA=Join-Path $TestRoot local
    $env:ProgramFiles=Join-Path $TestRoot programs
    $env:POSH_PATH=$null; $env:POSH_THEMES_PATH=$null
    $store=Join-Path $TestRoot 'WindowsApps/ohmyposh.cli [fixture]'
    $null=[IO.Directory]::CreateDirectory((Join-Path $store themes))
    $theme=Join-Path $store 'themes/local.omp.json'
    [IO.File]::WriteAllText($theme,'{}')
    $script:packages=@([pscustomobject]@{InstallLocation=$store})
    $script:installed=$true; $script:exitCode=0; $script:emptyScript=$false; $script:poshCalls=0
    function Get-AppxPackage {
        [CmdletBinding()]param($Name)
        Assert ($Name -eq 'ohmyposh.cli*') 'Package discovery was not scoped to Oh My Posh'
        $script:packages
    }
    function Get-Command {
        [CmdletBinding()]param($Name,$CommandType)
        if($Name -eq 'oh-my-posh'){if($script:installed){[pscustomobject]@{Name='oh-my-posh';CommandType='Application'}}}
        else{Microsoft.PowerShell.Core\Get-Command @PSBoundParameters}
    }
    function oh-my-posh {
        $script:poshCalls++; $script:poshArguments=@($args); $global:LASTEXITCODE=$script:exitCode
        if(-not $script:emptyScript){'function global:prompt { "store fixture> " }'}
    }
    function Invoke-RestMethod {throw 'Local startup must not request remote themes'}
    function Invoke-WebRequest {throw 'Local startup must not download'}
    function winget {throw 'Local startup must not install'}
    $result=@(Invoke-OhMyPoshRandomTheme -LocalOnly -PassThru)
    Assert ($result.Count -eq 1 -and $result[0] -eq $true -and (prompt) -eq 'store fixture> ') 'Store initialization did not execute'
    Assert ($script:poshArguments.Count -eq 4 -and $script:poshArguments[2] -eq '--config' -and $script:poshArguments[3] -eq $theme) 'MSIX theme path or argument boundaries were lost'
    Write-Host 'PASS: registered Store/MSIX theme discovery and generated prompt execution'

    $script:packages=@()
    Assert (Invoke-OhMyPoshRandomTheme -LocalOnly -PassThru) 'Built-in fallback did not initialize'
    Assert (($script:poshArguments -join ',') -eq 'init,pwsh') 'No-theme startup did not use the built-in default'
    $script:installed=$false
    $beforeCalls=$script:poshCalls
    Assert ((Invoke-OhMyPoshRandomTheme -LocalOnly -PassThru) -eq $false -and $script:poshCalls -eq $beforeCalls) 'Missing executable reported initialization'
    $script:installed=$true
    Write-Host 'PASS: no-theme default prompt and missing-tool result without network or installation'

    $script:exitCode=7
    Assert-Fails {Invoke-OhMyPoshRandomTheme -LocalOnly -PassThru}
    $script:exitCode=0; $script:emptyScript=$true
    Assert-Fails {Invoke-OhMyPoshRandomTheme -LocalOnly -PassThru}
    $script:ProfilePromptInitialized=$false
    Initialize-ProfileAppearance -WarningAction SilentlyContinue
    Assert (-not $script:ProfilePromptInitialized) 'Failed initialization was cached as success'
    $script:emptyScript=$false
    Initialize-ProfileAppearance
    Assert $script:ProfilePromptInitialized 'Retry after failure did not initialize'
    $beforeCalls=$script:poshCalls
    Initialize-ProfileAppearance
    Assert ($script:poshCalls -eq $beforeCalls) 'Successful prompt initialization was repeated'
    Write-Host 'PASS: native/empty-script failures stay retryable; successful initialization runs once'

    Assert ((Get-PSReadLineOption).EditMode -eq 'Windows') 'The sample reset Windows editing mode'
    Assert ((Get-PSReadLineKeyHandler -Chord Tab).Function -eq 'Complete') 'Tab completion was lost'
    Assert ((Get-PSReadLineKeyHandler -Chord '(').Function -eq 'SelfInsert') 'Bracket override was lost'
    Assert ((Get-PSReadLineKeyHandler -Chord UpArrow).Function -eq 'HistorySearchBackward') 'Custom history binding was lost'
    Invoke-SamplePSReadLineProfile
    Assert ((Get-PSReadLineOption).EditMode -eq 'Emacs') 'The standalone sample default changed'
    Write-Host 'PASS: real PSReadLine Windows mode, custom history, final Tab/bracket bindings and standalone compatibility'
}
finally {
    foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}
    Set-Item Function:global:prompt $originalPrompt
}
