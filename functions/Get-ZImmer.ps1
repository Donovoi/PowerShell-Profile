# Function to download the latest Zimmerman Tools and put them in path with chocolatey bins.
# Also updates kape & bins
function Get-Zimmer {
    [CmdletBinding()]
    param (
        
    )
    
    Remove-Item $("(Get-CimInstance -ClassName Win32_Volume -Filter `"Label LIKE 'X-Ways%'`").DriveLetter" + "\Triage\KAPE\Modules\bin\ZimmermanTools\") -Recurse -Force -ea silentlycontinue
    Remove-Item $("(Get-CimInstance -ClassName Win32_Volume -Filter `"Label LIKE 'X-Ways%'`").DriveLetter" + "\Triage\KAPE\Modules\bin\Get-ZimmermanTools.ps1") -ea silentlycontinue
    
    Start-Process pwsh -ArgumentList "-NoProfile -ExecutionPolicy unrestricted -Command `". `$(`"(Get-CimInstance -ClassName Win32_Volume -Filter `"Label LIKE 'X-Ways%'`").DriveLetter`" + `"\Triage\KAPE\KAPE-EZToolsAncillaryUpdater.ps1 -netVersion 6)`"`""
    $ProgressPreference = 'SilentlyContinue'
    $Global:ENV:ChocolateyInstall = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\chocolatey apps\chocolatey\bin"
    Invoke-WebRequest -Uri 'https://f001.backblazeb2.com/file/EricZimmermanTools/net6/All_6.zip' -OutFile $(RESOLVE-PATH -Verbose  -Path $(Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter" + "\ZimmermanTools.zip")) -Verbose 
    Expand-Archive -Path (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\ZimmermanTools.zip" -DestinationPath (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\ZimmermanTools" -Force
    # We now have a a folder with many zip files in it. We need to extract each one to the same folder "$ENV:TEMP\extracted" .
    Get-ChildItem -Path (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\ZimmermanTools" -Filter *.zip -File | ForEach-Object -Process { 
        Expand-Archive -Path $_.FullName -DestinationPath (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\ZimmermanTools\extracted" -Force
    }
    # Now we have a folder with all the zimmerman tools in it. We need to copy them to the $ENV:ChocolateyInstall folder, but just the binaries and their dependencies.
    Get-ChildItem -Path (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter + "\ZimmermanTools\extracted" -Recurse | ForEach-Object -Process { 
        Copy-Item -Path $_.FullName -Destination $Global:ENV:ChocolateyInstall -Force
    }
}