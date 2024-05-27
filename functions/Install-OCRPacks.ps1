function Install-EveryOCRPack {
    [CmdletBinding()]
    param (
        
    )
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        $Capability = Get-WindowsCapability -Online | Where-Object { $_.Name -Like 'Language.OCR*' }
        $Capability | Add-WindowsCapability -Online
    }
    else {
        throw 'This function requires windows powershell'
    }
}