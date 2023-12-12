function Invoke-MetaInspect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $InspectedAssemblyPath
    )

    process {
        Add-Type -Path "F:\Projects\PowerShell-Profile\Libraries\lib\dnlib.dll"
        


        # Load the dll with dnlib
        $module = [dnlib.DotNet.ModuleDefMD]::Load("$InspectedAssemblyPath", [dnlib.DotNet.ModuleContext]::new())

        
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
}

