function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}