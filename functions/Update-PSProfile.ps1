function Update-PSProfile {
    [CmdletBinding()]
    param (
        $parentpathprofile = $(Get-Item $PROFILE).Directory.FullName
    )    
    Start-AsAdmin
    if (-not(Test-Path $PROFILE)) {
        New-Item $PROFILE -Force
        $sourcefolder = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\Projects\Powershell-Profile\*"
        Copy-Item -Path $sourcefolder -Recurse -Container -Destination $parentpathprofile -Force          
    }
    try {    
        Set-Location -Path $parentpathprofile
        git fetch --all; 
        $NAMEOFHEAD = $(git symbolic-ref refs/remotes/origin/HEAD); 
        git reset --hard origin/$($NAMEOFHEAD.split('/')[-1]); 

    }
    catch {
        $sourcefolder = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\Projects\Powershell-Profile\*"
        Copy-Item -Path $sourcefolder -Recurse -Container -Destination $parentpathprofile -Force
        Write-Error -Message "$_"
    }
    finally {
        # Clean up any bak files
        Get-ChildItem -Path $parentpathprofile -Filter *.bak -Recurse | Remove-Item -Force
        # Import all functions from functions folder
        $FunctionsFolder = Get-ChildItem -Path "$parentpathprofile/functions/*.ps*" -Recurse
        $FunctionsFolder.ForEach{ Import-Module $_.FullName }
        # Make sure chocolatey is correct path
        $ENV:ChocolateyInstall = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\chocolatey apps\chocolatey\bin\"
        
    }
}