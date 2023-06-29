<#
.SYNOPSIS
    Short description
.DESCRIPTION
    Long description
.EXAMPLE
    Example of how to use this cmdlet
.EXAMPLE
    Another example of how to use this cmdlet
#>
function Update-Windows {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string[]]
        $ComputerName = $ENV:COMPUTERNAME
    )
    $XWAYSUSB = (Get-CimInstance -ClassName Win32_Volume -Filter "Label LIKE 'X-Ways%'").DriveLetter
    # install the powershell module kbupdate if it is not already installed
    if (-not (Get-Module -Name kbupdate -ListAvailable)) {
        Install-Module -Name kbupdate -Scope CurrentUser -Force
    }
    # Import the module
    Import-Module -Name kbupdate -Force

    # Create the paths if they don't exist
    if (-not (Test-Path -Path "$XWAYSUSB\windowsupdates")) {
        New-Item -Path "$XWAYSUSB\windowsupdates" -ItemType Directory
    }

    $since = [DateTime]::Now.AddMonths(-12)
    Get-KbUpdate -Architecture x64 -Since $since | Save-KbUpdate -Path "$XWAYSUSB\windowsupdates" -Verbose

    # Download Windows Update offline scan file
    Save-KbScanFile -Path "$XWAYSUSB\windowsupdates" -Verbose

    ### 💿💿💿         BURN TO DVD         💿💿💿 ###
    ### 🏃🏃🏃 TRANSFER TO OFFLINE NETWORK 🏃🏃🏃 ###

    # Tell Install-KbUpdate to check for all needed updates
    # and point the RepositoryPath to a network server. The
    # servers will grab what they need.

    $params = @{
        ComputerName   = $ComputerName
        AllNeeded      = $true
        ScanFilePath   = "$XWAYSUSB\windowsupdates\wsusscn2.cab"
        RepositoryPath = "$XWAYSUSB\windowsupdates\"
    }
    Install-KbUpdate @params
}

# Update-Windows -Verbose