#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new fixture directory.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
foreach($name in 'Initialize-CmdletDependencies','Invoke-Process','Get-GitPull'){. "$PSScriptRoot/../functions/$name.ps1"}
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Git([string]$Directory,[string[]]$Arguments){
    (Invoke-Process -FilePath git.exe -ArgumentList (@('-C',$Directory,'-c','user.name=Profile Fixture','-c','user.email=fixture@example.invalid','-c','commit.gpgsign=false','-c','core.autocrlf=false')+$Arguments) -PassThru).StandardOutput.Trim()
}
$seed=Join-Path $TestRoot seed
$upstream=Join-Path $TestRoot upstream.git
$origin=Join-Path $TestRoot origin.git
$checkout=Join-Path $TestRoot 'working [fixture]'
$null=Git $TestRoot @('init','--bare','--initial-branch=main',$upstream)
$null=Git $TestRoot @('init','--bare','--initial-branch=main',$origin)
$null=Git $TestRoot @('init','--initial-branch=main',$seed)
[IO.File]::WriteAllText("$seed/Cargo.toml",'tracked original')
[IO.File]::WriteAllText("$seed/lib.rs",'original rust')
[IO.File]::WriteAllText("$seed/staged.txt",'base index')
[IO.File]::WriteAllText("$seed/.gitignore","ignored.txt`n")
$null=Git $seed @('add','--all'); $null=Git $seed @('commit','-m','initial')
$initial=Git $seed @('rev-parse','HEAD')
$null=Git $seed @('remote','add','upstream',$upstream); $null=Git $seed @('remote','add','origin',$origin)
$null=Git $seed @('push','upstream','main'); $null=Git $seed @('push','origin','main')
$null=Git $TestRoot @('clone',$origin,$checkout)
$null=Git $checkout @('config','user.name','Profile Fixture'); $null=Git $checkout @('config','user.email','fixture@example.invalid')
$null=Git $checkout @('config','commit.gpgsign','false')
$null=Git $checkout @('remote','add','upstream',$upstream)
[IO.File]::WriteAllText("$seed/upstream.txt",'upstream one')
$null=Git $seed @('add','--all'); $null=Git $seed @('commit','-m','upstream change'); $null=Git $seed @('push','upstream','main')
$newHead=Git $seed @('rev-parse','HEAD')
[IO.File]::WriteAllText("$checkout/Cargo.toml",'tracked local edit')
[IO.File]::WriteAllText("$checkout/untracked.txt",'untracked local work')
[IO.File]::WriteAllText("$checkout/ignored.txt",'ignored work stays')
[IO.File]::WriteAllText("$checkout/staged.txt",'staged work')
$null=Git $checkout @('add','staged.txt')
[IO.File]::WriteAllText("$TestRoot/Cargo.toml",'caller sentinel')
$beforeStatus=Git $checkout @('status','--porcelain=v1','--untracked-files=all')
$location=Get-Location
Push-Location -LiteralPath $TestRoot
try {
    $plan=Get-GitPull -Path $checkout -Preview
    Assert ($plan.Result -eq 'Preview' -and $plan.TargetBranch -eq 'main' -and $plan.UpstreamCommit -eq $newHead -and $plan.CleanPreview -match 'untracked.txt') 'Preview omitted scope or destructive work'
    $whatif=Get-GitPull -Path $checkout -WhatIf
    Assert ($whatif.Result -eq 'Preview' -and (Git $checkout @('status','--porcelain=v1','--untracked-files=all')) -eq $beforeStatus -and (Git $checkout @('rev-parse','HEAD')) -eq $initial) 'Preview changed the repository'
    $result=Get-GitPull -Path $checkout -Confirm:$false
    Assert ($result.Result -eq 'Complete' -and (Git $checkout @('rev-parse','HEAD')) -eq $newHead -and (Git $origin @('rev-parse','main')) -eq $newHead) 'Reset/merge/push did not reach upstream'
    Assert ([IO.File]::ReadAllText("$checkout/Cargo.toml") -eq 'tracked original' -and [IO.File]::ReadAllText("$checkout/lib.rs") -eq 'original rust') 'Cargo sources damaged'
    Assert ([IO.File]::ReadAllText("$checkout/ignored.txt") -eq 'ignored work stays' -and [IO.File]::ReadAllText("$TestRoot/Cargo.toml") -eq 'caller sentinel') 'Ignored or caller files damaged'
    Assert ((Get-Location).Path -eq $TestRoot) 'Caller location changed'
    $recovery=Join-Path $TestRoot recovered
    $null=Git $checkout @('worktree','add','--detach',$recovery,($result.RecoveryRef+'/head'))
    $null=Git $recovery @('stash','apply','--index',($result.RecoveryRef+'/worktree'))
    Assert ([IO.File]::ReadAllText("$recovery/Cargo.toml") -eq 'tracked local edit' -and [IO.File]::ReadAllText("$recovery/untracked.txt") -eq 'untracked local work') 'Recovery refs could not restore the original work'
    Assert ((Git $recovery @('show',':staged.txt')) -eq 'staged work') 'Recovery lost staged index content'
    Write-Host 'PASS: preview/WhatIf, real reset/merge/push, exact recovery of dirty/untracked work, Cargo and ignored-file preservation'

    [IO.File]::WriteAllText("$seed/upstream.txt",'upstream two')
    $null=Git $seed @('add','--all'); $null=Git $seed @('commit','-m','upstream two'); $null=Git $seed @('push','upstream','main')
    $result=Get-GitPull -Path $checkout -NoPush -Confirm:$false
    Assert ((Git $origin @('rev-parse','main')) -eq $newHead -and [IO.File]::ReadAllText("$checkout/upstream.txt") -eq 'upstream two') 'NoPush changed origin or failed to merge'
    $originWriter=Join-Path $TestRoot 'origin writer'
    $null=Git $TestRoot @('clone',$origin,$originWriter)
    [IO.File]::WriteAllText("$originWriter/origin-only.txt",'independent remote work')
    $null=Git $originWriter @('add','--all'); $null=Git $originWriter @('commit','-m','origin diverged'); $null=Git $originWriter @('push','origin','main')
    $originDiverged=Git $origin @('rev-parse','main')
    $failed=$false; try { Get-GitPull -Path $checkout -Confirm:$false | Out-Null } catch { $failed=$_.Exception.Message -match 'rewrite origin history' }
    Assert ($failed -and (Git $origin @('rev-parse','main')) -eq $originDiverged) 'Divergent origin was rewritten'
    [IO.File]::WriteAllText("$seed/ignored.txt",'new tracked upstream file')
    $null=Git $seed @('add','-f','ignored.txt');$null=Git $seed @('commit','-m','track formerly ignored file');$null=Git $seed @('push','upstream','main')
    $failed=$false;try{Get-GitPull -Path $checkout -NoPush -Confirm:$false|Out-Null}catch{$failed=$true}
    Assert ($failed -and [IO.File]::ReadAllText("$checkout/ignored.txt") -eq 'ignored work stays') 'Merge overwrote an ignored local file'
    $null=Git $checkout @('update-index','--assume-unchanged','Cargo.toml')
    $failed=$false;try{Get-GitPull -Path $checkout -Preview|Out-Null}catch{$failed=$_.Exception.Message -match 'Assume-unchanged'}
    Assert $failed 'Assume-unchanged files were not guarded'
    $null=Git $checkout @('update-index','--no-assume-unchanged','Cargo.toml')
    Write-Host 'PASS: NoPush and non-fast-forward push refusal preserve origin'

    [IO.File]::WriteAllText("$checkout/pending.txt",'keep on remote failure')
    $null=Git $checkout @('remote','set-url','upstream',(Join-Path $TestRoot missing.git))
    $failed=$false; try { Get-GitPull -Path $checkout -Confirm:$false | Out-Null } catch { $failed=$true }
    Assert ($failed -and [IO.File]::ReadAllText("$checkout/pending.txt") -eq 'keep on remote failure') 'Remote failure discarded pending work'
    $null=Git $checkout @('remote','set-url','upstream',$upstream)
    [IO.File]::WriteAllText("$checkout/.git/index.lock",'fixture lock')
    $failed=$false; try { Get-GitPull -Path $checkout -Preview | Out-Null } catch { $failed=$_.Exception.Message -match 'lock' }
    Assert ($failed -and [IO.File]::Exists("$checkout/.git/index.lock")) 'Active lock was removed or ignored'
    Remove-Item -LiteralPath "$checkout/.git/index.lock"
    $null=Git $checkout @('checkout','--detach')
    $failed=$false; try { Get-GitPull -Path $checkout -Preview | Out-Null } catch { $failed=$_.Exception.Message -match 'Detached' }
    Assert $failed 'Detached HEAD was not refused'
    Write-Host 'PASS: failed remote, active lock and detached HEAD safeguards'

    $plain=Join-Path $TestRoot 'tracking checkout'
    $null=Git $TestRoot @('clone',$origin,$plain)
    [IO.File]::WriteAllText("$originWriter/next.txt",'next origin commit')
    $null=Git $originWriter @('add','--all');$null=Git $originWriter @('commit','-m','tracking update');$null=Git $originWriter @('push','origin','main')
    $trackingHead=Git $origin @('rev-parse','main')
    [IO.File]::WriteAllText("$plain/local-untracked.txt",'keep local work')
    $plan=Get-GitPull -Path $plain -Preview
    Assert ($plan.Mode -eq 'FastForward' -and -not $plan.PushTo) 'Tracking-only preview requested reset or push'
    $result=Get-GitPull -Path $plain -Confirm:$false
    Assert ($result.Result -eq 'Complete' -and (Git $plain @('rev-parse','HEAD')) -eq $trackingHead -and [IO.File]::ReadAllText("$plain/local-untracked.txt") -eq 'keep local work') 'Tracking-only fast-forward lost local work or failed'
    $null=Git $plain @('add','local-untracked.txt');$null=Git $plain @('commit','-m','local divergence')
    $divergentHead=Git $plain @('rev-parse','HEAD')
    [IO.File]::WriteAllText("$originWriter/next.txt",'divergent origin commit')
    $null=Git $originWriter @('add','--all');$null=Git $originWriter @('commit','-m','remote divergence');$null=Git $originWriter @('push','origin','main')
    $failed=$false;try{Get-GitPull -Path $plain -Confirm:$false|Out-Null}catch{$failed=$true}
    Assert ($failed -and (Git $plain @('rev-parse','HEAD')) -eq $divergentHead) 'Tracking-only divergence reset local commits'
    Write-Host 'PASS: tracking-only fast-forward, untracked preservation and divergence refusal'
}
finally { Pop-Location }
Assert ((Get-Location).Path -eq $location.Path) 'Test did not restore location'
