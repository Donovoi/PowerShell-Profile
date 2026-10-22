# Profile reliability checks

Run from a PowerShell 7 session on Windows. No Pester installation is required.

~~~powershell
pwsh -NoProfile -File .\tests\Invoke-ProfileValidation.ps1 -TestRoot "$([Environment]::GetFolderPath('MyDocuments'))\ProfileValidation-$(Get-Date -Format yyyyMMdd-HHmmss)"
~~~

Use a new test directory. The runner preserves logs and fixtures, records the PowerShell/Windows versions in validation.json, and fails if parsing or any test script fails.

| Check | What executes |
| --- | --- |
| ProfileStartup.Behavior | Real function/profile imports with module imports, volume discovery and interactive UI commands mocked. Repeated import, caller preferences, optional tools, bindings, PATH, invocation-time admin guards and screen-event filtering. |
| ProfileCore.Behavior | Dependency imports and caches with HTTP mocked; a fresh-session bootstrap; real native child processes for argument boundaries, stdout/stderr, exit codes, stream pressure, timeout cleanup and redirection; BOM fixtures; logger output; elevation payload executed unelevated. |
| ProfileDependencies.Behavior | Actual orchestration and binding against current function signatures, with package installation and SYSTEM APIs mocked. Default and explicit package sets, CurrentUser scope, global imports and error propagation. |
| Install-Profile.Status | Real file-sharing locks, atomic replacement, bounded retries and fallback error reporting. |
| Install-Profile.Integration | Disposable Git/profile directories, loaded fixture DLLs, exact fixture lock-owner termination, detached worker handoff, invalid staging, target restrictions and rollback. |
| Existing thumbnail checks | Import checks and mocked worker behavior; no real Windows thumbnail worker is stopped. |

All script tests passed on PowerShell 7.6.7 / Windows 10.0.26300. Older PowerShell 7 minors, interactive console rendering, actual UAC/SYSTEM launches and live package feeds are not qualified by this suite. Mocked installers prove dispatch and failure handling, not provider/network availability.

## Intentional API corrections

- Importing the profile no longer installs tools. Invoke-OhMyPoshRandomTheme still automatically installs its missing executable when called directly. Startup uses its new LocalOnly mode.
- Initialize-CmdletDependencies imports into global scope, verifies exports, forwards repository/timeout options, and throws after bounded retries (default: three). Already available commands are reused unless Force is specified.
- Install-Cmdlet returns cached path strings with PreferLocal and PSModuleInfo otherwise. Both modes import commands globally. Warm cache use does not download; Force refreshes only after download and syntax validation. WhatIf does not download, import or create a cache.
- Install-PSModule combines default and explicit modules, imports globally and propagates installation/import failures. Install-Dependencies does not restart the shell for CurrentUser installation.
- Invoke-Process takes one unquoted string per native argument. Default output is complete stdout lines; stderr uses tagged information records. PassThru returns Id, ExitCode, StandardOutput and StandardError. Nonzero exits throw unless IgnoreExitCode is supplied. TimeoutSeconds bounds execution/output draining. Output is collected before emission; live line-by-line streaming is not provided. Wait and NoNewWindow remain compatibility switches. Unsupported Start-Process options now fail parameter binding; use Start-Process directly for credentials, verbs or shell-document launches.
- Get-FileEncoding returns null for BOMless files unless FallbackEncoding is supplied. Test-ByteOrderMark retains its encoding-or-false contract. UTF-7 is not inferred.
- Start-AsAdmin and Invoke-RunAsAdmin never exit the caller. Supply FilePath and individual ArgumentList values to run a script; no FilePath opens an elevated interactive shell. Get-SYSTEM, Restore-WinMgmt and Set-SOE require an already elevated session when invoked.
- Find-ScreenTrouble returns relevant System warning/error events using Get-WinEvent. The former placeholder flicker tests and speculative diagnosis were removed; active display testing remains unimplemented.
- Write-Logg needs no dependencies for ordinary console/file logging. Existing NoLogFile and ForegroundColor calls remain supported; file logging stays opt-in.

The corrected CsWin32 dependency table pins [0.3.366](https://www.nuget.org/packages/Microsoft.Windows.CsWin32/0.3.366), a published package version. Binding is tested; the unfinished DLL-generation workflow is not validated end to end.

The broader review's download, forensic-layout, Git reset/sync, full deduplication and credential-storage packages remain separate work. Set-InvalidHandle is also still unfinished: Get-Handle does not implement the file-handle contract it expects. Moving native compilation into Get-Handle only makes importing that file safe.
