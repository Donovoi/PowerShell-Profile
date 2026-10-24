#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$asset=Join-Path $repo 'scripts/ExecutableAnalysis/WindowsGuestSession.ps1'
$TestRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new TestRoot.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Throws([scriptblock]$Body,[string]$Pattern){try{& $Body;throw 'Expected exception'}catch{if($_.Exception.Message -notmatch $Pattern){throw}}}
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($asset,[ref]$tokens,[ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'The session helper does not parse.'
$native=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('using System;') -and $node.Value.Contains('public static class ProfileAnalysisSessionNative')},$true))
Assert-True ($native.Count -eq 1) 'Expected exactly one literal native helper.'
# Compiles declarations only. No LSA, registry, logon, task, session or power APIs are called.
if(-not ('ProfileAnalysisSessionNative' -as [type])){Add-Type -TypeDefinition $native[0].Value -Language CSharp}
Write-Output 'PASS: guest asset parses and its native declarations compile without calling session APIs.'

foreach($name in 'Assert-SessionRegularPath','Read-SessionJson','Write-SessionJson','Enter-SessionMutationLock','Wait-SessionProof','Assert-SessionAutoLogonBaseline','Get-SessionBaselineCredential','Get-SessionPowerCfgArgumentList','Assert-SessionPowerPolicy','Get-SessionVerifiedPowerPolicy','Set-SessionPowerPolicy'){
    $definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
    Assert-True ($definitions.Count -eq 1) ('Missing safe file helper: '+$name)
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}
$recordPath=Join-Path $TestRoot 'record.json'
Write-SessionJson $recordPath ([pscustomobject]@{UserName='fixture';Status='Ready'}) -CreateNew
Assert-True ((Read-SessionJson $recordPath).Status -eq 'Ready') 'The private JSON helper changed its record.'
$hash=(Get-FileHash -LiteralPath $recordPath).Hash
Assert-Throws {Write-SessionJson $recordPath ([pscustomobject]@{Status='Wrong'}) -CreateNew} 'already exists'
Assert-True ((Get-FileHash -LiteralPath $recordPath).Hash -eq $hash) 'CreateNew overwrote existing evidence.'
$invalid=Join-Path $TestRoot 'invalid.json'
[IO.File]::WriteAllText($invalid,'{"UserPassword":"UNIQUE_SECRET_SENTINEL",broken')
try{$null=Read-SessionJson $invalid;throw 'Expected exception'}catch{Assert-True ($_.Exception.Message -eq 'The private session record is not valid JSON.') 'A malformed private configuration exposed source text or lost its generic error.'}
$large=Join-Path $TestRoot 'large.json';[IO.File]::WriteAllBytes($large,[byte[]]::new(16385))
Assert-Throws {Read-SessionJson $large} 'exceeds its size budget'
Assert-Throws {Read-SessionJson $TestRoot} 'regular files'
Write-Output 'PASS: bounded private JSON records preserve bytes, refuse overwrite and redact malformed credential input.'

$source=[IO.File]::ReadAllText($asset)
Assert-True ($source.Contains('WTSGetActiveConsoleSessionId') -and $source.Contains('WTSQueryUserToken') -and $source.Contains('StandardTokenVerified')) 'Actual interactive console/token verification is absent.'
Assert-True ($source.Contains("LsaStorePrivateData") -and -not ($source -match "New-ItemProperty[^\r\n]+-Name 'DefaultPassword'")) 'Autologon password must use the LSA secret instead of a plaintext registry value.'
Assert-True ($source.Contains('$PSCommandPath') -and $source.Contains('fixed trusted guest path')) 'The guest-only execution path guard is absent.'
Assert-True ($source.Contains("Principal.UserId='S-1-5-18'") -and $source.Contains("-Mode Cleanup';")) 'The secret-free SYSTEM cleanup task is absent.'
Assert-True ($source.Contains("ExecutionTimeLimit='PT5M'")) 'The SYSTEM cleanup task lost its bounded first-logon allowance.'
Write-Output 'PASS: the session helper retains guest-path, LSA-secret and actual-console verification boundaries.'

# Fake both power APIs and the powercfg boundary. Never invoke powercfg.exe or
# the compiled native PowerPolicy method on the host.
$powerScheme='381b4222-f694-41f0-9685-ff5bb260df2e'
function Get-SessionPowerPolicy {
    $script:powerReads++
    if($script:powerCase -eq 'unsupported'){throw 'Mock power API unsupported'}
    $snapshot=$script:powerState.Clone()
    if($script:powerCase -eq 'scheme-change' -and $script:powerReads -gt 1){$snapshot.ActiveSchemeId='11111111-2222-3333-4444-555555555555'}
    if($script:powerCase -eq 'missing-value'){$snapshot.Remove('MonitorTimeoutDcSeconds')}
    return [pscustomobject]$snapshot
}
function Invoke-SessionPowerCfg {
    param([string]$Operation,[guid]$SchemeId,[string]$Setting='Monitor')
    $arguments=@(Get-SessionPowerCfgArgumentList -Operation $Operation -SchemeId $SchemeId -Setting $Setting)
    $null=$script:powerCommands.Add(($arguments -join ' '))
    if($script:powerCase -eq 'command-failure' -and $script:powerCommands.Count -eq 3){throw 'Mock powercfg failed with exit code 5'}
    if($script:powerCase -ne 'ignored-write' -and $Operation -ne 'SetActive'){
        $suffix=if($Operation -eq 'SetAc'){'AcSeconds'}else{'DcSeconds'}
        $script:powerState[$Setting+'Timeout'+$suffix]=[uint32]0
    }
}
foreach($case in 'success','unsupported','missing-value','command-failure','ignored-write','scheme-change'){
    $script:powerCase=$case;$script:powerReads=0;$script:powerCommands=New-Object 'Collections.Generic.List[string]'
    $script:powerState=@{ActiveSchemeId=$powerScheme;MonitorTimeoutAcSeconds=[uint32]600;MonitorTimeoutDcSeconds=[uint32]300;StandbyTimeoutAcSeconds=[uint32]1800;StandbyTimeoutDcSeconds=[uint32]900}
    if($case -eq 'success'){
        $policy=Set-SessionPowerPolicy
        Assert-True ($policy.Verified.Status -eq 'Verified' -and $policy.Before.MonitorTimeoutAcSeconds -eq 600 -and $policy.Before.StandbyTimeoutDcSeconds -eq 900) 'Power configuration lost its original policy evidence.'
        Assert-SessionPowerPolicy -Policy $policy.Verified -ExpectedSchemeId $powerScheme
        $expected=@(
            "/setacvalueindex $powerScheme 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 0",
            "/setdcvalueindex $powerScheme 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 0",
            "/setacvalueindex $powerScheme 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0",
            "/setdcvalueindex $powerScheme 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0",
            "/setactive $powerScheme"
        )
        Assert-True (($script:powerCommands -join "`n") -ceq ($expected -join "`n")) 'Power configuration did not write and activate exactly the four fixed AC/DC settings.'
        # Ready verification must read the current policy again, not reuse a marker.
        $script:powerState.StandbyTimeoutDcSeconds=[uint32]1
        Assert-Throws {Get-SessionVerifiedPowerPolicy -ExpectedSchemeId $powerScheme} 'StandbyTimeoutDcSeconds'
    }elseif($case -eq 'unsupported'){
        Assert-Throws {Set-SessionPowerPolicy} 'API unsupported'
        Assert-True ($script:powerCommands.Count -eq 0) 'An unsupported API triggered power mutation.'
    }elseif($case -eq 'missing-value'){
        Assert-Throws {Set-SessionPowerPolicy} 'value is unavailable'
        Assert-True ($script:powerCommands.Count -eq 0) 'An incomplete policy triggered power mutation.'
    }elseif($case -eq 'command-failure'){
        Assert-Throws {Set-SessionPowerPolicy} 'exit code 5'
        Assert-True ($script:powerCommands.Count -eq 3) 'A failed write did not stop configuration.'
    }elseif($case -eq 'ignored-write'){
        Assert-Throws {Set-SessionPowerPolicy} 'not verified'
    }else{Assert-Throws {Set-SessionPowerPolicy} 'scheme changed'}
}
Assert-Throws {Get-SessionPowerCfgArgumentList -Operation 'SetArbitrary' -SchemeId $powerScheme} 'does not belong to the set'
Assert-Throws {Get-SessionPowerCfgArgumentList -Operation SetAc -SchemeId 'bad & command'} 'Cannot process argument transformation|Cannot convert'
Assert-Throws {Get-SessionPowerCfgArgumentList -Operation SetActive -SchemeId ([guid]::Empty)} 'identity is invalid'
$invalidPolicy=@{ActiveSchemeId=$powerScheme;MonitorTimeoutAcSeconds='0';MonitorTimeoutDcSeconds=0;StandbyTimeoutAcSeconds=0;StandbyTimeoutDcSeconds=0}
Assert-Throws {Assert-SessionPowerPolicy -Policy ([pscustomobject]$invalidPolicy)} 'invalid type'
Assert-True ($source.Contains('PowerReadACValueIndex') -and $source.Contains('PowerReadDCValueIndex') -and $source.Contains('PowerGetActiveScheme') -and $source.Contains('LocalFree(pointer)')) 'Native invariant power verification or allocation cleanup is absent.'
Assert-True ($source.Contains('[ValidateRange(1,15)][int]$TimeoutSeconds=15') -and $source.Contains('$characters -gt 16384')) 'Powercfg process execution lost its time or output bound.'
Write-Output 'PASS: fake power APIs/powercfg verify exact AC/DC GUID writes, original evidence, fresh readiness checks and refusal of unsupported, incomplete, failed, unchanged or switched policies without changing host power settings.'

