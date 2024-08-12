function Add-Paths {
    param (
        [string]$chocolateyPath,
        [string]$nirsoftPath
    )

    # Update current session PATH
    $env:Path += ";$chocolateyPath;$chocolateyPath\bin;$nirsoftPath"

    # Get current PATH variables
    $currentSystemPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $currentUserPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')

    # Create HashSets for uniqueness
    $systemPathSet = [System.Collections.Generic.HashSet[string]]::new($currentSystemPath -split ';')
    $userPathSet = [System.Collections.Generic.HashSet[string]]::new($currentUserPath -split ';')

    # Add new paths
    $systemPathSet.Add("$chocolateyPath") | Out-Null
    $systemPathSet.Add("$chocolateyPath\bin") | Out-Null
    $systemPathSet.Add("$nirsoftPath") | Out-Null

    $userPathSet.Add("$chocolateyPath") | Out-Null
    $userPathSet.Add("$chocolateyPath\bin") | Out-Null
    $userPathSet.Add("$nirsoftPath") | Out-Null

    # Join the HashSets back into single strings with ';' as the separator
    $newSystemPath = ($systemPathSet -join ';')
    $newUserPath = ($userPathSet -join ';')

    # Update registry for system PATH
    [System.Environment]::SetEnvironmentVariable('Path', $newSystemPath, [System.EnvironmentVariableTarget]::Machine)

    # Update registry for user PATH
    [System.Environment]::SetEnvironmentVariable('Path', $newUserPath, [System.EnvironmentVariableTarget]::User)

    # Notify the system of the environment variable change
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1a
    $result = [UIntPtr]::Zero

    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@

    $null = [Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
}