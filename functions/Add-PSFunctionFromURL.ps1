function Add-PSFunctionFromURL {
    [cmdletbinding()]
    param(
        [parameter(Mandatory, ValueFromPipeline)]
        [uri] $URI
    )

    process {
        try {
            $funcs = Invoke-RestMethod $URI
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($funcs, [ref] $null, [ref] $null)
            foreach ($func in $ast.FindAll({ $args[0] -is [FunctionDefinitionAst] }, $true)) {
                if ($func.Name -in (Get-Command -CommandType Function).Name) {
                    Write-Warning "$($func.Name) is already loaded! Skipping"
                    continue
                }
                New-Item -Name "script:$($func.Name)" -Path function: -Value $func.Body.GetScriptBlock()
            }
        }
        catch {
            Write-Warning $_.Exception.Message
        }
    }
}