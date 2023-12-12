function Invoke-MetaInspect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $InspectedAssemblyPath
    )

    process {
        Add-Type -AssemblyName dnlib
        


        # Load the dll with dnlib
        $MyModule = [dnlib.DotNet.ModuleDefMD]::Load("$InspectedAssemblyPath", [dnlib.DotNet.ModuleContext]::new())

        # Enumerate all Types
        $Types = $MyModule.GetTypes()

        # For every type definition, inspect the properties 
        # Filter their CustomAttributes against the attribute name we expect
        # Finally output the property name(s)
        $Types | ForEach-Object {
            $Params = $_.Properties | Where-Object {
                $_.CustomAttributes.AttributeType.FullName -eq [Parameter].FullName
            }
            $Params.Name
        }

    }
}


