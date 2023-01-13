function Update-WSL {
    [CmdletBinding()]
    param (
        
    )
    wsl --update
    # This function will enumerate all WSL distributions and upgrade them (if necessary). Taking into account the different syntax required for each distro.
    $DistributionSearched = WSL
    $DistributionSearched | ForEach-Object {
        $DistributionName = $_.DistributionName
        $DistributionVersion = $_.Version
        $DistributionState = $_.State
        Write-Output "[$($DistributionName)] Version: $($DistributionVersion) - Status: $($DistributionState)"
        if ($DistributionState -eq 'Stopped') {
            Write-Output "[$($DistributionName)] Starting..."
            Start-WindowsSubSystem -Name $DistributionName
            Write-Output "[$($DistributionName)] Started!"
        }
        if (($DistributionName -like '*Ubuntu*') -or ($DistributionName -like '*Debian*') -or ($DistributionName -like '*kali*')) {
            Write-Output "[$($DistributionName)] Updating..."
            wsl --exec 'apt update && apt dist-upgrade -y && apt autoremove -y && apt clean' -d $DistributionName -u root
            Write-Output "[$($DistributionName)] Updated!"
        }
        elseif (($DistributionName -like '*openSUSE*') -or ($DistributionName -like '*sles*')) {
            Write-Output "[$($DistributionName)] Updating..."
            wsl --exec zypper refresh
            wsl --exec zypper update
            Write-Output "[$($DistributionName)] Updated!"
        }
        elseif ($DistributionName -like '*Arch*') {
            Write-Output "[$($DistributionName)] Updating..."
            wsl --exec pacman -Sy
            wsl --exec pacman --noconfirm
        }
        elseif ($DistributionName -like '*fedora*') {
            Write-Output "[$($DistributionName)] Updating..."
            wsl --exec dnf update --assumeyes --refresh
            Write-Output "[$($DistributionName)] Updated!"
        }
        else {
            Write-Warning "[$($DistributionName)] This distribution is not supported for WSL Update functionality!"
        }
    }
}