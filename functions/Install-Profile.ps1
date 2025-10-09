<#
.SYNOPSIS
This script installs a PowerShell profile from a Git repository and ensures all necessary components, like PowerShell 7 and Git, are installed. It also includes functions for handling file permissions and ownership at a low level using Win32 API calls.

.DESCRIPTION
The script includes functions to install PowerShell 7 and Git, create a profile folder, import functions from the cloned profile, and handle file permissions using Win32 API. The `Invoke-Win32Api` function is used for making low-level Win32 API calls without compiling C# code, providing flexibility and dynamic handling of file operations.

.NOTES
Make sure to run this script with appropriate permissions, as it involves operations that might require administrative privileges.
#>

function Install-Profile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]
        $profileURL = 'https://github.com/Donovoi/PowerShell-Profile.git'
    )
    # First we will check if we are already running as the only instance of pwsh or powershell and with no profile
    $processes = Get-Process | Where-Object { $_.ProcessName -eq 'pwsh' }
    if ($processes.Count -gt 1) {
        $processes | Where-Object { $_.ProcessName -eq 'pwsh' -and $_.Id -ne $PID } | Stop-Process -Force
        Start-Process -FilePath pwsh -ArgumentList "-NoProfile -Command `"IEX (iwr https://gist.githubusercontent.com/Donovoi/5fd319a97c37f987a5bcb8362fe8b7c5/raw)`""
        exit
    }
    else {

        $myDocuments = [System.Environment]::GetFolderPath('MyDocuments')
        $powerShell7ProfilePath = Join-Path -Path $myDocuments -ChildPath 'PowerShell'

        function New-ProfileFolder {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Path
            )
            if (Test-Path -Path $path) {
                Invoke-RemoveItem -Path $path
            }
            New-Item -Path $path -ItemType Directory -Force
            Write-Host "Profile folder created successfully at $path" -ForegroundColor Green
        }

        function Import-Functions {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Path
            )
            $functionPath = Join-Path -Path $path -ChildPath 'functions'
            if (Test-Path -Path $functionPath) {
                $FunctionsFolder = Get-ChildItem -Path (Join-Path -Path $functionPath -ChildPath '*.ps*') -Recurse
                $FunctionsFolder.ForEach{
                    try {
                        . $_.FullName
                    }
                    catch {
                        Write-Host "Error importing function from $($_.FullName): $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        }

        function Install-Git {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                if (Get-Command -Name winget -ErrorAction SilentlyContinue) {
                    winget install --id=Git.Git
                }
                else {
                    Write-Host 'winget is not available. Please install winget first.' -ForegroundColor Red
                    exit
                }
            }
        }

        function Get-Repo {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Path
            )
            if (Test-Path -Path $path) {
                Push-Location -Path $path
                $repoPath = Join-Path -Path $path -ChildPath 'powershellprofile'
                if (Test-Path -Path $repoPath) {
                    Remove-Item -Path $repoPath -Recurse -Force
                }
                try {
                    git clone --recursive $profileURL $repoPath
                    Copy-Item -Path "$repoPath\*" -Destination $path -Force -Recurse
                }
                catch {
                    Write-Host "Error cloning repository: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        function Invoke-RemoveItem {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [string[]]$Path
            )

            begin {
                $script:isRemovable = $false
                # Check if the file is removable and if not, try to make it removable
                $Path | ForEach-Object {
                    try {

                        if (Test-IsRemovable -Path $_) {
                            $isRemovable = $true

                        }
                        else {
                            Write-Warning "File: $_ is not removable."
                            Write-Host 'Attempting to make it removable...' -ForegroundColor Yellow
                            Set-Removable -Path $_
                            $isRemovable = $true
                        }
                    }
                    catch {
                        $isRemovable = $false
                    }
                    return $isRemovable
                }
            }

            process {
                # Attempt to remove the file
                $Path | ForEach-Object {
                    try {
                        if (Test-IsRemovable -Path $_) {
                            Remove-Item $_ -ErrorAction Stop -Recurse -Force
                        }
                        else {
                            Write-Error "Failed to remove the file: $_"

                        }

                    }
                    catch {
                        Write-Warning "Unable to delete item, error: $_"

                    }
                    Write-Output 'Now trying to take ownership and grant full control access...'
                    Write-Host -Object ' and maybe get a HANDLE on things..👌' -ForegroundColor Green
                    Set-Removable -Path $_.FullName

                }
            }
        }

        function Test-IsRemovable {
            [CmdletBinding()]
            [OutputType([bool])]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Path
            )

            try {
                Remove-Item $Path -Force -Recurse
                return $true
            }
            catch {
                return $false
            }
        }
        Function Invoke-Win32Api {
            <#
        .SYNOPSIS
        Call a native Win32 API or a function exported in a DLL.

        .DESCRIPTION
        This method allows you to call a native Win32 API or DLL function
        without compiling C# code using Add-Type. The advantages of this over
        using Add-Type is that this is all generated in memory and no temporary
        files are created.

        The code has been created with great help from various sources. The main
        sources I used were;
        # http://www.leeholmes.com/blog/2007/10/02/managing-ini-files-with-powershell/
        # https://blogs.technet.microsoft.com/heyscriptingguy/2013/06/27/use-powershell-to-interact-with-the-windows-api-part-3/

        .PARAMETER DllName
        [String] The DLL to import the method from.

        .PARAMETER MethodName
        [String] The name of the method.

        .PARAMETER ReturnType
        [Type] The type of the return object returned by the method.

        .PARAMETER ParameterTypes
        [Type[]] Array of types that define the parameter types required by the
        method. The type index should match the index of the value in the
        Parameters parameter.

        If the parameter is a reference or an out parameter, use [Ref] as the type
        for that parameter.

        .PARAMETER Parameters
        [Object[]] Array of objects to supply for the parameter values required by
        the method. The value index should match the index of the value in the
        ParameterTypes parameter.

        If the parameter is a reference or an out parameter, the object should be a
        [Ref] of the parameter.

        .PARAMETER SetLastError
        [Bool] Whether to apply the SetLastError Dll attribute on the method,
        default is $false

        .PARAMETER CharSet
        [Runtime.InteropServices.CharSet] The charset to apply to the CharSet Dll
        attribute on the method, default is [Runtime.InteropServices.CharSet]::Auto

        .OUTPUTS
        [Object] The return result from the method, the type of this value is based
        on the ReturnType parameter.

        .EXAMPLE
        # Use the Win32 APIs to open a file handle
        $handle = Invoke-Win32Api -DllName kernel32.dll `
            -MethodName CreateFileW `
            -ReturnType Microsoft.Win32.SafeHandles.SafeFileHandle `
            -ParameterTypes @([String], [System.Security.AccessControl.FileSystemRights], [System.IO.FileShare], [IntPtr], [System.IO.FileMode], [UInt32], [IntPtr]) `
            -Parameters @(
                "\\?\C:\temp\test.txt",
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.IO.FileShare]::ReadWrite,
                [IntPtr]::Zero,
                [System.IO.FileMode]::OpenOrCreate,
                0,
                [IntPtr]::Zero) `
            -SetLastError $true `
            -CharSet Unicode
        if ($handle.IsInvalid) {
            $last_err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw [System.ComponentModel.Win32Exception]$last_err
        }
        $handle.Close()

        # Lookup the account name from a SID
        $sid_string = "S-1-5-18"
        $sid = New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $sid_string
        $sid_bytes = New-Object -TypeName byte[] -ArgumentList $sid.BinaryLength
        $sid.GetBinaryForm($sid_bytes, 0)

        $name = New-Object -TypeName System.Text.StringBuilder
        $name_length = 0
        $domain_name = New-Object -TypeName System.Text.StringBuilder
        $domain_name_length = 0

        $invoke_args = @{
            DllName = "Advapi32.dll"
            MethodName = "LookupAccountSidW"
            ReturnType = [bool]
            ParameterTypes = @([String], [byte[]], [System.Text.StringBuilder], [Ref], [System.Text.StringBuilder], [Ref], [Ref])
            Parameters = @(
                $null,
                $sid_bytes,
                $name,
                [Ref]$name_length,
                $domain_name,
                [Ref]$domain_name_length,
                [Ref][IntPtr]::Zero
            )
            SetLastError = $true
            CharSet = "Unicode"
        }

        $res = Invoke-Win32Api @invoke_args
        $name.EnsureCapacity($name_length)
        $domain_name.EnsureCapacity($domain_name_length)
        $res = Invoke-Win32Api @invoke_args
        if (-not $res) {
            $last_err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw [System.ComponentModel.Win32Exception]$last_err
        }
        Write-Output "SID: $sid_string, Domain: $($domain_name.ToString()), Name: $($name.ToString())"

        .NOTES
        The parameters to use for a method dynamically based on the method that is
        called. There is no cut and fast way to automatically convert the interface
        listed on the Microsoft docs. There are great resources to help you create
        the "P/Invoke" definition like pinvoke.net.
        #>
            [CmdletBinding()]
            [OutputType([Object])]
            param(
                [Parameter(Position = 0, Mandatory = $true)] [String]$DllName,
                [Parameter(Position = 1, Mandatory = $true)] [String]$MethodName,
                [Parameter(Position = 2, Mandatory = $true)] [Type]$ReturnType,
                [Parameter(Position = 3)] [Type[]]$ParameterTypes = [Type[]]@(),
                [Parameter(Position = 4)] [Object[]]$Parameters = [Object[]]@(),
                [Parameter()] [Bool]$SetLastError = $false,
                [Parameter()] [Runtime.InteropServices.CharSet]$CharSet = [Runtime.InteropServices.CharSet]::Auto
            )
            if ($ParameterTypes.Length -ne $Parameters.Length) {
                throw [System.ArgumentException]"ParameterType Count $($ParameterTypes.Length) not equal to Parameter Count $($Parameters.Length)"
            }

            # First step is to define the dynamic assembly in the current AppDomain
            $assembly = New-Object -TypeName System.Reflection.AssemblyName -ArgumentList 'Win32ApiAssembly'
            $AssemblyBuilder = [System.Reflection.Assembly].Assembly.GetTypes() | Where-Object { $_.Name -eq 'AssemblyBuilder' }
            $dynamic_assembly = $AssemblyBuilder::DefineDynamicAssembly($assembly, [Reflection.Emit.AssemblyBuilderAccess]::Run)


            # Second step is to create the dynamic module and type/class that contains
            # the P/Invoke definition
            $dynamic_module = $dynamic_assembly.DefineDynamicModule('Win32Module', $false)
            $dynamic_type = $dynamic_module.DefineType('Win32Type', [Reflection.TypeAttributes]'Public, Class')

            # Need to manually get the reference type if the ParameterType is [Ref], we
            # define this based on the Parameter type at the same index
            $parameter_types = $ParameterTypes.Clone()
            for ($i = 0; $i -lt $ParameterTypes.Length; $i++) {
                if ($ParameterTypes[$i] -eq [Ref]) {
                    $parameter_types[$i] = $Parameters[$i].Value.GetType().MakeByRefType()
                }
            }

            # Next, the method is created where we specify the name, parameters and
            # return type that is expected
            $dynamic_method = $dynamic_type.DefineMethod(
                $MethodName,
                [Reflection.MethodAttributes]'Public, Static',
                $ReturnType,
                $parameter_types
            )

            # Build the attributes (DllImport) part of the method where the DLL
            # SetLastError and CharSet are applied
            $constructor = [Runtime.InteropServices.DllImportAttribute].GetConstructor([String])
            $method_fields = [Reflection.FieldInfo[]]@(
                [Runtime.InteropServices.DllImportAttribute].GetField('SetLastError'),
                [Runtime.InteropServices.DllImportAttribute].GetField('CharSet')
            )
            $method_fields_values = [Object[]]@($SetLastError, $CharSet)
            $custom_attributes = New-Object -TypeName Reflection.Emit.CustomAttributeBuilder -ArgumentList @(
                $constructor,
                $DllName,
                $method_fields,
                $method_fields_values
            )
            $dynamic_method.SetCustomAttribute($custom_attributes)

            # Create the custom type/class based on what was configured above
            $win32_type = $dynamic_type.CreateType()

            # Invoke the method with the parameters supplied and return the result
            $result = $win32_type::$MethodName.Invoke($Parameters)
            return $result
        }

        function Set-Removable {
            <#
        .SYNOPSIS
        Updates file permissions to make it removable by the current user.

        .DESCRIPTION
        The function takes a file path as input and attempts to change its permissions to make it removable by the current user. It uses Win32 API calls to modify file permissions and ownership.

        .PARAMETER Path
        The file path for which permissions need to be updated.
        #>
            [CmdletBinding(SupportsShouldProcess)]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Path
            )

            if ($PSCmdlet.ShouldProcess($Path, 'Take ownership and grant full control')) {
                try {
                    # Update file ownership and permissions using Win32 API calls
                    # First we will elevate in a new window to system using paexec
                    # check for paexec in path then act accordingly
                    if (-not (Get-Command -Name 'paexec.exe' -ErrorAction SilentlyContinue)) {
                        # download from github
                        Write-Host 'paexec not found. Downloading now' -ForegroundColor Yellow
                        $paexec = Invoke-WebRequest -Uri 'https://www.poweradmin.com/paexec/paexec.exe' -OutFile 'C:\Windows\paexec.exe'
                    }
                    takeown /f $Path
                    icacls $Path /grant "${env:USERNAME}:(F)"
                    $result = Invoke-Win32Api -DllName 'kernel32.dll' -MethodName 'SetFileAttributes' -ReturnType [bool] -ParameterTypes @([String], [UInt32]) -Parameters @($Path, 0x80) # 0x80 is FILE_ATTRIBUTE_NORMAL
                    if (-not $result) {
                        throw 'Failed to change file attributes.'
                    }
                    Set-InvalidHandle -Path $Path
                }
                catch {
                    Write-Error "Failed to make the file removable: $($_.Exception.Message)"
                }
            }
        }
        <#