# Exercise the actual bounded process wrapper with a harmless PowerShell fixture
# substituted for powercfg. Only the executable and fixed argument factory differ.
$processDefinition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SessionPowerCfg'},$true).Extent.Text
$fixtureDefinition=$processDefinition.Replace('function Invoke-SessionPowerCfg','function Invoke-FixturePowerCfg').Replace("'System32\powercfg.exe'","'System32\WindowsPowerShell\v1.0\powershell.exe'")
Assert-True (-not $fixtureDefinition.Contains("'System32\powercfg.exe'") -and $fixtureDefinition.Contains('function Invoke-FixturePowerCfg')) 'The fixture did not replace the real powercfg executable.'
. ([scriptblock]::Create($fixtureDefinition))
function Get-SessionPowerCfgArgumentList {
    param([string]$Operation,[guid]$SchemeId,[string]$Setting)
    $code=switch($script:powerProcessCase){
        'success' {"[Console]::Write('fixture');exit 0"}
        'failure' {"[Console]::Error.Write('fixture');exit 7"}
        'timeout' {'Start-Sleep -Seconds 30'}
        'output' {"[Console]::Write(('x'*20000));exit 0"}
        default {throw 'Unknown fixture process case.'}
    }
    return @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
}
$script:powerProcessCase='success';Invoke-FixturePowerCfg -Operation SetActive -SchemeId $powerScheme -TimeoutSeconds 5
$script:powerProcessCase='failure';Assert-Throws {Invoke-FixturePowerCfg -Operation SetActive -SchemeId $powerScheme -TimeoutSeconds 5} 'exit code 7'
$script:powerProcessCase='output';Assert-Throws {Invoke-FixturePowerCfg -Operation SetActive -SchemeId $powerScheme -TimeoutSeconds 5} 'output limit'
$script:powerProcessCase='timeout';$fixtureTimer=[Diagnostics.Stopwatch]::StartNew()
Assert-Throws {Invoke-FixturePowerCfg -Operation SetActive -SchemeId $powerScheme -TimeoutSeconds 1} 'deadline'
Assert-True ($fixtureTimer.Elapsed.TotalSeconds -lt 8) 'The fixture process timeout did not return within its termination allowance.'
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SessionPowerCfgArgumentList'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
Write-Output 'PASS: real harmless fixture processes verify powercfg-wrapper success, nonzero exit, output cap and timeout termination without launching powercfg.'

$lockPath=Join-Path $TestRoot 'fixture.lock'
$held=Enter-SessionMutationLock -Path $lockPath -Operation Configure
try{
    Assert-Throws {Enter-SessionMutationLock -Path $lockPath -Operation Configure} 'another process|being used'
    Assert-Throws {Enter-SessionMutationLock -Path $lockPath -Operation Cleanup -CleanupWaitSeconds 0} 'another process|being used'
}finally{$held.Dispose()}
$held=Enter-SessionMutationLock -Path $lockPath -Operation Cleanup
$held.Dispose()
$probeState=@{Count=0}
$proof=Wait-SessionProof -TimeoutSeconds 1 -PollMilliseconds 10 -Probe {$probeState.Count++;if($probeState.Count -lt 3){throw 'Desktop is not ready'};[pscustomobject]@{Ready=$true}}
Assert-True ($proof.Ready -and $probeState.Count -eq 3) 'Console proof did not recover from transient readiness failures.'
Assert-Throws {Wait-SessionProof -TimeoutSeconds 0 -Probe {throw 'Still not ready'}} 'Still not ready'
Assert-True ($source.Contains("if(`$Mode -ne 'Verify'){`$lock=Enter-SessionMutationLock")) 'Read-only verification can still starve cleanup by acquiring its lock.'
foreach($count in 0,1,$null){$null=Assert-SessionAutoLogonBaseline -SecretPresent $false -PlaintextPasswordPresent $false -AutoAdminLogon '0' -AutoLogonCount $count}
$null=Assert-SessionAutoLogonBaseline -SecretPresent $false -PlaintextPasswordPresent $false -AutoAdminLogon $null -AutoLogonCount $null
Assert-Throws {Assert-SessionAutoLogonBaseline -SecretPresent $false -PlaintextPasswordPresent $false -AutoAdminLogon '1' -AutoLogonCount 0} 'AutoAdminLogon=1'
Assert-Throws {Assert-SessionAutoLogonBaseline -SecretPresent $true -PlaintextPasswordPresent $false -AutoAdminLogon '0' -AutoLogonCount 0} 'LsaSecretPresent=True'
Assert-Throws {Assert-SessionAutoLogonBaseline -SecretPresent $false -PlaintextPasswordPresent $true -AutoAdminLogon '0' -AutoLogonCount 1} 'PlaintextPasswordValuePresent=True'
Assert-Throws {Assert-SessionAutoLogonBaseline -SecretPresent $false -PlaintextPasswordPresent $false -AutoAdminLogon $null -AutoLogonCount 1} 'must not be replaced'
Write-Output 'PASS: mutation locks are bounded, read-only verification cannot starve cleanup, console proof retries, and disabled stale counters are accepted without accepting existing secrets.'

$baseline=@{SecretPresent=$true;SecretEmpty=$false;OwnedCredentialMatch=$true;BaselineMigrationEnabled=$true;PlaintextPasswordPresent=$false;AutoAdminLogon='0';AutoLogonCount=1;DefaultUserName='analysis-admin';DefaultDomainName='FIXTURE';ComputerName='FIXTURE'}
foreach($domain in @($null,'','.','fixture')){
    $allowed=$baseline.Clone();$allowed.DefaultDomainName=$domain
    $classification=Assert-SessionAutoLogonBaseline @allowed
    Assert-True ($classification.Classification -eq 'OwnedProvisioningCredential' -and $classification.UserName -ceq 'analysis-admin' -and @($classification.PSObject.Properties).Count -eq 2) 'A proven local provisioning credential was rejected or retained extra evidence.'
}
$emptyBaseline=$baseline.Clone();$emptyBaseline.SecretEmpty=$true;$emptyBaseline.OwnedCredentialMatch=$false
Assert-True ((Assert-SessionAutoLogonBaseline @emptyBaseline).Classification -eq 'Empty') 'An opted-in empty inactive LSA value was rejected.'
foreach($mutation in @(@{BaselineMigrationEnabled=$false},@{OwnedCredentialMatch=$false},@{DefaultDomainName='OTHER-DOMAIN'},@{DefaultDomainName=4},@{DefaultUserName='DOMAIN\user'},@{AutoAdminLogon='1'},@{AutoAdminLogon=$null},@{PlaintextPasswordPresent=$true},@{SecretEmpty=$true})){
    $rejected=$baseline.Clone();foreach($key in $mutation.Keys){$rejected[$key]=$mutation[$key]}
    Assert-Throws {Assert-SessionAutoLogonBaseline @rejected} 'must not be replaced'
}
$emptyBaseline.BaselineMigrationEnabled=$false
Assert-Throws {Assert-SessionAutoLogonBaseline @emptyBaseline} 'must not be replaced'
$knownCredentials=@([pscustomobject]@{UserName='Administrator';UserPassword='Known fixture A!'},[pscustomobject]@{UserName='Administrator';UserPassword='Known fixture B!'})
Assert-True (@(Get-SessionBaselineCredential $knownCredentials).Count -eq 2) 'Rotated credentials for the same known account were rejected.'
Assert-True (@(Get-SessionBaselineCredential $null).Count -eq 0 -and @(Get-SessionBaselineCredential @()).Count -eq 0) 'Absent baseline credentials enabled migration.'
foreach($invalid in @('secret',([pscustomobject]@{UserName='user';UserPassword='secret'}),@($knownCredentials[0],$knownCredentials[0],$knownCredentials[0],$knownCredentials[0]),@([pscustomobject]@{UserName='bad\name';UserPassword='secret'}),@([pscustomobject]@{UserName='user';UserPassword=4}),@([pscustomobject]@{UserName='user';UserPassword=''}),@([pscustomobject]@{UserName='user';UserPassword=('x'*1025)}),@([pscustomobject]@{UserName='user';UserPassword="x`0y"}),@([pscustomobject]@{UserName='user';UserPassword='secret';Extra='UNIQUE_SECRET_SENTINEL'}))){
    try{$null=Get-SessionBaselineCredential $invalid;throw 'Expected validation refusal'}catch{Assert-True ($_.Exception.Message -match 'BaselineCredentials|owned baseline credential' -and $_.Exception.Message -notmatch 'UNIQUE_SECRET_SENTINEL|Known fixture') 'Invalid baseline credential was accepted or exposed in its error.'}
}

