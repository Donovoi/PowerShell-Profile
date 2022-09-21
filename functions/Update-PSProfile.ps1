function Update-PSProfile {
    [CmdletBinding()]
    param (
        
    )
    # Import all functions from functions folder
    if (-not(Test-Path $PROFILE)) {
        New-Item $PROFILE -Force
        $Global:parentpathprofile = $($(Resolve-Path -Path $Profile) -split 'Microsoft.PowerShell_profile.ps1')[0]
    }
    try {    
        Set-Location -Path $parentpathprofile
        git fetch --all; 
        $NAMEOFHEAD = $(git symbolic-ref refs/remotes/origin/HEAD); 
        git reset --hard origin/$($NAMEOFHEAD.split('/')[-1]); 

    } catch {
        $sourcefolder = "$($(Get-Volume -FriendlyName 'X-Ways*').DriveLetter)`:\Projects\Powershell-Profile\9589627f7e8e70bee3497549a88070dc\*"
        Copy-Item -Path $sourcefolder -Recurse -Container -Destination $parentpathprofile -Force
    } finally {
        $FunctionsFolder = Get-ChildItem -Path "$parentpathprofile/functions/*.ps*" -Recurse
        $FunctionsFolder.ForEach{ Import-Module $_.FullName }
    }
}