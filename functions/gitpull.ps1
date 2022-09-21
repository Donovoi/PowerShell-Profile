Function Git-Pull {
    Import-Module $PSScriptRoot\Start-AsAdmin.ps1 -Force
    Start-AsAdmin -WindowsPowerShell -Verbose
    Write-Output $PSVersionTable
    # Find all git repositories in any directory on this drive, then perform git pull on each one.
    $DriveLetter = Get-PSDrive | Where-Object { $_.Description -eq 'X-Ways Portable' } | Select-Object -Property root
    [System.IO.Directory]::EnumerateDirectories($DriveLetter.root, '.git', 'AllDirectories') | ForEach-Object -Process { 
  
        $pathparent = $_ -split '.git'
        Set-Location -Path $($pathparent)[0]
        git fetch --all; 
        $NAMEOFHEAD = $(git symbolic-ref refs/remotes/origin/HEAD); 
        git reset --hard origin/$($NAMEOFHEAD.split('/')[-1]); 
        #git pull --verbose; 
        #git config --global --add safe.directory $(Resolve-Path .)
        #git config --global --add safe.directory '*'
        #gh repo sync --force
    } 
}
