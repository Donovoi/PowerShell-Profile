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
        Install-Dependencies -InstallDefaultPSModules -NugetPackages Microsoft.Windows.CsWin32 -InstallDefaultNugetPackages -AddDefaultAssemblies -AddCustomAssemblies 'F:\Projects\PowerShell-Profile\Libraries\lib\dnlib.dll' -WarningAction SilentlyContinue -WarningVariable $null
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

function ExtractFunctionMetadataUsingDnlib($dlltoinspect) {
    # Load the dll with dnlib
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

# # Example usage
# $pseverythingdll = Get-GenerateddllFunc -dlltoinspect 'F:\Projects\PowerShell-Profile\Non PowerShell Tools\everything sdk\PSEverything\PSEverything\obj\Debug\net8.0\PSEverything.dll'
# $pseverythingdll | Get-Member

# $testsearch = [nativeMethods]::Everything_SetSearchW('test')

# Write-Host $testsearch
