Function Git-Pull {
    [cmdletbinding()]
    Param(

    )
    $ErrorActionPreference = 'Continue'
    $global:OriginalCommand = $MyInvocation.MyCommand
    # Import-Module $PSScriptRoot\Start-AsAdmin.ps1 -Force
    Start-AsAdmin -WindowsPowerShell -Verbose
    # Find all ein repositories in any directory on this drive, then perform ein pull on each one.
    $DriveLetter = Get-PSDrive | Where-Object { $_.Description -eq 'X-Ways Portable' } | Select-Object -Property root
    [System.IO.Directory]::EnumerateDirectories($DriveLetter.root, '.git', 'AllDirectories') | ForEach-Object -Verbose -Process { 
        $ErrorActionPreference = 'SilentlyContinue'
        $pathparent = $_ -split '.git'
        Write-Output "Pulling from $pathparent"
        Set-Location -Path $($pathparent)[0]
        git config --global --add safe.directory $(Resolve-Path .)
        # verbose ein fetch
        gix fetch #--all --verbose
        $NAMEOFHEAD = $(git symbolic-ref refs/remotes/origin/HEAD) 
        git reset --hard origin/$($NAMEOFHEAD.split('/')[-1]) 
        Write-Output "git pull complete for $($pathparent)[0]"
        [GC]::Collect()
        #ein pull --verbose; 
        #ein config --global --add safe.directory $(Resolve-Path .)
        #ein config --global --add safe.directory '*'
        #gh repo sync --force
    } 
}