.SYNOPSIS
Invalidates file handles for a given path.

.DESCRIPTION
The Set-InvalidHandle function takes a path as input, searches for any file handles associated with that path, and attempts to invalidate them. If an error occurs, the function will return a verbose error message. This function uses low-level system calls to ensure high reliability.

.PARAMETER Path
The path to the file for which to invalidate handles. This parameter is mandatory.

.OUTPUTS
Returns a boolean indicating success or failure.

.EXAMPLE
Set-InvalidHandle -Path "C:\Path\To\File.txt"

#>
        function Set-InvalidHandle {
            [CmdletBinding()]
            [OutputType([bool])]
            param(
                [Parameter(Mandatory = $true)]
                [string]
                $Path
            )

            begin {
                $Error.Clear()
                $HandlePath = Resolve-Path -Path $Path | Select-Object -ExpandProperty Path
                $Handle = $null

                $NtSetInformationFile = @'
                [DllImport("ntdll.dll", SetLastError = true)]
                public static extern int NtSetInformationFile(IntPtr FileHandle, ref IO_STATUS_BLOCK IoStatusBlock, IntPtr FileInformation, int Length, int FileInformationClass);
'@
                $Kernel32 = @'
                [DllImport("kernel32.dll", SetLastError = true)]
                public static extern int CloseHandle(IntPtr hObject);
'@
                $CloseHandle = Add-Type -MemberDefinition $Kernel32 -Name 'CloseHandleWin32' -Namespace Win32Functions -PassThru
                $SetInformationFile = Add-Type -MemberDefinition $NtSetInformationFile -Name 'NtSetInformationFileWin32' -Namespace Win32Functions -PassThru
            }

            process {
                $success = $false

                try {
                    $Handle = Get-Handle -Path $HandlePath
                    $success = $true
                }
                catch {
                    Write-Error "Failed to get handle: $($_.Exception.Message)"
                }

                if ($Handle) {
                    $Handle | ForEach-Object -Process {
                        $ProcessHandle = $_.Handle
                        $IoStatusBlock = New-Object IO_STATUS_BLOCK
                        $script:success = $false

                        try {
                            $CloseHandle::CloseHandle($ProcessHandle) | Out-Null
                            $SetInformationFile::NtSetInformationFile($ProcessHandle, [ref]$IoStatusBlock, [IntPtr]::Zero, 0, 11) | Out-Null
                            $success = $true
                        }
                        catch {
                            Write-Error "Failed to close handle: $($_.Exception.Message)"
                                            [string]$Path
            )
            if (Test-Path -Path $path) {
                Invoke-RemoveItem -Path $path
            }
            New-Item -Path $path -ItemType Directory -Force
            Write-Host "Profile folder created successfully at $path" -ForegroundColor Green
        }

        function Import-Functions {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Path
            )
            $functionPath = Join-Path -Path $path -ChildPath 'functions'
            if (Test-Path -Path $functionPath) {
                $FunctionsFolder = Get-ChildItem -Path (Join-Path -Path $functionPath -ChildPath '*.ps*') -Recurse
                $FunctionsFolder.ForEach{
                    try {
                        . $_.FullName
                    }
                    catch {
                        Write-Host "Error importing function from $($_.FullName): $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
        }

        function Install-Git {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                if (Get-Command -Name winget -ErrorAction SilentlyContinue) {
                    winget install --id=Git.Git
                }
                else {
                    Write-Host 'winget is not available. Please install winget first.' -ForegroundColor Red
                    exit
                }
            }
        }

        function Get-Repo {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Path
            )
            if (Test-Path -Path $path) {
                Push-Location -Path $path
                $repoPath = Join-Path -Path $path -ChildPath 'powershellprofile'
                if (Test-Path -Path $repoPath) {
                    Remove-Item -Path $repoPath -Recurse -Force
                }
                try {
                    git clone --recursive $profileURL $repoPath
                    Copy-Item -Path "$repoPath\*" -Destination $path -Force -Recurse
                }
                catch {
                    Write-Host "Error cloning repository: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        function Invoke-RemoveItem {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [string[]]$Path
            )

            begin {
                $script:isRemovable = $false
                # Check if the file is removable and if not, try to make it removable
                $Path | ForEach-Object {
                    try {

                        if (Test-IsRemovable -Path $_) {
                            $isRemovable = $true

                        }
                        else {
                            Write-Warning "File: $_ is not removable."
                            Write-Host 'Attempting to make it removable...' -ForegroundColor Yellow
                            Set-Removable -Path $_
                            $isRemovable = $true
                        }
                    }
                    catch {
                        $isRemovable = $false
                    }
                    return $isRemovable
                }
            }

            process {
                # Attempt to remove the file
                $Path | ForEach-Object {
                    try {
                        if (Test-IsRemovable -Path $_) {
                            Remove-Item $_ -ErrorAction Stop -Recurse -Force
                        }
                        else {
                            Write-Error "Failed to remove the file: $_"

                        }

                    }
                    catch {
                        Write-Warning "Unable to delete item, error: $_"

                    }
                    Write-Output 'Now trying to take ownership and grant full control access...'
                    Write-Host -Object ' and maybe get a HANDLE on things..👌' -ForegroundColor Green
                    Set-Removable -Path $_.FullName

                }
            }
        }

        function Test-IsRemovable {
            [CmdletBinding()]
            [OutputType([bool])]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Path
            )

            try {
                Remove-Item $Path -Force -Recurse
                return $true
            }
            catch {
                return $false
            }
        }
        Function Invoke-Win32Api {
            <#
        .SYNOPSIS
        Call a native Win32 API or a function exported in a DLL.

        .DESCRIPTION
        This method allows you to call a native Win32 API or DLL function
        without compiling C# code using Add-Type. The advantages of this over
        using Add-Type is that this is all generated in memory and no temporary
        files are created.

        The code has been created with great help from various sources. The main
        sources I used were;
        # http://www.leeholmes.com/blog/2007/10/02/managing-ini-files-with-powershell/
        # https://blogs.technet.microsoft.com/heyscriptingguy/2013/06/27/use-powershell-to-interact-with-the-windows-api-part-3/

        .PARAMETER DllName
        [String] The DLL to import the method from.

        .PARAMETER MethodName
        [String] The name of the method.

        .PARAMETER ReturnType
        [Type] The type of the return object returned by the method.

        .PARAMETER ParameterTypes
        [Type[]] Array of types that define the parameter types required by the
        method. The type index should match the index of the value in the
        Parameters parameter.

        If the parameter is a reference or an out parameter, use [Ref] as the type
        for that parameter.

        .PARAMETER Parameters
        [Object[]] Array of objects to supply for the parameter values required by
        the method. The value index should match the index of the value in the
        ParameterTypes parameter.

        If the parameter is a reference or an out parameter, the object should be a
        [Ref] of the parameter.

        .PARAMETER SetLastError
        [Bool] Whether to apply the SetLastError Dll attribute on the method,
        default is $false

        .PARAMETER CharSet
        [Runtime.InteropServices.CharSet] The charset to apply to the CharSet Dll
        attribute on the method, default is [Runtime.InteropServices.CharSet]::Auto

        .OUTPUTS
        [Object] The return result from the method, the type of this value is based
        on the ReturnType parameter.

        .EXAMPLE
        # Use the Win32 APIs to open a file handle
        $handle = Invoke-Win32Api -DllName kernel32.dll `
            -MethodName CreateFileW `
            -ReturnType Microsoft.Win32.SafeHandles.SafeFileHandle `
            -ParameterTypes @([String], [System.Security.AccessControl.FileSystemRights], [System.IO.FileShare], [IntPtr], [System.IO.FileMode], [UInt32], [IntPtr]) `
            -Parameters @(
                "\\?\C:\temp\test.txt",
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.IO.FileShare]::ReadWrite,
                [IntPtr]::Zero,
                [System.IO.FileMode]::OpenOrCreate,
                0,
                [IntPtr]::Zero) `
            -SetLastError $true `
            -CharSet Unicode
        if ($handle.IsInvalid) {
            $last_err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw [System.ComponentModel.Win32Exception]$last_err
        }
        $handle.Close()

        # Lookup the account name from a SID
        $sid_string = "S-1-5-18"
        $sid = New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $sid_string
        $sid_bytes = New-Object -TypeName byte[] -ArgumentList $sid.BinaryLength
        $sid.GetBinaryForm($sid_bytes, 0)

        $name = New-Object -TypeName System.Text.StringBuilder
        $name_length = 0
        $domain_name = New-Object -TypeName System.Text.StringBuilder
        $domain_name_length = 0

        $invoke_args = @{
            DllName = "Advapi32.dll"
            MethodName = "LookupAccountSidW"
            ReturnType = [bool]
            ParameterTypes = @([String], [byte[]], [System.Text.StringBuilder], [Ref], [System.Text.StringBuilder], [Ref], [Ref])
            Parameters = @(
                $null,
                $sid_bytes,
                $name,
                [Ref]$name_length,
                $domain_name,
                [Ref]$domain_name_length,
                [Ref][IntPtr]::Zero
            )
            SetLastError = $true
            CharSet = "Unicode"
        }

        $res = Invoke-Win32Api @invoke_args
        $name.EnsureCapacity($name_length)
        $domain_name.EnsureCapacity($domain_name_length)
        $res = Invoke-Win32Api @invoke_args
        if (-not $res) {
            $last_err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw [System.ComponentModel.Win32Exception]$last_err
        }
        Write-Output "SID: $sid_string, Domain: $($domain_name.ToString()), Name: $($name.ToString())"

        .NOTES
        The parameters to use for a method dynamically based on the method that is
        called. There is no cut and fast way to automatically convert the interface
        listed on the Microsoft docs. There are great resources to help you create
        the "P/Invoke" definition like pinvoke.net.
        #>
            [CmdletBinding()]
            [OutputType([Object])]
            param(
                [Parameter(Position = 0, Mandatory = $true)] [String]$DllName,
                [Parameter(Position = 1, Mandatory = $true)] [String]$MethodName,
                [Parameter(Position = 2, Mandatory = $true)] [Type]$ReturnType,
                [Parameter(Position = 3)] [Type[]]$ParameterTypes = [Type[]]@(),
                [Parameter(Position = 4)] [Object[]]$Parameters = [Object[]]@(),
                [Parameter()] [Bool]$SetLastError = $false,
                [Parameter()] [Runtime.InteropServices.CharSet]$CharSet = [Runtime.InteropServices.CharSet]::Auto
            )
            if ($ParameterTypes.Length -ne $Parameters.Length) {
                throw [System.ArgumentException]"ParameterType Count $($ParameterTypes.Length) not equal to Parameter Count $($Parameters.Length)"
            }

            # First step is to define the dynamic assembly in the current AppDomain
            $assembly = New-Object -TypeName System.Reflection.AssemblyName -ArgumentList 'Win32ApiAssembly'
            $AssemblyBuilder = [System.Reflection.Assembly].Assembly.GetTypes() | Where-Object { $_.Name -eq 'AssemblyBuilder' }
            $dynamic_assembly = $AssemblyBuilder::DefineDynamicAssembly($assembly, [Reflection.Emit.AssemblyBuilderAccess]::Run)


            # Second step is to create the dynamic module and type/class that contains
            # the P/Invoke definition
            $dynamic_module = $dynamic_assembly.DefineDynamicModule('Win32Module', $false)
            $dynamic_type = $dynamic_module.DefineType('Win32Type', [Reflection.TypeAttributes]'Public, Class')

            # Need to manually get the reference type if the ParameterType is [Ref], we
            # define this based on the Parameter type at the same index
            $parameter_types = $ParameterTypes.Clone()
            for ($i = 0; $i -lt $ParameterTypes.Length; $i++) {
                if ($ParameterTypes[$i] -eq [Ref]) {
                    $parameter_types[$i] = $Parameters[$i].Value.GetType().MakeByRefType()
                }
            }

            # Next, the method is created where we specify the name, parameters and
            # return type that is expected
            $dynamic_method = $dynamic_type.DefineMethod(
                $MethodName,
                [Reflection.MethodAttributes]'Public, Static',
                $ReturnType,
                $parameter_types
            )

            # Build the attributes (DllImport) part of the method where the DLL
            # SetLastError and CharSet are applied
            $constructor = [Runtime.InteropServices.DllImportAttribute].GetConstructor([String])
            $method_fields = [Reflection.FieldInfo[]]@(
                [Runtime.InteropServices.DllImportAttribute].GetField('SetLastError'),
                [Runtime.InteropServices.DllImportAttribute].GetField('CharSet')
            )
            $method_fields_values = [Object[]]@($SetLastError, $CharSet)
            $custom_attributes = New-Object -TypeName Reflection.Emit.CustomAttributeBuilder -ArgumentList @(
                $constructor,
                $DllName,
                $method_fields,
                $method_fields_values
            )
            $dynamic_method.SetCustomAttribute($custom_attributes)

            # Create the custom type/class based on what was configured above
            $win32_type = $dynamic_type.CreateType()

            # Invoke the method with the parameters supplied and return the result
            $result = $win32_type::$MethodName.Invoke($Parameters)
            return $result
        }

        function Set-Removable {
            <#
        .SYNOPSIS
        Updates file permissions to make it removable by the current user.

        .DESCRIPTION
        The function takes a file path as input and attempts to change its permissions to make it removable by the current user. It uses Win32 API calls to modify file permissions and ownership.

        .PARAMETER Path
        The file path for which permissions need to be updated.
        #>
            [CmdletBinding(SupportsShouldProcess)]
            param (
                [Parameter(Mandatory = $true)]
                [string]$Path
            )

            if ($PSCmdlet.ShouldProcess($Path, 'Take ownership and grant full control')) {
                try {
                    # Update file ownership and permissions using Win32 API calls
                    # First we will elevate in a new window to system using paexec
                    # check for paexec in path then act accordingly
                    if (-not (Get-Command -Name 'paexec.exe' -ErrorAction SilentlyContinue)) {
                        # download from github
                        Write-Host 'paexec not found. Downloading now' -ForegroundColor Yellow
                        $paexec = Invoke-WebRequest -Uri 'https://www.poweradmin.com/paexec/paexec.exe' -OutFile 'C:\Windows\paexec.exe'
                    }
                    takeown /f $Path
                    icacls $Path /grant "${env:USERNAME}:(F)"
                    $result = Invoke-Win32Api -DllName 'kernel32.dll' -MethodName 'SetFileAttributes' -ReturnType [bool] -ParameterTypes @([String], [UInt32]) -Parameters @($Path, 0x80) # 0x80 is FILE_ATTRIBUTE_NORMAL
                    if (-not $result) {
                        throw 'Failed to change file attributes.'
                    }
                    Set-InvalidHandle -Path $Path
                }
                catch {
                    Write-Error "Failed to make the file removable: $($_.Exception.Message)"
                }
            }
        }
        <#
.SYNOPSIS
Invalidates file handles for a given path.

.DESCRIPTION
The Set-InvalidHandle function takes a path as input, searches for any file handles associated with that path, and attempts to invalidate them. If an error occurs, the function will return a verbose error message. This function uses low-level system calls to ensure high reliability.

.PARAMETER Path
The path to the file for which to invalidate handles. This parameter is mandatory.

.OUTPUTS
Returns a boolean indicating success or failure.

.EXAMPLE
Set-InvalidHandle -Path "C:\Path\To\File.txt"

#>
        function Set-InvalidHandle {
            [CmdletBinding()]
            [OutputType([bool])]
            param(
                [Parameter(Mandatory = $true)]
                [string]
                $Path
            )

            begin {
                $Error.Clear()
                $HandlePath = Resolve-Path -Path $Path | Select-Object -ExpandProperty Path
                $Handle = $null

                $NtSetInformationFile = @'
                [DllImport("ntdll.dll", SetLastError = true)]
                public static extern int NtSetInformationFile(IntPtr FileHandle, ref IO_STATUS_BLOCK IoStatusBlock, IntPtr FileInformation, int Length, int FileInformationClass);
'@
                $Kernel32 = @'
                [DllImport("kernel32.dll", SetLastError = true)]
                public static extern int CloseHandle(IntPtr hObject);
'@
                $CloseHandle = Add-Type -MemberDefinition $Kernel32 -Name 'CloseHandleWin32' -Namespace Win32Functions -PassThru
                $SetInformationFile = Add-Type -MemberDefinition $NtSetInformationFile -Name 'NtSetInformationFileWin32' -Namespace Win32Functions -PassThru
            }

            process {
                $success = $false

                try {
                    $Handle = Get-Handle -Path $HandlePath
                    $success = $true
                }
                catch {
                    Write-Error "Failed to get handle: $($_.Exception.Message)"
                }

                if ($Handle) {
                    $Handle | ForEach-Object -Process {
                        $ProcessHandle = $_.Handle
                        $IoStatusBlock = New-Object IO_STATUS_BLOCK
                        $script:success = $false

                        try {
                            $CloseHandle::CloseHandle($ProcessHandle) | Out-Null
                            $SetInformationFile::NtSetInformationFile($ProcessHandle, [ref]$IoStatusBlock, [IntPtr]::Zero, 0, 11) | Out-Null
                            $success = $true
                        }
                        catch {
                            Write-Error "Failed to close handle: $($_.Exception.Message)"
                            $success = $false
                        }
                    }
                }
                else {
                    Write-Error "Failed to get handle for $HandlePath"
                    $success = $false
                }

                return $success
            }
        }


        function Get-Handle {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory = $true)]
                [string]$FilePath
            )
            Add-Type -TypeDefinition @'
        using System;
        using System.Diagnostics;
        using System.ComponentModel;
        using System.Runtime.InteropServices;

        public class ProcessHandler
        {
            [DllImport("kernel32.dll")]
            public static extern IntPtr OpenProcess(uint processAccess, bool bInheritHandle, int processId);
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern bool CloseHandle(IntPtr hObject);

            public IntPtr GetProcessHandle(int pid)
            {
                return OpenProcess(0x0400 | 0x0010, false, pid);
            }

            public void CloseProcessHandle(IntPtr handle)
            {
                CloseHandle(handle);
            }
        }