# Exercise only a pure native comparison with known fixture bytes. No LSA APIs run.
$unicodeType=[ProfileAnalysisSessionNative].GetNestedType('Unicode',[Reflection.BindingFlags]::NonPublic)
$compare=[ProfileAnalysisSessionNative].GetMethod('CompareSecret',([Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::NonPublic))
Assert-True ($null -ne $compare) 'The exact native secret comparison is unavailable for known-byte tests.'
foreach($text in @('Known fixture A!',('Wide-'+[char]0x03A9+[char]0x6F22),'')){
    $buffer=[Runtime.InteropServices.Marshal]::StringToCoTaskMemUni($text)
    try{
        $value=[Activator]::CreateInstance($unicodeType)
        $unicodeType.GetField('Length').SetValue($value,[uint16]($text.Length*2));$unicodeType.GetField('MaximumLength').SetValue($value,[uint16]($text.Length*2+2));$unicodeType.GetField('Buffer').SetValue($value,$buffer)
        Assert-True ([bool]$compare.Invoke($null,@($value,$text)) -eq ($text.Length -gt 0)) 'Native comparison changed known UTF-16 bytes or accepted an empty secret.'
        Assert-True (-not [bool]$compare.Invoke($null,@($value,($text+'x')))) 'Native comparison accepted a different length.'
        if($text.Length){Assert-True (-not [bool]$compare.Invoke($null,@($value,('X'+$text.Substring(1))))) 'Native comparison accepted different bytes.'}
    }finally{for($i=0;$i -lt ($text.Length*2+2);$i++){[Runtime.InteropServices.Marshal]::WriteByte($buffer,$i,0)};[Runtime.InteropServices.Marshal]::FreeCoTaskMem($buffer)}
}
Assert-True ($source.Contains('$currentBaseline=Get-SessionAutoLogonBaseline') -and $source.IndexOf('$currentBaseline=Get-SessionAutoLogonBaseline') -lt $source.IndexOf('[ProfileAnalysisSessionNative]::StoreSecret($configuration.UserPassword)') -and $source.Contains('-PreserveAutoLogon:(-not $autoLogonWritten)')) 'Final baseline recheck or refusal cleanup could overwrite an unrelated secret.'
Write-Output 'PASS: opt-in baseline migration validates bounded credentials and local identity, compares known native UTF-16 bytes exactly, refuses unknown/active secrets, and records no credential material.'

$deploymentRegressions=[Collections.Generic.List[string]]::new()
& {
    # Import only pure diagnostic functions and isolated catch/result clauses.
    # Never load the package script entry point, deployment task adapter, AppX
    # cmdlets, real event/ACL readers, or controller task lifecycle on the host.
    $packageAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/ExecutableAnalysis/WindowsGuestPackage.ps1'),[ref]$tokens,[ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'The package helper does not parse.'
    foreach($name in 'Select-DeploymentStagedPackage','Set-DeploymentDiagnosticText','Get-DeploymentPathPermission','New-DeploymentOperationView','Get-DeploymentFailure'){
        $definition=@($packageAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
        Assert-True ($definition.Count -eq 1) ('The diagnostic helper is missing: '+$name)
        if($definition.Count){. ([scriptblock]::Create($definition[0].Extent.Text))}
    }
    $identity=[pscustomobject]@{Name='Known.RuntimeFixture';Publisher='CN=Fixture Only';Version='1.2.3.4';ProcessorArchitecture='x64';ResourceId=''}
    $stagedFullName='Known.RuntimeFixture_1.2.3.4_x64__0123456789abc'
    function New-StagedIdentityFixture {
        [pscustomobject]@{Name=$identity.Name;Publisher=$identity.Publisher;Version=[version]$identity.Version;Architecture='X64';ResourceId='';PackageFullName=$stagedFullName;PackageFamilyName='Known.RuntimeFixture_0123456789abc';InstallLocation='';PackageUserInformation=@()}
    }
    $stagedFixture=New-StagedIdentityFixture
    $selected=Select-DeploymentStagedPackage -Candidates @($stagedFixture) -Identity $identity
    Assert-True ([object]::ReferenceEquals($selected,$stagedFixture) -and $selected.InstallLocation -ceq '') 'The exact staged object with an empty install location was not retained.'
    foreach($field in 'Name','Publisher','Version','Architecture','ResourceId'){
        $mismatch=New-StagedIdentityFixture;$mismatch.$field=if($field -eq 'Version'){[version]'9.8.7.6'}else{'Wrong fixture identity'}
        Assert-Throws {Select-DeploymentStagedPackage -Candidates @($mismatch) -Identity $identity} 'missing or ambiguous'
        Assert-True ([object]::ReferenceEquals((Select-DeploymentStagedPackage -Candidates @($mismatch,$stagedFixture) -Identity $identity),$stagedFixture)) 'An unrelated staged identity interfered with exact selection.'
    }
    foreach($badName in @($null,'','Known.RuntimeFixture_1.2.3.4_arm64__0123456789abc','Known.RuntimeFixture_1.2.3.4_x64_resource_0123456789abc','KnownXRuntimeFixture_1.2.3.4_x64__0123456789abc','Known.RuntimeFixture_1.2.3.4_x64__0123456789ab!',($stagedFullName+'-suffix'))){
        $malformed=New-StagedIdentityFixture;$malformed.PackageFullName=$badName
        Assert-Throws {Select-DeploymentStagedPackage -Candidates @($malformed) -Identity $identity} 'missing or ambiguous'
    }
    Assert-Throws {Select-DeploymentStagedPackage -Candidates @() -Identity $identity} 'missing or ambiguous'
    Assert-Throws {Select-DeploymentStagedPackage -Candidates @($stagedFixture,(New-StagedIdentityFixture)) -Identity $identity} 'missing or ambiguous'
    $packageEntry=@($packageAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0]
    $modeBranch=@($packageEntry.Body.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -match '\$Mode -eq'})[0]
    $standardStatements=@($modeBranch.ElseClause.Statements)
    $identityGuard=@($standardStatements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match '^if\(-not \$ExpectedPackageFullName'})
    $currentQuery=@($standardStatements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$registered'})
    $currentGuard=@($standardStatements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match '^if\(\$registered.Count'})
    $identityPattern=@($packageEntry.Body.Statements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$fullNamePattern'})
    Assert-True ($identityGuard.Count -eq 1 -and $currentQuery.Count -eq 1 -and $currentGuard.Count -eq 1 -and $identityPattern.Count -eq 1) 'Standard-user identity verification clauses changed.'
    $standardIdentityCheck=[scriptblock]::Create(($identityPattern[0].Extent.Text,$identityGuard[0].Extent.Text,$currentQuery[0].Extent.Text,$currentGuard[0].Extent.Text -join "`n"))
    function Get-AppxPackage {param([string]$Name,[switch]$AllUsers);$script:currentPackageQueryCount++;Assert-True ($Name -ceq $identity.Name -and -not $AllUsers) 'Standard registration inspected another user or package.';return $currentRows}
    $ExpectedPackageFullName=$stagedFullName;$currentRows=@($stagedFixture);$script:currentPackageQueryCount=0
    & $standardIdentityCheck
    Assert-True ($script:currentPackageQueryCount -eq 1) 'Standard registration did not verify the current user.'
    foreach($currentRows in @(@(),@($stagedFixture,(New-StagedIdentityFixture)),@([pscustomobject]@{Version=[version]$identity.Version;Publisher=$identity.Publisher;PackageFullName=$stagedFullName.ToUpperInvariant()}))){
        Assert-Throws {& $standardIdentityCheck} 'standard user did not register the exact staged identity'
    }
    $currentRows=@($stagedFixture)
    foreach($ExpectedPackageFullName in @($null,'','Different.Package_1.2.3.4_x64__0123456789abc',($stagedFullName+"';throw 'Injected'"))){
        $script:currentPackageQueryCount=0
        Assert-Throws {& $standardIdentityCheck} 'requires the exact staged package identity'
        Assert-True ($script:currentPackageQueryCount -eq 0) 'Invalid staged identity reached current-user package lookup.'
    }
    $controlManifestPath='C:\ProfileAnalysis\payload-manifest.json'
    foreach($controlAsset in 'scripts/ExecutableAnalysis/WindowsGuestPackage.ps1','scripts/ExecutableAnalysis/WindowsGuestController.ps1','scripts/ExecutableAnalysis/WindowsGuestRunner.ps1','functions/Invoke-ExecutableAnalysisWindowsVm.ps1'){
        $controlAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $controlAsset),[ref]$tokens,[ref]$parseErrors)
        Assert-True ($parseErrors.Count -eq 0) ('A manifest-control asset does not parse: '+$controlAsset)
        $controlPaths=@($controlAst.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like 'C:\ProfileAnalysis\*payload-manifest.json'},$true))
        Assert-True ($controlPaths.Count -ge 1 -and @($controlPaths|Where-Object {$_.Value -cne $controlManifestPath}).Count -eq 0) ('The guest control manifest path diverged or entered the OS-managed Work tree: '+$controlAsset)
    }
    $commonStatements=@($packageEntry.Body.Statements)
    $modeIndex=[array]::IndexOf($commonStatements,$modeBranch)
    Assert-True ($modeIndex -gt 0) 'The package registration branch was not found.'
    $commonReads=@(foreach($statement in $commonStatements[0..($modeIndex-1)]){$statement.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in 'Get-Item','Get-Content','Get-FileHash','Get-Acl','Get-ChildItem'},$true)})
    Assert-True ($commonReads.Count -eq 3) 'The pre-registration control manifest read contract changed.'
    foreach($read in $commonReads){
        $literalParameter=@($read.CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'LiteralPath'})
        Assert-True ($literalParameter.Count -eq 1) 'A pre-registration read lost its literal control path.'
        $pathIndex=[array]::IndexOf(@($read.CommandElements),$literalParameter[0])+1
        Assert-True ($read.CommandElements[$pathIndex] -is [Management.Automation.Language.VariableExpressionAst] -and $read.CommandElements[$pathIndex].VariablePath.UserPath -ceq 'manifestPath') 'Standard registration reads a protected source file before registration.'
    }
    $standardReads=@($modeBranch.ElseClause.FindAll({param($node)($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in 'Get-Item','Get-Content','Get-FileHash','Get-Acl','Get-ChildItem') -or ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Extent.Text -match '(?i)(?:IO\.File|XmlReader|XmlDocument|\.Load\()')},$true))
    Assert-True ($standardReads.Count -eq 0) 'Standard registration depends on protected source files instead of preserved metadata.'
    $stageHashes=@($modeBranch.Clauses[0].Item2.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-FileHash' -and $node.Extent.Text -match '\$appx'},$true))
    Assert-True ($stageHashes.Count -eq 1) 'Management staging stopped verifying the preserved signed manifest hash.'
    $applicationSelection=@($standardStatements|Where-Object {($_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in '$applications','$record.ApplicationId','$record.Aumid') -or ($_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match '^if\(\$applications.Count')})
    Assert-True ($applicationSelection.Count -eq 4) 'The preserved application metadata selection contract changed.'
    $selectApplication=[scriptblock]::Create(($applicationSelection|ForEach-Object {$_.Extent.Text}) -join "`n")
    $payload=[pscustomobject]@{EntryPoint='app/Known.exe';Package=[pscustomobject]@{Applications=@([pscustomobject]@{Id='Main.App';Executable='APP\known.exe'},[pscustomobject]@{Id='Other.App';Executable='app/Other.exe'})}}
    $record=[ordered]@{PackageFamilyName='Known.RuntimeFixture_0123456789abc'}
    & $selectApplication
    Assert-True ($record.ApplicationId -ceq 'Main.App' -and $record.Aumid -ceq 'Known.RuntimeFixture_0123456789abc!Main.App') 'Preserved application metadata did not select the intended case-insensitive relative executable and AUMID.'
    foreach($badId in @($null,'','1StartsWithDigit','Contains Space','App!Injection','App/Traversal',('A'*65))){
        $payload.Package.Applications=@([pscustomobject]@{Id=$badId;Executable='app/Known.exe'})
        Assert-Throws {& $selectApplication} 'unambiguous Appx application declaration'
    }
    foreach($declarations in @(@(),@([pscustomobject]@{Id='Other';Executable='app/Other.exe'}),@([pscustomobject]@{Id='First';Executable='app/Known.exe'},[pscustomobject]@{Id='Second';Executable='APP\known.exe'}))){
        $payload.Package.Applications=$declarations
        Assert-Throws {& $selectApplication} 'unambiguous Appx application declaration'
    }
    Write-Output 'PASS: all control-manifest paths stay outside the package tree; standard registration uses hashed application metadata and rejects missing, ambiguous or invalid application IDs without source-file reads.'
    Write-Output 'PASS: pure staged selection preserves the actual empty-location row and rejects mismatched, missing, duplicate or malformed identities; fake current-user lookup requires the exact selected full name.'
    $adapter=$packageAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-DeploymentOperationView'},$true)
    $rawMembers=@($adapter.FindAll({param($node)$node -is [Management.Automation.Language.MemberExpressionAst] -and $node.Expression -is [Management.Automation.Language.VariableExpressionAst] -and $node.Expression.VariablePath.UserPath -eq 'Operation'},$true))
    Assert-True ($rawMembers.Count -eq 0) 'The WinRT adapter depends on unavailable raw COM members.'
    if(-not ('ProfileAnalysisFixture.TypedOperation' -as [type])){
        Add-Type -Language CSharp -TypeDefinition @'
using System;
namespace Windows.Foundation {
 public enum AsyncStatus {Started,Completed,Canceled,Error}
 public interface IAsyncInfo {AsyncStatus Status {get;} Exception ErrorCode {get;} void Cancel();}
}
namespace ProfileAnalysisFixture {
 public sealed class KnownResult {public string Marker="Known typed result";}
 public interface IProgressContract<TResult,TProgress> : Windows.Foundation.IAsyncInfo {TResult GetResults();}
 public sealed class TypedOperation : IProgressContract<KnownResult,int> {
  public bool CancelCalled;public int ResultCalls;
  Windows.Foundation.AsyncStatus Windows.Foundation.IAsyncInfo.Status {get{return CancelCalled?Windows.Foundation.AsyncStatus.Canceled:Windows.Foundation.AsyncStatus.Completed;}}
  Exception Windows.Foundation.IAsyncInfo.ErrorCode {get{return null;}}
  void Windows.Foundation.IAsyncInfo.Cancel(){CancelCalled=true;}
  KnownResult IProgressContract<KnownResult,int>.GetResults(){ResultCalls++;return new KnownResult();}
 }
}
'@
    }
    $typed=[ProfileAnalysisFixture.TypedOperation]::new()
    $contract=[ProfileAnalysisFixture.IProgressContract[ProfileAnalysisFixture.KnownResult,int]]
    Assert-True ($null -eq $typed.GetType().GetMethod('GetResults') -and $null -eq $typed.GetType().GetProperty('Status')) 'The typed fixture accidentally exposes raw members.'
    $view=New-DeploymentOperationView -Operation $typed -Contract $contract
    Assert-True ($view.Status.ToString() -eq 'Completed' -and $null -eq $view.ErrorCode -and $view.GetResults().Marker -eq 'Known typed result' -and $typed.ResultCalls -eq 1) 'Projected typed result or status access failed.'
    $null=$view.Cancel()
    Assert-True ($typed.CancelCalled -and $view.Status.ToString() -eq 'Canceled') 'Projected cancellation did not invoke the interface or refresh status.'
    Assert-Throws {New-DeploymentOperationView -Operation $typed -Contract ([object])} 'metadata is unavailable'

    # Windows PowerShell 5.1 is the actual guest runtime. This probe invokes only
    # the read-only StorageFile API against a verified nonexistent local path.
    $projectionProbe=Join-Path $TestRoot 'Test-ReadOnlyWinRtProjection.ps1'
    $projectionResult=Join-Path $TestRoot 'winrt-projection-result.json'
    $projectionSource=@'
#requires -Version 5.1
param([string]$PackageAsset,[string]$FixtureDirectory,[string]$ResultPath)
$ErrorActionPreference='Stop'
function Assert-Projection([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($PackageAsset,[ref]$tokens,[ref]$errors)
Assert-Projection ($errors.Count -eq 0) 'The deployment helper does not parse.'
foreach($name in 'Set-DeploymentDiagnosticText','New-DeploymentOperationView','Get-DeploymentFailure'){
 $found=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
 Assert-Projection ($found.Count -eq 1) 'The required pure adapter helper is unavailable.'
 . ([scriptblock]::Create($found[0].Extent.Text))
}
$missing=Join-Path $FixtureDirectory ('NoSuchFile-'+[guid]::NewGuid().ToString('N')+'.txt')
Assert-Projection ($missing -match '^[A-Za-z]:\\' -and -not(Test-Path -LiteralPath $missing)) 'Projection fixture must be a nonexistent local file.'
$null=[Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime]
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$method=[System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object {$_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'}|Select-Object -First 1
Assert-Projection ($null -ne $method) 'The read-only WinRT task adapter is unavailable.'
$closed=$method.MakeGenericMethod([Windows.Storage.StorageFile]);$contract=$closed.GetParameters()[0].ParameterType
$operation=[Windows.Storage.StorageFile]::GetFileFromPathAsync($missing)
$view=New-DeploymentOperationView -Operation $operation -Contract $contract
$task=$closed.Invoke($null,@($operation));$original=$null
try{if(-not $task.Wait(10000)){$null=$view.Cancel();throw 'The read-only missing-file operation exceeded ten seconds.'}}catch{$original=$_.Exception.GetBaseException()}
Assert-Projection ($task.IsCompleted -and $task.IsFaulted -and $original.HResult -eq -2147024894) 'The missing-file task did not expose ERROR_FILE_NOT_FOUND.'
Assert-Projection ($view.Status.ToString() -eq 'Error' -and $view.ErrorCode.HResult -eq -2147024894) 'Projected IAsyncInfo lost its real native status or HRESULT.'
$resultError=$null
try{$null=$view.GetResults()}catch{$resultError=$_.Exception.GetBaseException()}
Assert-Projection ($resultError.HResult -eq -2147024894) 'Projected GetResults did not retain the native missing-file HRESULT.'
$record=[ordered]@{};$retained=Get-DeploymentFailure -Operation $view -OriginalError $original
Assert-Projection ([object]::ReferenceEquals($retained,$original) -and $record.DeploymentOperationStatus -eq 'Error' -and $record.DeploymentOperationHResult -eq -2147024894 -and [bool]$record.DeploymentDiagnosticError) 'A throwing StorageFile GetResults replaced the original failure.'
Assert-Projection (-not(Test-Path -LiteralPath $missing)) 'The read-only probe created its missing-file fixture.'
$directStatus=$null;try{$directStatus=[string]$operation.Status}catch{}
# Inspect projected metadata only; never construct or call a real PackageManager.
$packageType=[Windows.Management.Deployment.PackageManager,Windows.Management.Deployment,ContentType=WindowsRuntime]
$registerMethods=@($packageType.GetMethods()|Where-Object {$_.Name -eq 'RegisterPackageByFullNameAsync' -and $_.GetParameters().Count -eq 3})
Assert-Projection ($registerMethods.Count -eq 1) 'The three-argument staged registration contract is unavailable.'
$parameters=$registerMethods[0].GetParameters();$returnType=$registerMethods[0].ReturnType
Assert-Projection ($parameters[0].ParameterType -eq [string] -and $parameters[1].ParameterType -eq [Collections.Generic.IEnumerable[string]] -and $parameters[2].ParameterType.FullName -ceq 'Windows.Management.Deployment.DeploymentOptions' -and $returnType.Name -ceq 'IAsyncOperationWithProgress`2' -and $returnType.GetGenericArguments()[0].FullName -ceq 'Windows.Management.Deployment.DeploymentResult' -and $returnType.GetGenericArguments()[1].FullName -ceq 'Windows.Management.Deployment.DeploymentProgress') 'Staged registration argument or progress-result metadata differs from its documented contract.'
$registrationCalls=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'RegisterPackageByFullNameAsync'},$true))
Assert-Projection ($registrationCalls.Count -eq 2) 'Both management and standard-user registration must use the staged full-name contract.'
$registrationState=@{Calls=0};$ExpectedPackageFullName='Known.RuntimeFixture_1.2.3.4_x64__0123456789abc'
$manager=[pscustomobject]@{}
$manager|Add-Member ScriptMethod RegisterPackageByFullNameAsync {
 param([string]$FullName,[object]$Dependencies,[object]$Options)
 Assert-Projection ($FullName -ceq 'Known.RuntimeFixture_1.2.3.4_x64__0123456789abc' -and $Dependencies -is [string[]] -and $Dependencies.Count -eq 0 -and $Options.GetType().FullName -ceq 'Windows.Management.Deployment.DeploymentOptions' -and [int]$Options -eq 0) 'A registration call changed the exact identity, typed empty dependencies, or None options.'
 $registrationState.Calls++;return [pscustomobject]@{FixtureOperation='No deployment'}
}
foreach($call in $registrationCalls){$fakeResult=& ([scriptblock]::Create($call.Extent.Text));Assert-Projection ($fakeResult.FixtureOperation -ceq 'No deployment') 'The fake registration result was lost.'}
Assert-Projection ($registrationState.Calls -eq 2) 'Both exact production registration expressions were not exercised against the fake.'
[ordered]@{Status='Passed';PowerShellVersion=$PSVersionTable.PSVersion.ToString();OperationType=$operation.GetType().FullName;DirectStatusAccessible=[bool]$directStatus;ProjectedStatus=$view.Status.ToString();ProjectedHResult=$view.ErrorCode.HResult;GetResultsHResult=$resultError.HResult;OriginalCausePreserved=$true;MissingFileRemainsAbsent=$true;StagedRegistrationMetadataVerified=$true;FakeRegistrationCalls=$registrationState.Calls;DeploymentPerformed=$false}|ConvertTo-Json|Set-Content -LiteralPath $ResultPath -Encoding utf8
'@
    [IO.File]::WriteAllText($projectionProbe,$projectionSource,[Text.UTF8Encoding]::new($false))
    $packageAsset=Join-Path $repo 'scripts/ExecutableAnalysis/WindowsGuestPackage.ps1'
    if($PSVersionTable.PSEdition -eq 'Desktop'){
        & $projectionProbe -PackageAsset $packageAsset -FixtureDirectory $TestRoot -ResultPath $projectionResult
    }else{
        $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'))
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$projectionProbe,'-PackageAsset',$packageAsset,'-FixtureDirectory',$TestRoot,'-ResultPath',$projectionResult)){$info.ArgumentList.Add($argument)}
        $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
        try{
            Assert-True $process.Start() 'The Windows PowerShell read-only projection fixture did not start.';$started=$true
            $outputTask=$process.StandardOutput.ReadToEndAsync();$errorTask=$process.StandardError.ReadToEndAsync()
            Assert-True $process.WaitForExit(30000) 'The read-only projection fixture exceeded its 30-second process limit.'
            $output=$outputTask.GetAwaiter().GetResult();$errorOutput=$errorTask.GetAwaiter().GetResult()
            Assert-True ($output.Length+$errorOutput.Length -le 65536) 'Projection fixture output exceeded its cap.'
            [IO.File]::WriteAllText((Join-Path $TestRoot 'winrt-projection-child.log'),$output+$errorOutput)
            Assert-True ($process.ExitCode -eq 0) 'The Windows PowerShell projection fixture failed; inspect its retained bounded log.'
        }finally{if($started -and -not $process.HasExited){$process.Kill();$null=$process.WaitForExit(5000)};$process.Dispose()}
    }
    $projection=Get-Content -LiteralPath $projectionResult -Raw|ConvertFrom-Json
    Assert-True ($projection.Status -eq 'Passed' -and $projection.PowerShellVersion -like '5.1.*' -and $projection.ProjectedHResult -eq -2147024894 -and $projection.GetResultsHResult -eq -2147024894 -and $projection.OriginalCausePreserved -and $projection.MissingFileRemainsAbsent -and $projection.StagedRegistrationMetadataVerified -and $projection.FakeRegistrationCalls -eq 2 -and -not $projection.DeploymentPerformed) 'The actual guest-runtime projection proof is incomplete.'
    Write-Output 'PASS: typed fake progress results/cancellation and real PS5.1 missing-file WinRT projection preserve status/native errors without raw COM members or deployment.'
    $original=[Runtime.InteropServices.COMException]::new('Known original deployment cause.',-2147467259)
    $wrapped=[AggregateException]::new('Known task wrapper.',[Exception[]]@($original))
    $extended=[Runtime.InteropServices.COMException]::new('Known richer native detail.',-2147024891)
    $activity=[guid]'12345678-1234-1234-1234-123456789abc'
    function New-FixtureDeploymentOperation {
        param([string]$Status='Error',[object]$Details,[switch]$ThrowDetails)
        $state=@{Calls=0;Details=$Details;ThrowDetails=[bool]$ThrowDetails}
        $operation=[pscustomobject]@{Status=$Status;ErrorCode=[Runtime.InteropServices.COMException]::new('Known operation error.',-2147418113);FixtureState=$state}
        $operation|Add-Member ScriptMethod GetResults {$state.Calls++;if($state.ThrowDetails){throw [InvalidOperationException]::new(('Diagnostic failure '+('D'*20000)))};return $state.Details}.GetNewClosure()
        return $operation
    }
    $details=[pscustomobject]@{ActivityId=$activity;ErrorText=('Known deployment text '+('E'*20000));ExtendedErrorCode=$extended}
    $record=[ordered]@{};$operation=New-FixtureDeploymentOperation -Details $details
    $failure=Get-DeploymentFailure -Operation $operation -OriginalError $wrapped
    Assert-True ($operation.FixtureState.Calls -eq 1 -and $failure -is [Runtime.InteropServices.COMException] -and $failure.HResult -eq $extended.HResult) 'Faulted deployment did not retrieve its detailed native result and HRESULT.'
    Assert-True ($record.DeploymentActivityId -eq $activity.ToString() -and $record.DeploymentExtendedHResult -eq $extended.HResult -and $record.DeploymentOperationHResult -eq $operation.ErrorCode.HResult -and $record.DeploymentOperationStatus -eq 'Error') 'Deployment identity or native error provenance was lost.'
    Assert-True ($record.DeploymentErrorText.Length -eq 16384 -and $failure.Message.Length -le 16420 -and $record.DeploymentErrorText -ceq $details.ErrorText.Substring(0,16384) -and $record.DeploymentErrorTextTruncated -eq $true) 'Deployment error text exceeded its exact bound, lost truncation proof or changed known bytes.'
    foreach($state in 'Started','Completed','Canceled'){
        $record=[ordered]@{};$operation=New-FixtureDeploymentOperation -Status $state -ThrowDetails
        $failure=Get-DeploymentFailure -Operation $operation -OriginalError $wrapped
        Assert-True ([object]::ReferenceEquals($failure,$original) -and $operation.FixtureState.Calls -eq 0 -and $record.DeploymentOperationStatus -eq $state) 'A non-error operation queried unavailable results or replaced the original cause.'
    }
    $record=[ordered]@{};$operation=New-FixtureDeploymentOperation -ThrowDetails
    $failure=Get-DeploymentFailure -Operation $operation -OriginalError $wrapped
    Assert-True ([object]::ReferenceEquals($failure,$original) -and $record.DeploymentDiagnosticError.StartsWith('Diagnostic failure ')) 'A failing diagnostic replaced the original task failure.'
    if($record.DeploymentDiagnosticError.Length -gt 16384 -or $record.DeploymentDiagnosticErrorTruncated -ne $true){$deploymentRegressions.Add('native diagnostic error text lacks its bound or truncation proof')}
    $record=[ordered]@{};$operation=New-FixtureDeploymentOperation -Details ([pscustomobject]@{ActivityId=$activity;ErrorText='';ExtendedErrorCode=$extended})
    $failure=Get-DeploymentFailure -Operation $operation -OriginalError $wrapped
    Assert-True ($record.DeploymentExtendedHResult -eq $extended.HResult -and $record.DeploymentActivityId -eq $activity.ToString()) 'Empty diagnostic text discarded available native metadata.'
    if($failure.HResult -ne $extended.HResult){$deploymentRegressions.Add('empty ErrorText discards the richer extended HRESULT')}
    Assert-True ($record.DeploymentErrorText -ceq '' -and $record.DeploymentErrorTextTruncated -eq $false) 'An empty original ErrorText was misrepresented.'
    $record=[ordered]@{};$longExtended=[Runtime.InteropServices.COMException]::new(('Known extended fallback '+('F'*20000)),$extended.HResult)
    $operation=New-FixtureDeploymentOperation -Details ([pscustomobject]@{ActivityId=$activity;ErrorText='';ExtendedErrorCode=$longExtended})
    $failure=Get-DeploymentFailure -Operation $operation -OriginalError $wrapped
    Assert-True ($failure.HResult -eq $extended.HResult -and $failure.Message.Length -le 16420 -and $record.DeploymentExtendedErrorText.Length -eq 16384 -and $record.DeploymentExtendedErrorTextTruncated -eq $true) 'Empty ErrorText bypassed the bounded native-message fallback.'
    $record=[ordered]@{};$operation=New-FixtureDeploymentOperation -Details ([pscustomobject]@{ActivityId=$activity;ErrorText='Known text without an extended error.';ExtendedErrorCode=$null})
    $failure=Get-DeploymentFailure -Operation $operation -OriginalError $wrapped
    Assert-True ($failure.HResult -eq $original.HResult -and $record.DeploymentErrorText -ceq 'Known text without an extended error.') 'Missing extended error replaced the original HRESULT.'

    $waitDefinition=$packageAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-DeploymentOperation'},$true)
    $resultClause=@($waitDefinition.Body.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text -match '^if\s*\(\$result\.ExtendedErrorCode'})
    Assert-True ($resultClause.Count -eq 1) 'The returned-result failure clause is missing.'
    $record=[ordered]@{};$result=$details;$returnedFailure=$null
    try{& ([scriptblock]::Create($resultClause[0].Extent.Text))}catch{$returnedFailure=$_.Exception.GetBaseException()}
    Assert-True ($returnedFailure.HResult -eq $extended.HResult) 'A returned deployment error lost its HRESULT.'
    if($record.DeploymentErrorText.Length -gt 16384 -or $record.DeploymentErrorTextTruncated -ne $true){$deploymentRegressions.Add('returned deployment result text lacks its bound or truncation proof')}

    $entryTry=@($packageAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
    Assert-True ($entryTry.Count -eq 1 -and $entryTry[0].CatchClauses.Count -eq 1) 'The package diagnostic catch structure changed.'
    $body=$entryTry[0].CatchClauses[0].Body.Extent.Text
    $diagnostics=[scriptblock]::Create($body.Substring(1,$body.Length-2))
    $root='C:\ProfileAnalysis\Work\Application';$allowedAclPaths=@($root,'C:\ProfileAnalysis\Work','C:\ProfileAnalysis')
    function Get-WinEvent {
        param([hashtable]$FilterHashtable,[int]$MaxEvents,[string]$ErrorAction)
        $script:fixtureEventCalls++
        Assert-True ($FilterHashtable.LogName -ceq 'Microsoft-Windows-AppXDeploymentServer/Operational' -and $MaxEvents -eq 64 -and $FilterHashtable.StartTime -eq ([datetime]::Parse($record.StartedUtc)).AddSeconds(-2)) 'Event diagnostics lost their exact channel/time/count bounds.'
        if($diagnosticMode -eq 'failed-readers'){throw [InvalidOperationException]::new(('Known event reader failure '+('V'*20000)))}
        foreach($index in 0..63){[pscustomobject]@{Id=$index;TimeCreated=[datetime]::UtcNow;ActivityId=if($index%2 -eq 0){$activity}else{[guid]'87654321-4321-4321-4321-cba987654321'};LevelDisplayName='Error';Message=('Known event '+('M'*5000))}}
    }
    function Get-Acl {
        param([string]$LiteralPath,[string]$ErrorAction)
        $script:fixtureAclCalls++
        Assert-True ($LiteralPath -cin $allowedAclPaths) 'Permissions diagnostics queried an unrelated path.'
        if($diagnosticMode -eq 'failed-readers'){throw [InvalidOperationException]::new(('Known ACL reader failure '+('A'*20000)))}
        return [pscustomobject]@{Owner=('O'*20000);Sddl=('S'*70000)}
    }
    $successPermissions=@($modeBranch.Clauses[0].Item2.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text.Contains('Get-DeploymentPathPermission')})
    Assert-True ($successPermissions.Count -eq 1) 'Successful deployment lost its bounded permissions observation.'
    $observeSuccessPermissions=[scriptblock]::Create($successPermissions[0].Extent.Text)
    foreach($diagnosticMode in 'successful-readers','failed-readers'){
        $record=[ordered]@{Status='Completed'};$script:fixtureAclCalls=0
        & $observeSuccessPermissions
        Assert-True ($record.Status -ceq 'Completed') 'Auxiliary permission diagnostics changed successful deployment status.'
        if($diagnosticMode -eq 'failed-readers'){
            Assert-True ($script:fixtureAclCalls -eq 1 -and $record.DeploymentPermissionsError.Length -eq 16384 -and $record.DeploymentPermissionsError.StartsWith('Known ACL reader failure') -and $record.DeploymentPermissionsErrorTruncated -eq $true) 'Successful deployment did not retain bounded permission-reader failure evidence.'
        }else{
            Assert-True ($script:fixtureAclCalls -eq 3 -and @($record.DeploymentPathPermissions).Count -eq 3) 'Successful deployment did not inspect exactly the three fixed permission paths.'
            foreach($permission in $record.DeploymentPathPermissions){Assert-True ($permission.Path -cin $allowedAclPaths -and $permission.Owner -ceq ('O'*16384) -and $permission.Sddl -ceq ('S'*65536) -and $permission.OwnerTruncated -eq $true -and $permission.SddlTruncated -eq $true) 'The shared permission helper lost its exact prefixes or truncation bounds.'}
        }
    }
    foreach($diagnosticMode in 'matched-activity','unknown-activity','failed-readers'){
        $record=[ordered]@{StartedUtc=[datetime]::UtcNow.ToString('o');DeploymentActivityId=if($diagnosticMode -eq 'unknown-activity'){$null}else{$activity.ToString()};Error=$null;HResult=$null}
        $script:fixtureEventCalls=0;$script:fixtureAclCalls=0;$diagnosticFailure=$null
        try{try{throw $wrapped}catch{& $diagnostics}}catch{$diagnosticFailure=$_.Exception.GetBaseException()}
        Assert-True ([object]::ReferenceEquals($diagnosticFailure,$original) -and $record.Error -eq $original.Message -and $record.HResult -eq $original.HResult -and $script:fixtureEventCalls -eq 1) 'Secondary diagnostics replaced the original failure or repeated event collection.'
        if($diagnosticMode -eq 'failed-readers'){
            Assert-True ($record.DeploymentEventsError.StartsWith('Known event reader failure') -and $record.DeploymentPermissionsError.StartsWith('Known ACL reader failure')) 'Diagnostic-reader failures were concealed.'
            if($record.DeploymentEventsError.Length -gt 16384 -or $record.DeploymentPermissionsError.Length -gt 16384 -or $record.DeploymentEventsErrorTruncated -ne $true -or $record.DeploymentPermissionsErrorTruncated -ne $true){$deploymentRegressions.Add('event or ACL reader error text lacks its bound or truncation proof')}
        }else{
            $expectedCount=if($diagnosticMode -eq 'matched-activity'){32}else{64}
            Assert-True (@($record.DeploymentEvents).Count -eq $expectedCount -and @($record.DeploymentEvents|Where-Object {$_.Message.Length -ne 4096}).Count -eq 0 -and $script:fixtureAclCalls -eq 3) 'Event activity filtering, bounded messages or fixed ACL paths changed.'
            if($diagnosticMode -eq 'matched-activity'){Assert-True (@($record.DeploymentEvents|Where-Object ActivityId -NE $activity.ToString()).Count -eq 0) 'Unrelated event activity was attributed to the deployment.'}
            foreach($permission in $record.DeploymentPathPermissions){if($permission.Owner.Length -gt 16384 -or $permission.Sddl.Length -gt 65536 -or $permission.OwnerTruncated -ne $true -or $permission.SddlTruncated -ne $true){$deploymentRegressions.Add('ACL diagnostic text lacks bounded values or truncation proof');break}}
        }
    }
    $profileFailure=[Runtime.InteropServices.COMException]::new('Known native profile acquisition failure.',-2147024891)
    $profileProof=[pscustomobject]@{Status='CleanupFailed';UserSid='S-1-5-21-1-2-3-500';LoadedByThisRun=$true;PrivilegesRestored=$false;Released=$false}
    $profileFailure.Data['DeploymentProfileProof']=$profileProof
    $profileFailure.Data['DeploymentProfileCleanupError']='Known acquisition cleanup failure '+('C'*20000)
    $profileFailure.Data['PrivilegeRestorationErrors']='Known original privilege restore failure '+('P'*20000)
    $profileFailure.Data['UnrelatedPrivateFixture']='DO-NOT-SERIALIZE-EXCEPTION-DATA'
    $profileWrapped=[AggregateException]::new('Known acquisition wrapper.',[Exception[]]@($profileFailure))
    $record=[ordered]@{StartedUtc=[datetime]::UtcNow.ToString('o');Error=$null;HResult=$null};$diagnosticMode='unknown-activity'
    $script:fixtureEventCalls=0;$script:fixtureAclCalls=0;$retainedProfileFailure=$null
    try{try{throw $profileWrapped}catch{& $diagnostics}}catch{$retainedProfileFailure=$_.Exception.GetBaseException()}
    Assert-True ([object]::ReferenceEquals($retainedProfileFailure,$profileFailure) -and $record.Error -ceq $profileFailure.Message -and $record.HResult -eq $profileFailure.HResult) 'Acquisition cleanup diagnostics replaced the primary native failure.'
    Assert-True ($record.DeploymentProfileAcquisitionFailed -is [bool] -and $record.DeploymentProfileAcquisitionFailed -and $record.DeploymentProfile.Status -ceq 'CleanupFailed' -and $record.DeploymentProfile.UserSid -ceq $profileProof.UserSid -and $record.DeploymentProfile.LoadedByThisRun -and -not $record.DeploymentProfile.PrivilegesRestored -and -not $record.DeploymentProfile.Released) 'Failed acquisition lost its profile cleanup proof.'
    foreach($field in 'DeploymentProfileCleanupError','PrivilegeRestorationErrors'){
        Assert-True ($record[$field].Length -eq 16384 -and $record[$field] -ceq $profileFailure.Data[$field].Substring(0,16384) -and $record[$field+'Truncated'] -is [bool] -and $record[$field+'Truncated']) 'Acquisition cleanup text lost its bound, exact prefix, or truncation proof.'
    }
    $profileProof.Status='Changed original fixture after capture'
    Assert-True ($record.DeploymentProfile.Status -ceq 'CleanupFailed' -and -not [object]::ReferenceEquals($record.DeploymentProfile,$profileProof)) 'The acquisition report retained a mutable proof reference instead of a snapshot.'
    $serializedProfileFailure=$record|ConvertTo-Json -Depth 8
    Assert-True (-not $serializedProfileFailure.Contains('UnrelatedPrivateFixture') -and -not $serializedProfileFailure.Contains('DO-NOT-SERIALIZE-EXCEPTION-DATA')) 'Unrelated exception Data leaked into the deployment report.'
    Write-Output 'PASS: acquisition failure reports retain an independent profile proof and bounded known cleanup fields while preserving the native cause and excluding unrelated exception Data.'
    Write-Output 'PASS: extracted deployment diagnostics use fake WinRT results, bounded event readers and fixed ACL paths; secondary failures retain the original HRESULT without deployment or host inspection.'
    $controllerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/ExecutableAnalysis/WindowsGuestController.ps1'),[ref]$tokens,[ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'The controller does not parse.'
    $controllerTry=@($controllerAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.Finally})
    Assert-True ($controllerTry.Count -eq 1) 'The controller entry-point catch structure changed.'
    $controllerStatements=@($controllerTry[0].Body.Statements)
    $commandStart=@($controllerStatements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$command'})[0]
    $encodingEnd=@($controllerStatements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$encoded'})[0]
    $startIndex=[array]::IndexOf($controllerStatements,$commandStart);$endIndex=[array]::IndexOf($controllerStatements,$encodingEnd)
    Assert-True ($startIndex -ge 0 -and $endIndex -gt $startIndex) 'The fixed runner command encoding clauses changed.'
    $buildEncodedCommand=[scriptblock]::Create((($controllerStatements[$startIndex..$endIndex]|ForEach-Object {$_.Extent.Text}) -join "`n")+"`n"+'$encoded')
    $configuration=[pscustomobject]@{TimeoutSeconds=15;ExpectedSHA256=('A'*64);PayloadManifestSHA256=('B'*64);LaunchMode='RegisteredPackage';MaxProcessMemoryMB=128;MaxJobMemoryMB=256}
    $observation=[ordered]@{PackageDeployment=[pscustomobject]@{PackageFullName=$stagedFullName}}
    $encodedFixture=& $buildEncodedCommand
    $decodedFixture=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encodedFixture))
    $commandAst=[Management.Automation.Language.Parser]::ParseInput($decodedFixture,[ref]$tokens,[ref]$parseErrors)
    $runnerCommands=@($commandAst.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))
    Assert-True ($parseErrors.Count -eq 0 -and $runnerCommands.Count -eq 1 -and $runnerCommands[0].GetCommandName() -ceq 'C:\ProfileAnalysis\Runner.ps1') 'The encoded runner action introduced another command or changed its fixed target.'
    $fullNameArgument=@($runnerCommands[0].CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ExpectedPackageFullName'})
    Assert-True ($fullNameArgument.Count -eq 1) 'The encoded runner action lost its exact staged identity argument.'
    $argumentIndex=[array]::IndexOf(@($runnerCommands[0].CommandElements),$fullNameArgument[0])+1
    Assert-True ($runnerCommands[0].CommandElements[$argumentIndex] -is [Management.Automation.Language.StringConstantExpressionAst] -and $runnerCommands[0].CommandElements[$argumentIndex].Value -ceq $stagedFullName) 'The staged identity was not retained as one literal runner argument.'
    foreach($unsafeName in @("Known.Package';throw 'Injected'",'Known.Package;Injected','Known Package','Known/Package',"Known.Package`nInjected",'-BadPackage',('A'*257))){
        $observation.PackageDeployment.PackageFullName=$unsafeName
        Assert-Throws {& $buildEncodedCommand} 'cannot be passed safely'
    }
    $runnerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/ExecutableAnalysis/WindowsGuestRunner.ps1'),[ref]$tokens,[ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'The guest runner does not parse.'
    $runnerRegistration=@($runnerAst.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'C:\ProfileAnalysis\WindowsGuestPackage.ps1'},$true))
    Assert-True ($runnerRegistration.Count -eq 1) 'The runner registration handoff is missing or ambiguous.'
    $forwardedParameter=@($runnerRegistration[0].CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ExpectedPackageFullName'})
    Assert-True ($forwardedParameter.Count -eq 1) 'The runner does not forward its staged identity.'
    $forwardedIndex=[array]::IndexOf(@($runnerRegistration[0].CommandElements),$forwardedParameter[0])+1
    Assert-True ($runnerRegistration[0].CommandElements[$forwardedIndex] -is [Management.Automation.Language.VariableExpressionAst] -and $runnerRegistration[0].CommandElements[$forwardedIndex].VariablePath.UserPath -ceq 'ExpectedPackageFullName') 'The runner altered the staged identity before standard-user registration.'
    foreach($parameterAst in $runnerAst.ParamBlock,$packageAst.ParamBlock){
        $bindIdentity=[scriptblock]::Create($parameterAst.Extent.Text+"`n"+'$ExpectedPackageFullName')
        $parameters=if($parameterAst -eq $runnerAst.ParamBlock){@{ExpectedSHA256=('A'*64)}}else{@{Mode='Register';PayloadManifestSHA256=('B'*64)}}
        Assert-True ((& $bindIdentity @parameters -ExpectedPackageFullName $stagedFullName) -ceq $stagedFullName) 'An entry-point parameter binder changed the exact staged identity.'
        Assert-Throws {& $bindIdentity @parameters -ExpectedPackageFullName "Known.Package';Injected"} 'ExpectedPackageFullName'
    }
    Write-Output 'PASS: isolated controller encoding preserves one literal staged identity, rejects unsafe names, and both entry-point binders plus the runner AST retain the exact registration handoff without launching tasks.'
    $cleanupTry=@($controllerTry[0].Finally.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst] -and $_.CatchClauses.Count -eq 1})
    Assert-True ($cleanupTry.Count -eq 1) 'The controller cleanup catch structure changed.'
    # Preserve the real catch boundary so a bare rethrow retains its native cause.
    $cleanupCatch=[scriptblock]::Create('try { throw $cleanupError } '+$cleanupTry[0].CatchClauses[0].Extent.Text)
    $cleanupError=[Runtime.InteropServices.COMException]::new('Known cleanup failure.',-2147024864)
    foreach($hasPrimary in $true,$false){
        $observation=[ordered]@{Error=if($hasPrimary){$original.Message}else{$null};HResult=if($hasPrimary){$original.HResult}else{$null};CleanupError=$null;CleanupHResult=$null}
        $caughtCleanup=$null
        try{& $cleanupCatch}catch{$caughtCleanup=$_.Exception.GetBaseException()}
        Assert-True ($observation.CleanupError -ceq $cleanupError.Message -and $observation.CleanupHResult -eq $cleanupError.HResult) 'Controller cleanup lost its separate diagnostic.'
        if($hasPrimary){Assert-True ($null -eq $caughtCleanup -and $observation.Error -ceq $original.Message -and $observation.HResult -eq $original.HResult) 'Controller cleanup masked the primary failure.'}
        else{Assert-True ([object]::ReferenceEquals($caughtCleanup,$cleanupError) -and $observation.Error -ceq $cleanupError.Message -and $observation.HResult -eq $cleanupError.HResult) 'A standalone controller cleanup failure was hidden.'}
    }
    Write-Output 'PASS: isolated controller cleanup catches preserve the primary native cause and retain cleanup errors separately without any task or native calls.'
}

