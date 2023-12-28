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
function Get-GenerateddllFunc {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $dlltoinspect
    )

    process {
        # get all files in the current directory except this file and import it as a script
        $ActualScriptName = Get-PSCallStack | Select-Object -First 1 -ExpandProperty ScriptName
        $ScriptParentPath = Split-Path -Path $(Resolve-Path -Path $($ActualScriptName.foreach{ $_ }) ) -Parent
        $scriptstonotimport = @("$($($ActualScriptName.foreach{$_}).split('\')[-1])", 'Get-KapeAndTools.ps1', '*RustandFriends*', '*zimmerman*', '*memorycapture*' )
        Get-ChildItem -Path $ScriptParentPath -Exclude $scriptstonotimport | ForEach-Object {
            . $_.FullName
        }

        # add and install any dependencies
        Install-Dependencies -InstallDefaultPSModules -NugetPackages Microsoft.Windows.CsWin32 -InstallDefaultNugetPackages -AddDefaultAssemblies -AddCustomAssemblies "$PWD\Libraries\dnlib.dll"
        # verify, normalize and escape the path using dotnet methods
        $dlltoinspect = [System.IO.Path]::GetFullPath($dlltoinspect).Replace('\', '\\').Trim()
        # Extract function metadata (names, parameters, return types) using dnlib
        $functionsMetadata = ExtractFunctionMetadataUsingDnlib($dlltoinspect)

        $csharpCode = 'using System; using System.Runtime.InteropServices;' + "`n"
        $csharpCode += 'public static class NativeMethods {' + "`n"

        foreach ($function in $functionsMetadata) {
            # Construct the parameter string
            $parameterString = ''
            foreach ($param in $function.Parameters) {
                # Assuming $param has properties for type and name
                $parameterString += $param.Type + ' ' + $param.Name + ', '
            }
            $parameterString = $parameterString.TrimEnd(', ')

            # Construct the method declaration
            $methodCode = '[DllImport("' + $dlltoinspect + '", EntryPoint = "' + $function.MethodName + '", CharSet = CharSet.Auto)]' + "`n"
            $methodCode += 'public static extern ' + $function.ReturnType + ' ' + $function.MethodName + '(' + $parameterString + ');' + "`n"

            $csharpCode += $methodCode

            # Optional: Log each method being processed
            Write-Host "Adding function to class: $($function.MethodName)"
        }

        $csharpCode += '}' # Close the class declaration

        # Compile the class with all methods
        try {
            Add-Type -TypeDefinition $csharpCode -IgnoreWarnings
            Write-Host 'Successfully compiled all functions.'
        }
        catch {
            Write-Host 'Error compiling functions.'
            Write-Host $_.Exception.Message -ForegroundColor Red
        }



    }
}

function ExtractFunctionMetadataUsingDnlib() {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $dlltoinspect
    )
    # get all files in the current directory except this file and import it as a script
    $ActualScriptName = Get-PSCallStack | Select-Object -First 1 -ExpandProperty ScriptName
    $ScriptParentPath = Split-Path -Path $(Resolve-Path -Path $($ActualScriptName.foreach{ $_ }) ) -Parent
    $scriptstonotimport = @("$($($ActualScriptName.foreach{$_}).split('\')[-1])", 'Get-KapeAndTools.ps1', '*RustandFriends*', '*zimmerman*', '*memorycapture*' )
    Get-ChildItem -Path $ScriptParentPath -Exclude $scriptstonotimport | ForEach-Object {
        . $_.FullName
    }
    # Load the dll with dnlib
    # add and install any dependencies
    Install-Dependencies -InstallDefaultPSModules -NugetPackages Microsoft.Windows.CsWin32 -InstallDefaultNugetPackages -AddDefaultAssemblies -AddCustomAssemblies "$PWD\Libraries\dnlib.dll"
    $module = [dnlib.DotNet.ModuleDefMD]::Load("$dlltoinspect", [dnlib.DotNet.ModuleContext]::new())

    # Extract method information
    $methodInfos = @()
    foreach ($type in $module.GetTypes()) {
        foreach ($method in $type.Methods) {
            # Assuming you want to handle only public static methods for simplicity
            if ($method.IsStatic) {
                $methodInfos += @{
                    TypeName   = $type.FullName
                    MethodName = $method.Name
                    # parameters
                    Parameters = $method.Parameters
                    # return type
                    ReturnType = $method.ReturnType
                    # method body
                    Body       = $method.Body
                }
            }
        }
    }
    return $methodInfos
}

# Load the assembly
# $assemblyPath = "$PWD\Libraries\Microsoft.Windows.CsWin32.dll"
# $assembly = [System.Reflection.Assembly]::LoadFile($assemblyPath)

# # Get the type
# $type = $assembly.GetType("Namespace.TypeName")

# # Create an instance if necessary
# $instance = [Activator]::CreateInstance($type)

# # Call an instance method
# $result = $instance.InstanceMethod()

# # Call a static method
# $staticResult = [Namespace.TypeName]::StaticMethod()

# # Handle the results
# Write-Host "Instance method result: $result"
# Write-Host "Static method result: $staticResult"

# # Example usage
# $pseverythingdll = ExtractFunctionMetadataUsingDnlib "$PWD\Libraries\Microsoft.Windows.CsWin32.dll"
# $pseverythingdll | Get-Member

# $sourceGenerator = New-Object Microsoft.Windows.CsWin32.SourceGenerator
