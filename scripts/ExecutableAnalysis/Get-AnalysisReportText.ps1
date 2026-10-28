function Get-AnalysisReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record,[Parameter(Mandatory)][string]$RunDirectory,[AllowEmptyString()][string]$SourceSHA256='',[string]$FindingsText)
    $lines=[Collections.Generic.List[string]]::new()
    $statusNames=@{Completed='Complete';CompletedWithLimitations='Complete, with limits';Partial='Incomplete';Failed='Failed';Running='In progress'}
    $stageNames=@{IdentityAndStrings='File details and text';FirmwareContext='Firmware details';ApplicationContext='Application files';research='Documentation research';PdbContext='Debug symbols';GhidraDirect='Ghidra code analysis';FunctionIndex='Function list';analysis='Analysis';detractor='Independent review';'reconciled-findings'='Final review'}
    $status=if($statusNames.ContainsKey([string]$Record.Status)){$statusNames[[string]$Record.Status]}else{[string]$Record.Status}
    $lines.Add('# Program analysis');$lines.Add('');$lines.Add("Result: $status ($($Record.Status)).")
    $lines.Add('');$lines.Add("- File SHA-256: $SourceSHA256")
    $unchanged=if($Record.SourceUnchanged){'Yes'}else{'No'}
    $lines.Add("- Source file unchanged: $unchanged")
    if($Record.Identity){$lines.Add("- File format: $($Record.Identity.Format). Processor: $($Record.Identity.Architecture).")}
    if($Record.ApplicationContext -and $Record.ApplicationContext.Detected){
        $lines.Add("Application scope: $($Record.ApplicationContext.Scope)")
        $lines.Add('See [application files and limits](basic/application-context.json).')
    }
    if(-not $PSBoundParameters.ContainsKey('FindingsText')){$findings=Join-Path $RunDirectory 'ai/reconciled-findings.md';if(Test-Path -LiteralPath $findings){$FindingsText=[IO.File]::ReadAllText($findings)}}
    if($FindingsText){$lines.Add('');$lines.Add('## Findings');$lines.Add('');$lines.Add($FindingsText.Trim())}
    if($Record.FirmwareContext -and $Record.FirmwareContext.RequiresStaticOnly){
        $lines.Add('');$lines.Add('## Firmware analysis');$lines.Add('')
        $lines.Add('The tools read the firmware files. They did not run the updater or the extracted programs.')
        $lines.Add('This run did not write firmware or settings. It did not unlock a menu.')
        $lines.Add('See [firmware detection and file offsets](basic/firmware-context.json). A detected wrapper does not prove that its payload is valid.')
        if(Test-Path -LiteralPath (Join-Path $RunDirectory 'firmware/firmware-result.json')){$lines.Add('See [extraction results, file lists and tool details](firmware/firmware-result.json).')}
        if(Test-Path -LiteralPath (Join-Path $RunDirectory 'firmware/menu-summary.json')){$lines.Add('See [menu definitions](firmware/menu-summary.json). The FormPackageTextPaths field lists the full form text.')}
        if(Test-Path -LiteralPath (Join-Path $RunDirectory 'firmware/numeric-validation.json')){
            $lines.Add('See [independent checks of menu values](firmware/numeric-validation.json).')
            $lines.Add('IFRExtractor 1.6.1 can decode the high byte incorrectly in EDK2 Label, Timeout, Class and SubClass fields.')
            $lines.Add('The original text remains saved. Separate corrected values require matching source bytes.')
        }
        if(Test-Path -LiteralPath (Join-Path $RunDirectory 'firmware/form-navigation.json')){$lines.Add('See [menu references and conditions](firmware/form-navigation.json). These definitions do not prove that a menu can be reached or displayed.')}
        $lines.Add('Saved defaults do not show the active settings or write access. They do not prove that the firmware applies to the hardware.')
        $lines.Add('Code outside firmware/ belongs to the updater wrapper.')
    }
    $lines.Add('');$lines.Add('## Analysis steps');$lines.Add('')
    foreach($stage in $Record.Stages){
        $label=if($stageNames.ContainsKey([string]$stage.Name)){$stageNames[[string]$stage.Name]}else{[string]$stage.Name}
        $lines.Add("- ${label}: $($stage.Status)")
    }
    if($Record.FunctionIndex.function_count -gt 0){
        $lines.Add('');$lines.Add('## Decompiled functions');$lines.Add('')
        $lines.Add("The tools saved $($Record.FunctionIndex.function_count) functions. The pseudocode shows their estimated behavior. It is not the original source code.")
        $lines.Add('Use the [function list](functions.html) to read the code and processor instructions. The [full index](functions.json) contains file hashes.')
        $lines.Add('This count does not prove that the tools found every function or explain every action.')
    }
    if($Record.PdbContext.Reference -or $Record.TerminalFlow){
        $lines.Add('');$lines.Add('## Debug symbols and function endings');$lines.Add('')
        if($Record.PdbContext.Reference){
            $loaded=if($Record.PdbContext.Loaded){'Yes'}else{'No'}
            $source=if($Record.PdbContext.Source -eq 'Download'){'Downloaded'}elseif($Record.PdbContext.Source -eq 'Local'){'Found locally'}else{[string]$Record.PdbContext.Source}
            $lines.Add('A program database (PDB) file supplies debug data, such as function names.')
            $lines.Add("PDB file: $($Record.PdbContext.Reference.Name). Identity result: $($Record.PdbContext.Status). Source: $source. Loaded: $loaded.")
            $lines.Add('See [PDB search, download and identity results](basic/pdb-context.json).')
        }
        if($Record.TerminalFlow){
            $flow=$Record.TerminalFlow;$complete=if($flow.Complete){'Yes'}else{'No'}
            $lines.Add("The tools examined $($flow.TotalSites) warnings about how functions end.")
            $lines.Add('')
            $lines.Add("- Explained: $($flow.ResolvedSites)");$lines.Add("- Unresolved: $($flow.UnresolvedSites)");$lines.Add("- Jumps to another function: $($flow.TailJumps)");$lines.Add("- Breakpoint instructions: $($flow.Breakpoints)");$lines.Add("- Inspection complete: $complete")
            $lines.Add('')
            if($flow.TailJumps -gt 0){$lines.Add('A tail jump transfers control to another function without adding a new return address.')}
            if($flow.Breakpoints -gt 0){$lines.Add('INT3 is a processor instruction that causes a breakpoint exception if it runs.')}
            $lines.Add('See [results for each warning](code/native/terminal-flow.json). Existing tool assumptions remain separate from these results.')
        }
    }
    $reviews=@($Record.Stages|Where-Object {$_.Name -in 'analysis','detractor','reconciled-findings'})
    if($reviews.Count){$lines.Add('');$lines.Add('## Review checks');$lines.Add('')}
    foreach($stage in $reviews){$label=$stageNames[[string]$stage.Name];$lines.Add("- ${label}: $($stage.SuccessfulEvidenceToolCalls) successful evidence calls. [Tool log](ai/$($stage.Name).stdout).")}
    foreach($stage in $Record.Stages|Where-Object Name -EQ 'Runtime'){
        if($stage.Result.GuestResult.Execution){$lines.Add("Program exit code: $($stage.Result.GuestResult.Execution.ExitCode). Reason: $($stage.Result.GuestResult.Execution.Reason).");$lines.Add('A completed observation does not prove that the application started successfully.')}
        elseif($stage.Result.Runtime){$lines.Add("Program execution observed: $($stage.Result.Runtime.targetExecObserved). Exit code: $($stage.Result.Runtime.exitCode). Reason: $($stage.Result.Runtime.termination).")}
    }
    if($Record.Limitations.Count){
        $lines.Add('');$lines.Add('## Limits and unknowns');$lines.Add('')
        foreach($limit in $Record.Limitations){
            $plain=switch -Regex ([string]$limit){
                '^The matching PDB contains zero TPI type records' {'The PDB has no type records. It does not describe internal data layouts or local variable types.';break}
                '^Runtime execution was not requested' {'This analysis did not run the program. No virtual-machine (VM) results are available.';break}
                default {[string]$limit}
            }
            $lines.Add('- '+$plain)
        }
    }
    $lines.Add('');$lines.Add('Full commands, tool logs and file hashes are in [report.json](report.json). That file also lists the work each tool completed.')
    $lines.Add('The ai/ folder contains the research and review reports.')
    return ($lines -join [Environment]::NewLine)+[Environment]::NewLine
}
