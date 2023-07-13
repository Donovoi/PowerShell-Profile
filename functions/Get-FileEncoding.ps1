function Get-FileEncoding {
    param ([Parameter(Mandatory = $true)] [String] $Path)

    [byte[]] $byte = [System.IO.File]::ReadAllBytes($Path)

    if ($byte[0] -eq 0x2b -and $byte[1] -eq 0x2f -and $byte[2] -eq 0x76) {
        return New-Object System.Text.UTF7Encoding 
    }
    elseif ($byte[0] -eq 0xef -and $byte[1] -eq 0xbb -and $byte[2] -eq 0xbf) {
        return New-Object System.Text.UTF8Encoding 
    }
    elseif ($byte[0] -eq 0xff -and $byte[1] -eq 0xfe) {
        return New-Object System.Text.UnicodeEncoding 
    }
    elseif ($byte[0] -eq 0xfe -and $byte[1] -eq 0xff) {
        return New-Object System.Text.BigEndian 
        UnicodeEncoding 
    }
    elseif ($byte[0] -eq 0 -and $byte[1] -eq 0 -and $byte[2] -eq 0xfe -and $byte[3] -eq 0xff) {
        return New-Object System.Text.UTF32Encoding 
    }
    else {
        return New-Object System.Text.ASCIIEncoding 
    }
}
