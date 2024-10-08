function Remove-PathEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$pathToRemove
    )

    # Get the current PATH environment variable based on the scope (Machine/User)
    $currentPath = $ENV:PATH

    # Split the PATH into an array of individual paths and create a HashSet for uniqueness
    $pathSet = [System.Collections.Generic.HashSet[string]]::new($currentPath -split ';')

    # Remove the entry if it exists
    if ($PSCmdlet.ShouldProcess($pathToRemove, 'Remove path entry')) {
        $pathSet.Remove($pathToRemove) | Out-Null
    }

    # Join the HashSet back into a single string with ';' as the separator
    $newPath = ($pathSet -join ';')

    # Set the updated PATH environment variable
    if ($PSCmdlet.ShouldProcess('Set PATH environment variable', 'Set updated PATH environment variable')) {
        Set-ItemProperty -Path HKCU:\Environment -Name Path -Value $newPath -Force
    }
}