'@ -Language CSharp

            $processHandler = New-Object ProcessHandler
            $escapedFilePath = $FilePath -replace '\\', '\\\\'
            $escapedFileNameWithExtension = Split-Path $escapedFilePath -Leaf

            do {
                $processes = Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%$escapedFileNameWithExtension%'"

                $processes | ForEach-Object {
                    $procHandle = $processHandler.GetProcessHandle($_.ProcessId)

                    if ($procHandle -ne [IntPtr]::Zero) {
                        $userDecision = $null
                        do {
                            $userDecision = Read-Host "Invalidate handles or Kill Process($($_.Caption) - $($_.ExecutablePath))?(I/K/Ignore)"
                            if ($userDecision -eq 'I') {
                                $processHandler.CloseProcessHandle($procHandle)
                                Write-Logg -Message 'Handle invalidated.'
                            }
                            elseif ($userDecision -eq 'K') {
                                Stop-Process -Id $_.ProcessId -Force
                                Write-Logg -Message 'Process killed.'
                            }
                        } while ($userDecision -ne 'I' -and $userDecision -ne 'K' -and $userDecision -ne 'Ignore')
                        $processHandler.CloseProcessHandle($procHandle)
                    }
                }
                Start-Sleep -Seconds 1
            } while ((Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%$escapedFileNameWithExtension%'").Count -gt 0)
        }

        New-ProfileFolder -Path $powerShell7ProfilePath
        Install-Git
        $folderarray = $powerShell7ProfilePath
        $folderarray | ForEach-Object -Process {
            Get-Repo -Path $_
            Import-Functions -Path $_
        }
    }
}

