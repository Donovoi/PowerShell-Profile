# A helper function used to reduce typing while defining function
# prototypes for Add-Win32Type.
function func {
    Param
    (
        [Parameter(Position = 0, Mandatory = $True)]
        [String]
        $DllName,

        [Parameter(Position = 1, Mandatory = $True)]
        [string]
        $FunctionName,

        [Parameter(Position = 2, Mandatory = $True)]
        [Type]
        $ReturnType,

        [Parameter(Position = 3)]
        [Type[]]
        $ParameterTypes,

        [Parameter(Position = 4)]
        [Runtime.InteropServices.CallingConvention]
        $NativeCallingConvention,

        [Parameter(Position = 5)]
        [Runtime.InteropServices.CharSet]
        $Charset,

        [String]
        $EntryPoint,

        [Switch]
        $SetLastError
    )

    $Properties = @{
        DllName      = $DllName
        FunctionName = $FunctionName
        ReturnType   = $ReturnType
    }

    if ($ParameterTypes) {
        $Properties['ParameterTypes'] = $ParameterTypes 
    }
    if ($NativeCallingConvention) {
        $Properties['NativeCallingConvention'] = $NativeCallingConvention 
    }
    if ($Charset) {
        $Properties['Charset'] = $Charset 
    }
    if ($SetLastError) {
        $Properties['SetLastError'] = $SetLastError 
    }
    if ($EntryPoint) {
        $Properties['EntryPoint'] = $EntryPoint 
    }

    New-Object PSObject -Property $Properties
}