# Extract only the watchdog function and common read-only validators. The actual
# script entry point and VBox process wrapper are never invoked by these tests.
$watchdogAsset=Join-Path $repo 'scripts/ExecutableAnalysis/WindowsVm.Watchdog.ps1'
$watchdogAst=[Management.Automation.Language.Parser]::ParseFile($watchdogAsset,[ref]$tokens,[ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'The watchdog does not parse.'
$watchdogFunction=$watchdogAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-AnalysisWindowsWatchdog'},$true)
. ([scriptblock]::Create($watchdogFunction.Extent.Text))
$commonAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts/ExecutableAnalysis/WindowsVm.Common.ps1'),[ref]$tokens,[ref]$parseErrors)
foreach($name in 'ConvertFrom-AnalysisWindowsVmInfo','Assert-AnalysisWindowsVmIsolation'){
    $definition=$commonAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$fixtureStorage=Join-Path $TestRoot 'watchdog-fixtures';$null=[IO.Directory]::CreateDirectory($fixtureStorage)
$fixtureUuid='11111111-2222-3333-4444-555555555555';$fixtureManifest=Join-Path $fixtureStorage 'manifest.json'
@{Schema='PowerShellProfile.AnalysisWindowsVm.v1';GuestOS='Windows 11 x64';Status='Ready';VirtualMachineId=$fixtureUuid;VirtualMachineName='Fixture-Only';StoragePath=$fixtureStorage}|ConvertTo-Json|Set-Content -LiteralPath $fixtureManifest -Encoding utf8
function Invoke-AnalysisWindowsVBox {
    param([string[]]$ArgumentList,[int]$TimeoutSeconds,[int]$MaxOutputCharacters)
    $null=$script:watchdogCalls.Add([pscustomobject]@{Arguments=$ArgumentList;Timeout=$TimeoutSeconds;OutputLimit=$MaxOutputCharacters})
    if($ArgumentList[1] -ne $fixtureUuid -or $TimeoutSeconds -ne 15){throw 'Unsafe mock VM identity or command timeout.'}
    if($ArgumentList[0] -eq 'getextradata'){return ('Value: '+$fixtureManifest)}
    if($ArgumentList[0] -eq 'controlvm'){
        if($ArgumentList.Count -ne 3 -or $ArgumentList[2] -ne 'poweroff'){throw 'Unexpected mutation in watchdog.'}
        $script:watchdogState='poweroff';return ''
    }
    if($ArgumentList[0] -ne 'showvminfo'){throw 'Unexpected watchdog command.'}
    $script:watchdogShows++
    $values=@{UUID=$fixtureUuid;name='Fixture-Only';VMState=$script:watchdogState;clipboard='disabled';draganddrop='disabled';clipboard_file_transfers='off';'SATA-0-0'=(Join-Path $fixtureStorage 'fixture.vdi')}
    foreach($key in 'usb','ehci','xhci','vrde','audio_in','audio_out','nested-hw-virt','teleporterenabled'){$values[$key]='off'}
    foreach($index in 1..8){$values['nic'+$index]='none'}
    foreach($index in 1..4){$values['uart'+$index]='off'}
    if($script:watchdogCase -eq 'wrong-uuid' -and $script:watchdogShows -gt 1){$values.UUID='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'}
    if($script:watchdogCase -eq 'unexpected-state' -and $script:watchdogShows -gt 1){$values.VMState='saved'}
    return (($values.Keys|ForEach-Object {'{0}="{1}"' -f $_,$values[$_]}) -join "`n")
}
function Start-Sleep {
    param([int]$Milliseconds)
    if($script:watchdogCase -in 'cancel','bad-cancel' -and -not(Test-Path -LiteralPath (Join-Path $script:watchdogEvidence 'cancel.json'))){
        $ready=Get-Content -LiteralPath (Join-Path $script:watchdogEvidence 'ready.json') -Raw|ConvertFrom-Json
        $cancelId=if($script:watchdogCase -eq 'cancel'){$ready.WatchdogId}else{'wrong-run'}
        @{Cancel=$true;BoundUUID=$fixtureUuid;WatchdogId=$cancelId}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $script:watchdogEvidence 'cancel.json') -Encoding utf8
    }
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds
}
foreach($case in 'cancel','expire-running','expire-paused','wrong-uuid','unexpected-state','bad-cancel'){
    $script:watchdogCase=$case;$script:watchdogState=if($case -eq 'expire-paused'){'paused'}else{'running'};$script:watchdogShows=0
    $script:watchdogCalls=New-Object 'Collections.Generic.List[object]'
    $script:watchdogEvidence=Join-Path $fixtureStorage $case
    $result=Invoke-AnalysisWindowsWatchdog -VirtualMachineId $fixtureUuid -OwnershipManifestPath $fixtureManifest -DeadlineSeconds 1 -EvidenceDirectory $script:watchdogEvidence
    $mutations=@($script:watchdogCalls|Where-Object {$_.Arguments[0] -eq 'controlvm'})
    if($case -eq 'cancel'){Assert-True ($result.Status -eq 'Cancelled' -and $mutations.Count -eq 0) 'Cancellation mutated the VM or did not match its run.'}
    elseif($case -in 'wrong-uuid','unexpected-state'){Assert-True ($result.Status -eq 'Failed' -and $mutations.Count -eq 0) 'Changed identity or unexpected state authorized a VM mutation.'}
    else{Assert-True ($result.Status -eq 'Expired' -and $result.PowerOffVerified -and $mutations.Count -eq 1) ('The expiry path did not power off exactly its fixture: '+$case)}
    if($case -eq 'bad-cancel'){Assert-True $result.CancellationRejected 'An invalid marker did not preserve the deadline.'}
    Assert-True (Test-Path -LiteralPath (Join-Path $script:watchdogEvidence 'result.json')) 'The watchdog lost its final evidence.'
}
Write-Output 'PASS: mocked watchdog cancels only matching runs, expires running/paused fixtures, ignores invalid cancellation, and refuses changed identity or unexpected state without any real VM calls.'
Assert-True ($deploymentRegressions.Count -eq 0) ('Deployment diagnostic regressions: '+(@($deploymentRegressions|Select-Object -Unique) -join '; '))
Write-Output 'PASS: all deployment-result/error/ACL text budgets and richer HRESULT preservation checks passed.'
