<#
.SYNOPSIS
    Elevates the current PowerShell session to run with administrator privileges.

.DESCRIPTION
    Checks if the current PowerShell session is running with administrator privileges.
    If not, relaunches the current script in a new PowerShell process with administrator rights
    using the 'RunAs' verb, which triggers a UAC prompt.
    
    After relaunching with elevated privileges, the original non-elevated session exits.

.EXAMPLE
    Invoke-RunAsAdmin
    
    Checks current privileges and relaunches with admin rights if needed.

.EXAMPLE
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Invoke-RunAsAdmin
    }
    
    Conditional elevation - only elevate if not already admin.

.OUTPUTS
    None. Exits current session if elevation is required.

.NOTES
    - Triggers Windows UAC prompt
    - Original non-elevated session terminates after launching elevated session
    - Elevated session starts in same directory as original
    - Use with caution as elevated sessions have unrestricted system access
#>
function Invoke-RunAsAdmin {
    [OutputType([void])]
    # Check if the current user is an administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    # If not an admin, relaunch the script as an admin
    if (-not $isAdmin) {
        $scriptPath = $myinvocation.mycommand.definition
        $arguments = "& '$scriptPath'"
        Start-Process -FilePath 'powershell' -Verb 'RunAs' -ArgumentList $arguments
        exit
    }
}