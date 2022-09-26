function Update-PSProfile {
    [CmdletBinding()]
    param (
        $Global:parentpathprofile = $($(Resolve-Path -Path $Profile) -split 'Microsoft.PowerShell_profile.ps1')[0]  
    )    
    if (-not(Test-Path $PROFILE)) {
        New-Item $PROFILE -Force
        $sourcefolder = "$($(Get-Volume -FriendlyName 'X-Ways*').DriveLetter)`:\Projects\Powershell-Profile\*"
        Copy-Item -Path $sourcefolder -Recurse -Container -Destination $parentpathprofile -Force          
    }
    try {    
        Set-Location -Path $parentpathprofile
        git fetch --all; 
        $NAMEOFHEAD = $(git symbolic-ref refs/remotes/origin/HEAD); 
        git reset --hard origin/$($NAMEOFHEAD.split('/')[-1]); 

    } catch {
        $sourcefolder = "$($(Get-Volume -FriendlyName 'X-Ways*').DriveLetter)`:\Projects\Powershell-Profile\*"
        Copy-Item -Path $sourcefolder -Recurse -Container -Destination $parentpathprofile -Force
        Write-Error -Message "$_"
    } finally {
        # Import all functions from functions folder
        $FunctionsFolder = Get-ChildItem -Path "$parentpathprofile/functions/*.ps*" -Recurse
        $FunctionsFolder.ForEach{ Import-Module $_.FullName }
        # Make sure chocolatey is correct path
        $ENV:ChocolateyInstall = "$($(Get-Volume -FriendlyName 'X-Ways*').DriveLetter)`:\chocolatey apps\chocolatey\bin\"
        
    }
}