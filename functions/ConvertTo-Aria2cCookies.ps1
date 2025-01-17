<#
.SYNOPSIS
    Converts PowerShell cookie objects to Aria2c compatible cookie format.

.DESCRIPTION
    The ConvertTo-Aria2cCookies function takes a CookieContainer object and converts its cookies into a format
    compatible with Aria2c downloader. It saves the converted cookies to a specified file path.
    The cookie format follows Aria2c specifications with tab-separated values:
    domain_name, http_only_flag, path, secure_flag, expiration_timestamp, name, value

.PARAMETER Cookies
    A System.Net.CookieContainer object containing the cookies to be converted.
    These cookies typically come from a web session or request.

.PARAMETER CookieFilePath
    The full path where the converted cookie file should be saved.
    The file will be created in Aria2c compatible format.

.PARAMETER Domain
    The domain name for which to extract cookies from the cookie container.
    This parameter is used to filter cookies for the specific domain.

.EXAMPLE
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    ConvertTo-Aria2cCookies -Cookies $session.Cookies -CookieFilePath "C:\temp\cookies.txt" -Domain "example.com"

.NOTES
    File Name      : ConvertTo-Aria2cCookies.ps1
    Prerequisite   : PowerShell 5.1 or later
    Copyright      : MIT License
    Purpose        : Convert web session cookies for use with Aria2c downloader

.OUTPUTS
    Creates a text file at the specified path containing the converted cookies in Aria2c format.

.LINK
    https://aria2.github.io/manual/en/html/aria2c.html#cookie

.FUNCTIONALITY
    Web Tools
    File Download
    Cookie Management
#>

function ConvertTo-Aria2cCookies {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Net.CookieContainer]$Cookies,
        [Parameter(Mandatory)]
        [string]$CookieFilePath,
        [Parameter(Mandatory)]
        [string]$Domain
    )

    $cookieList = @()

    foreach ($cookie in $Cookies.GetCookies($Domain)) {
        # Check if the Expires property is valid
        $expires = if ($cookie.Expires -eq [DateTime]::MinValue) {
            # Default to a placeholder (e.g., 0 for session cookies)
            0
        }
        else {
            $cookie.Expires.ToFileTimeUtc()
        }

        # Append cookie information in aria2c-compatible format
        $cookieList += "$($cookie.Domain)	$([int]$cookie.HttpOnly)	$($cookie.Path)	$([int]$cookie.Secure)	$expires	$($cookie.Name)	$($cookie.Value)"
    }

    # Write the cookie list to the file
    $cookieList | Set-Content -Path $CookieFilePath -Encoding UTF8

    return $CookieFilePath
}
