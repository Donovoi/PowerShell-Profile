#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestRoot,[string]$PythonPath)
$ErrorActionPreference='Stop'
$TestRoot=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TestRoot)
if(Test-Path -LiteralPath $TestRoot){throw 'Use a new TestRoot.'}
$null=[IO.Directory]::CreateDirectory($TestRoot)
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/ExecutableAnalysis/Invoke-AnalysisTool.ps1')
. (Join-Path $repo 'scripts/ExecutableAnalysis/Invoke-AnalysisFirmware.ps1')
function Assert-True([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Throws([scriptblock]$Body,[string]$Pattern){try{& $Body;throw 'Expected exception'}catch{if($_.Exception.Message -notmatch $Pattern){throw}}}
if(-not $PythonPath){$PythonPath=(Get-Command python -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source}
if(-not $IsWindows){throw 'These native fixture tests require Windows and the system .NET Framework C# compiler.'}
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){throw 'The system .NET Framework C# compiler is required for native test fixtures.'}
$toolSource=Join-Path $TestRoot 'ToolFixture.cs'
$toolExe=Join-Path $TestRoot 'ToolFixture.exe'
[IO.File]::WriteAllText($toolSource,@'
using System;
using System.IO;
public class ToolFixture {
    public static int Main(string[] args) {
        string mode = Environment.GetEnvironmentVariable("FIRMWARE_TEST_CASE") ?? "success";
        bool ifr = args.Length > 1 && args[1] == "verbose";
        if (mode == "uefi-nonzero" && !ifr) return 13;
        if (mode == "ifr-nonzero" && ifr) return 17;
        // Captured IFRExtractor 1.6.1 stdout/exit pairs from the pinned Dell run.
        if (mode == "no-forms" && ifr) { Console.Write("No IFR data found\n"); return 2; }
        if (mode == "insufficient-ifr" && ifr) { Console.Write("Not enough IFR data found to complete extraction\n"); return 3; }
        if (mode == "ifr-noforms-exit1" && ifr) { Console.Write("No IFR data found\n"); return 1; }
        if (mode == "ifr-unexpected-exit1" && ifr) { Console.WriteLine("Unexpected failure"); return 1; }
        if (mode == "ifr-unexpected-exit2" && ifr) { Console.WriteLine("Unexpected failure"); return 2; }
        if (mode == "ifr-unexpected-exit3" && ifr) { Console.WriteLine("Unexpected failure"); return 3; }
        if (mode == "ifr-noforms-stderr" && ifr) { Console.Write("No IFR data found\n"); Console.Error.WriteLine("Parser problem"); return 2; }
        if (mode == "ifr-insufficient-stderr" && ifr) { Console.Write("Not enough IFR data found to complete extraction\n"); Console.Error.WriteLine("Parser problem"); return 3; }
        if (mode == "input-changed") File.WriteAllText(Environment.GetEnvironmentVariable("FIRMWARE_TEST_SOURCE"), "CHANGED");
        if (ifr) {
            if (mode == "long-ifr-line") {
                File.WriteAllText(args[0] + ".0.0.en-US.uefi.ifr.txt", new string('X', 34 * 1024 * 1024));
                return 0;
            }
            File.WriteAllText(args[0] + ".0.0.en-US.uefi.ifr.txt", "0x100: FormSet Guid: 1234, Title: \"Fixture\" { 00 }\n0x120: Form FormId: 0x1, Title: \"Setup\" { 00 }\n0x130: OneOf Prompt: \"Boot mode\", Help: \"Fixture only\" { 00 }\n");
        } else {
            if (mode == "uefi-warning") {
                // Exact warning excerpts from UEFIExtract NE A75 on the Dell package.
                Console.WriteLine("FfsParser::parseVolumeBody: file header parsing failed with invalid size");
                Console.WriteLine("FitParser::parseFitEntryAcm: Intel ACM with unknown header version 00040000h found");
            }
            for (int n = 0; n < 2; n++) {
                string dir = Path.Combine(args[0] + ".dump", n + " Setup", "2 PE32 image section");
                Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, "body.bin"), "PE32 STATIC FIXTURE " + n);
            }
        }
        return 0;
    }
}
'@)
$targetSource=Join-Path $TestRoot 'TargetFixture.cs'
$target=Join-Path $TestRoot 'target [literal] & never-run.exe'
$sentinel=Join-Path $TestRoot 'TARGET-WAS-EXECUTED'
[IO.File]::WriteAllText($targetSource,@'
using System;
using System.IO;
public class TargetFixture {
    public static int Main() {
        File.WriteAllText(Environment.GetEnvironmentVariable("FIRMWARE_TEST_SENTINEL"), "Target was executed");
        return 93;
    }
}
'@)
& $compiler /nologo /target:exe ("/out:"+$toolExe) $toolSource
Assert-True ($LASTEXITCODE -eq 0) 'Native analysis-tool fixture compilation failed.'
& $compiler /nologo /target:exe ("/out:"+$target) $targetSource
Assert-True ($LASTEXITCODE -eq 0) 'Native never-run target fixture compilation failed.'
$original=[IO.File]::ReadAllBytes($target)
$hash=(Get-FileHash -LiteralPath $target).Hash
$library=Join-Path $TestRoot 'mock parser'
$package=Join-Path $library 'biosutilities'
$dependencies=Join-Path $TestRoot 'empty isolated dependencies'
$null=[IO.Directory]::CreateDirectory($package)
$null=[IO.Directory]::CreateDirectory($dependencies)
[IO.File]::WriteAllText((Join-Path $package '__init__.py'),'')
# This deliberately mocked parser emits checksum-valid UEFI FV fixture headers.
# Tests qualify orchestration and containment, never Dell parser correctness.
[IO.File]::WriteAllText((Join-Path $package 'dell_pfs_extract.py'),@'
from pathlib import Path
import os, struct, time
class DellPfsExtract:
    def __init__(self, input_object, extract_path, advanced, structure):
        assert advanced is True and structure is True
        self.input_buffer = Path(input_object).read_bytes()
        self.root = Path(extract_path)
    def _is_pfs_pkg(self, value):
        return False
    def check_format(self):
        return os.environ.get('FIRMWARE_TEST_CASE') != 'malformed'
    def parse_format(self):
        mode = os.environ.get('FIRMWARE_TEST_CASE', 'success')
        if mode == 'pfs-nonzero':
            raise RuntimeError('Fixture PFS failure')
        if mode == 'timeout':
            time.sleep(30)
        if mode == 'memory-limit':
            bytearray(512 * 1024 * 1024)
        if mode == 'unsafe-path':
            (self.root.parent.parent / 'ESCAPED').write_text('bad')
        if mode == 'unsafe-link':
            os.symlink(str(self.root.parent.parent), str(self.root / 'link'))
        if mode == 'process-attempt':
            import subprocess
            subprocess.run([os.environ['FIRMWARE_TEST_SOURCE']], check=False)
        if mode == 'output-limit':
            (self.root / 'oversize.data.bin').write_bytes(b'X' * 2 * 1024 * 1024)
        if mode == 'file-limit':
            for i in range(50):
                (self.root / ('item-%d.bin' % i)).write_bytes(b'X')
        if mode == 'pfs-warning':
            print('Warning: Filled sub-PFS PFAT 1 data gap 0xC00000 with 0xFF')
        if mode == 'metadata-warning':
            for i in range(3000):
                # Captured Dell BIOSUtilities structural-field forms, followed
                # by the exact real gap-fill warning from 0001-PFS.stdout.
                print(('Unknown 0: 0x2', 'Unknown 1: 0x4', 'Unknown 2: 0x1', 'Unknown 3: 0x0', 'Unknown                : 0x0123456789')[i % 5])
            print('Warning: Filled sub-PFS PFAT 1st data gap 0xC00000 [0x0-0xC00000]!')
        if mode == 'diagnostic-limit':
            for i in range(2050):
                print('Warning: fixture %d' % i)
        for name in ('Type3', 'Type4'):
            data = bytearray(64)
            struct.pack_into('<Q', data, 32, 64)
            data[40:44] = b'_FVH'
            struct.pack_into('<H', data, 48, 56)
            struct.pack_into('<H', data, 50, (-sum(struct.unpack_from('<28H', data))) & 65535)
            (self.root / (name + '.data.bin')).write_bytes(data)
        return True
'@)
$tools=@{Python=$PythonPath;BIOSUtilities=$library;UEFIExtract=$toolExe;IFRExtractor=$toolExe;PythonDependencies=$dependencies}
$saved=@{}
foreach($name in @('FIRMWARE_TEST_CASE','FIRMWARE_TEST_SOURCE','FIRMWARE_TEST_SENTINEL')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$env:FIRMWARE_TEST_SOURCE=$target
$env:FIRMWARE_TEST_SENTINEL=$sentinel
function Invoke-Fixture {
    [CmdletBinding()]
    param([string]$Name,[int]$Timeout=30,[long]$Bytes=64MB,[int]$Files=1000,[int]$Modules=1024,[long]$Memory=2GB)
    $env:FIRMWARE_TEST_CASE=$Name
    Invoke-AnalysisFirmware -InputPath $target -OutputDirectory (Join-Path $TestRoot $Name) -Tools $tools -LogDirectory (Join-Path $TestRoot 'logs') -TimeoutSeconds $Timeout -MaxOutputBytes $Bytes -MaxFiles $Files -MaxIFRModules $Modules -MaxMemoryBytes $Memory
}
try{
    $result=Invoke-Fixture success
    Assert-True ($result.Status -eq 'Succeeded' -and $result.Manifest.InputUnchanged -and -not $result.TargetExecuted) ('Successful fixture pipeline failed: '+($result.Manifest.Diagnostics|ConvertTo-Json -Compress))
    Assert-True ($result.Manifest.Variants.Count -eq 2 -and $result.Manifest.Summary.PE32Bodies -eq 4 -and $result.Manifest.Summary.UniqueIFRModulesScanned -eq 2) 'Variant preservation or PE32 hash deduplication failed.'
    Assert-True ($result.FormPackageTextPaths.Count -eq 2 -and (Test-Path -LiteralPath $result.MenuSummaryPath)) 'IFR outputs or bounded menu summary were not returned.'
    Assert-True ((Test-Path -LiteralPath $result.NumericValidationPath) -and $result.Manifest.Summary.NumericValidationCoverageComplete -and $result.Manifest.Summary.NumericValidationChecked -eq 0) 'Separate numeric-validation scope/coverage was not returned for a fixture without GUID extensions.'
    Assert-True ($result.Manifest.ToolCalls.Count -eq 5 -and $result.Manifest.Summary.InventoryComplete) 'Tool call provenance or inventory is incomplete.'
    foreach($file in $result.Manifest.Files){
        Assert-True ((Get-FileHash -LiteralPath (Join-Path (Join-Path $TestRoot 'success') $file.Path)).Hash -eq $file.SHA256) 'Recorded artifact hash does not match bytes.'
        if($file.Stage -in 'PFS','UEFI','IFR'){Assert-True ([bool]$file.ParentSHA256) 'Extracted artifact lacks a hashed parent.'}
    }
    Assert-True (-not(Test-Path -LiteralPath $sentinel) -and (Get-FileHash -LiteralPath $target).Hash -eq $hash) 'The target was executed or changed.'
    Write-Output 'PASS: both firmware variants, static-only target, isolated dependencies, complete tool/file hashes, parent provenance, IFR hash deduplication and menu summary.'
    $result=Invoke-Fixture no-forms
    Assert-True ($result.Status -eq 'Succeeded' -and $result.Manifest.Summary.IFRNoForms -eq 2 -and $result.Manifest.Summary.FailedToolCalls -eq 0 -and $result.FormPackageTextPaths.Count -eq 0) 'Explicit no-IFR observations were treated as extraction failures.'
    Assert-True (@($result.Manifest.ToolCalls|Where-Object { $_.Stage -eq 'IFR' -and $_.Status -eq 'NoForms' -and $_.ExitCode -eq 2 }).Count -eq 2) 'Captured no-IFR exit code was not preserved.'
    $result=Invoke-Fixture insufficient-ifr
    Assert-True ($result.Status -eq 'Partial' -and $result.Manifest.Summary.IFRInsufficientData -eq 2 -and $result.Manifest.Summary.IFRNoForms -eq 0 -and $result.Manifest.Summary.FailedToolCalls -eq 0 -and @($result.Manifest.Diagnostics|Where-Object Message -Match 'Not enough IFR data found to complete extraction').Count -eq 2) 'Captured insufficient-IFR data was hidden or misclassified as absent forms.'
    Assert-True (@($result.Manifest.ToolCalls|Where-Object { $_.Stage -eq 'IFR' -and $_.Status -eq 'InsufficientData' -and $_.ExitCode -eq 3 }).Count -eq 2) 'Captured insufficient-IFR exit code was not preserved.'
    $result=Invoke-Fixture metadata-warning
    Assert-True ($result.Status -eq 'Partial' -and -not $result.Manifest.DiagnosticsTruncated -and $result.Manifest.Diagnostics.Count -eq 1 -and $result.Manifest.Diagnostics[0].Message -match 'Filled sub-PFS PFAT') 'Structural Unknown fields consumed the warning budget or hid a real PFAT warning.'
    $result=Invoke-Fixture diagnostic-limit
    Assert-True ($result.Status -eq 'Partial' -and $result.Manifest.DiagnosticsTruncated -and $result.Manifest.Diagnostics.Count -eq 2048 -and $result.Manifest.DiagnosticsOmitted -eq 2) 'The bounded diagnostic list concealed omitted warning messages.'
    foreach($case in @('pfs-warning','uefi-warning','uefi-nonzero','ifr-nonzero','ifr-noforms-exit1','ifr-unexpected-exit1','ifr-unexpected-exit2','ifr-unexpected-exit3','ifr-noforms-stderr','ifr-insufficient-stderr')){
        $result=Invoke-Fixture $case
        Assert-True ($result.Status -eq 'Partial' -and $result.Manifest.Diagnostics.Count -gt 0 -and $result.InputUnchanged) ('Warning or nonzero exit was hidden: '+$case)
        if($case -eq 'uefi-warning'){
            Assert-True (@($result.Manifest.Diagnostics|Where-Object Message -Match 'file header parsing failed with invalid size').Count -eq 2 -and @($result.Manifest.Diagnostics|Where-Object Message -Match 'Intel ACM with unknown header version 00040000h found').Count -eq 2) 'Captured UEFI header/ACM warnings were filtered out.'
        }
    }
    foreach($case in @('malformed','pfs-nonzero','unsafe-path','unsafe-link','process-attempt')){
        $result=Invoke-Fixture $case
        Assert-True ($result.Status -eq 'Failed' -and $result.Manifest.Diagnostics.Count -gt 0 -and $result.InputUnchanged) ('Parser failure/containment was hidden: '+$case)
    }
    Assert-True (-not(Test-Path -LiteralPath (Join-Path $TestRoot 'ESCAPED')) -and -not(Test-Path -LiteralPath $sentinel)) 'Parser escaped its output root or executed the target.'
    Write-Output 'PASS: warnings remain Partial; nonzero exits, malformed inputs, outside-root writes, links and parser execution are rejected.'
    $result=Invoke-Fixture timeout -Timeout 5
    Assert-True ($result.Status -eq 'Failed' -and (($result.Manifest.Diagnostics|ConvertTo-Json) -match 'timeout') -and $result.InputUnchanged) 'Timeout was not terminated and recorded.'
    $result=Invoke-Fixture memory-limit -Memory 256MB
    Assert-True ($result.Status -eq 'Failed' -and $result.InputUnchanged) 'Windows job memory limit was not enforced.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $TestRoot 'memory-limit/tool-logs/0001-PFS.stderr') -Raw) -match 'MemoryError') 'Memory failure did not originate from the bounded parser allocation.'
    $result=Invoke-Fixture output-limit -Bytes 1MB
    Assert-True ($result.Status -eq 'Failed' -and -not $result.Manifest.Summary.InventoryComplete -and (($result.Manifest.Diagnostics|ConvertTo-Json) -match 'limit')) 'Output byte limit did not stop or disclose incomplete inventory.'
    $result=Invoke-Fixture file-limit -Files 20
    Assert-True ($result.Status -eq 'Failed' -and -not $result.Manifest.Summary.InventoryComplete) 'Output file limit did not stop extraction.'
    $result=Invoke-Fixture module-limit -Modules 1
    Assert-True ($result.Status -eq 'Partial' -and $result.Manifest.Summary.UniqueIFRModulesScanned -eq 1 -and $result.Manifest.Variants.Count -eq 2) 'IFR module limit lost variants or overclaimed complete coverage.'
    $result=Invoke-Fixture long-ifr-line -Modules 1
    $menu=Get-Content -LiteralPath $result.MenuSummaryPath -Raw|ConvertFrom-Json
    Assert-True ($result.Status -eq 'Partial' -and $menu.Truncated -and $menu.ReadLimitBytes -eq 32MB -and $menu.ReadBytes -eq (32MB+1) -and $menu.ReadSentinelBytes -eq 1) 'A long IFR line exceeded its bounded read or the summary masked bytes actually read.'
    $result=Invoke-Fixture input-changed
    Assert-True ($result.Status -eq 'Failed' -and -not $result.InputUnchanged -and -not $result.Manifest.InputUnchanged) 'Changed source bytes were accepted.'
    [IO.File]::WriteAllBytes($target,$original)
    Write-Output 'PASS: timeout, Windows job memory limit, output byte/file/module budgets and independent source preservation failure.'
    Assert-Throws {Invoke-Fixture success|Out-Null} 'must not exist'
    $badTools=$tools.Clone();$badTools.Python=$target
    Assert-Throws {Invoke-AnalysisFirmware -InputPath $target -OutputDirectory (Join-Path $TestRoot 'bad-tool') -Tools $badTools -LogDirectory (Join-Path $TestRoot 'logs')|Out-Null} 'Input content cannot be used'
    $link=Join-Path $TestRoot 'junction'
    $null=New-Item -ItemType Junction -Path $link -Target $dependencies
    Assert-Throws {Invoke-AnalysisFirmware -InputPath $target -OutputDirectory (Join-Path $link 'output') -Tools $tools -LogDirectory (Join-Path $TestRoot 'logs')|Out-Null} 'reparse'
    Assert-True (-not(Test-Path -LiteralPath $sentinel)) 'The executable input ran during a preflight rejection.'
    Write-Output 'PASS: existing output, reparse output and target-as-tool configurations fail before execution.'
}finally{
    [IO.File]::WriteAllBytes($target,$original)
    foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}

$numericTest=Join-Path $TestRoot 'NumericValidationTests.py'
[IO.File]::WriteAllText($numericTest,@'
import hashlib, importlib.util, pathlib, sys
worker_path, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
root.mkdir()
spec = importlib.util.spec_from_file_location('firmware_worker', worker_path)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
prefix = bytes.fromhex('5F 15 35 17 0B 0F A0 87 93 41 B2 66 53 8C 38 AF 48 CE')
guid = '0F0B1735-87A0-4193-B266-538C38AF48CE'
def fixture(name, extension, field, code, offset, value, rendered, source_delta=0):
    folder = root / name
    folder.mkdir()
    opcode = prefix + bytes([code]) + value.to_bytes(2, 'little')
    module = bytearray(offset + len(opcode))
    module[offset:offset + len(opcode)] = opcode
    module[offset] ^= source_delta
    (folder / 'module.bin').write_bytes(module)
    text = folder / 'module.bin.0.0.en-US.uefi.ifr.txt'
    text.write_text(f'0x{offset:X}: \tGuid Guid: {guid}, ExtendedOpCode: {extension}, {field}: 0x{rendered:X} {{ {opcode.hex(" ").upper()} }}\n')
    return text

# Exact verified offsets/values captured from the pinned Dell package output:
# module-0008 line3; module-0013 line3; module-0021 .4.0 line14.
captured = [fixture('captured-class-0655', 'Class', 'Class', 3, 0x947F, 0x655, 0x2AD),
            fixture('captured-class-0786', 'Class', 'Class', 3, 0x3B2F, 0x786, 0x342),
            fixture('captured-label-1000', 'Label', 'LabelNumber', 0, 0x8C3FB, 0x1000, 0x640)]
sources = [item for text in captured for item in (text, text.parent / 'module.bin')]
before = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
result = worker.validate_ifr_numeric_values(root, captured)
assert result['Status'] == 'Partial' and result['Checked'] == 3 and result['Mismatches'] == 3 and result['CoverageComplete']
assert [row['ActualLEValue'] for row in result['Records']] == [0x655, 0x786, 0x1000]
assert all(row['SourceBytesVerified'] and row['ModuleSHA256'] for row in result['Records'])
assert {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources} == before

other_extensions = [fixture('timeout', 'Timeout', 'Timeout', 2, 32, 0x100, 0x64),
                    fixture('subclass', 'SubClass', 'SubClass', 4, 32, 0x200, 0xC8)]
result = worker.validate_ifr_numeric_values(root, other_extensions)
assert result['Checked'] == 2 and result['Mismatches'] == 2 and result['CoverageComplete']

good = [fixture('good-class', 'Class', 'Class', 3, 8, 0x60, 0x60),
        fixture('good-timeout', 'Timeout', 'Timeout', 2, 8, 7, 7),
        fixture('good-subclass', 'SubClass', 'SubClass', 4, 8, 2, 2)]
result = worker.validate_ifr_numeric_values(root, good)
assert result['Status'] == 'Succeeded' and result['Checked'] == 3 and result['Matches'] == 3 and result['Records'] == []

bad = fixture('wrong-source-offset', 'Class', 'Class', 3, 32, 0x655, 0x2AD, source_delta=1)
result = worker.validate_ifr_numeric_values(root, [bad])
assert result['Status'] == 'Partial' and result['Checked'] == 0 and result['Unverified'] == 1
assert result['Records'][0]['ActualLEValue'] is None and not result['Records'][0]['SourceBytesVerified']
assert 'does not match module bytes' in result['Records'][0]['Reason']

result = worker.validate_ifr_numeric_values(root, captured, read_limit=100)
assert result['Status'] == 'Partial' and not result['ScanComplete'] and not result['CoverageComplete']
assert result['ReadBytes'] == 101 and result['ReadSentinelBytes'] == 1 and result['Checked'] == 0
result = worker.validate_ifr_numeric_values(root, captured, max_records=1)
assert result['Checked'] == 3 and result['Mismatches'] == 3 and len(result['Records']) == 1
assert result['SkippedBeyondCap'] == 2 and not result['CoverageComplete'] and result['ScanComplete']

long_file = root / 'long.ifr.txt'
long_file.write_bytes(b'X' * 1000 + b'\n')
result = worker.validate_ifr_numeric_values(root, [long_file], line_limit=128)
assert result['ReadBytes'] == 1001 and result['SkippedLongLines'] == 1 and not result['CoverageComplete']
assert result['ScanComplete'] and result['Checked'] == 0
print('PASS: captured numeric rendering mismatches, all four GUID fields, matching values, source-byte verification, preservation, bounded reads/lines/records and explicit coverage.')
'@)
& $PythonPath -I -S -B $numericTest (Join-Path $repo 'scripts/ExecutableAnalysis/firmware-worker.py') (Join-Path $TestRoot 'numeric-fixtures')
Assert-True ($LASTEXITCODE -eq 0) 'Numeric validation regressions failed.'
