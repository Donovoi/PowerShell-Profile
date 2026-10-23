# Profile reliability checks

Run from a PowerShell 7 session on Windows. No Pester installation is required.

~~~powershell
pwsh -NoProfile -File .\tests\Invoke-ProfileValidation.ps1 -TestRoot "$([Environment]::GetFolderPath('MyDocuments'))\ProfileValidation-$(Get-Date -Format yyyyMMdd-HHmmss)"
~~~

Use a new test directory. The runner preserves logs and fixtures, records the PowerShell/Windows versions in validation.json, and fails if parsing or any test script fails.

| Check | What executes |
| --- | --- |
| ProfileStartup.Behavior | Real function/profile imports with module imports, volume discovery and interactive UI commands mocked. Repeated import, caller preferences, optional tools, bindings, PATH, invocation-time admin guards and screen-event filtering. |
| ProfileAppearance.Behavior | Store/MSIX installation metadata and generated prompt fixtures, built-in fallback, native failures, retry state, and actual PSReadLine Windows/history/Tab/bracket bindings. Network and installation are forbidden in local-startup fixtures. |
| ProfileCore.Behavior | Dependency imports and caches with HTTP mocked; a fresh-session bootstrap; real native child processes for argument boundaries, stdout/stderr, exit codes, stream pressure, timeout cleanup and redirection; BOM fixtures; logger output; elevation payload executed unelevated. |
| ProfileDependencies.Behavior | Actual orchestration and binding against current function signatures, with package installation and SYSTEM APIs mocked. Default and explicit package sets, CurrentUser scope, global imports and error propagation. |
| Install-Profile.Status | Real file-sharing locks, atomic replacement, bounded retries and fallback error reporting. |
| Install-Profile.Integration | Disposable Git/profile directories, loaded fixture DLLs, exact fixture lock-owner termination, detached worker handoff, invalid staging, target restrictions and rollback. |
| Existing thumbnail checks | Import checks and mocked worker behavior; no real Windows thumbnail worker is stopped. |

All script tests passed on PowerShell 7.6.7 / Windows 10.0.26300. Older PowerShell 7 minors, interactive console rendering, actual UAC/SYSTEM launches and live package feeds are not qualified by this suite. Mocked installers prove dispatch and failure handling, not provider/network availability.

## Intentional API corrections

### Packages C–G

The Windows suite also requires `aria2c.exe` on PATH. It uses a loopback HTTP server and disposable local Git remotes; it does not use real credentials, reset user repositories, install a profile, or read raw evidence disks. `ProfileDownloads.Behavior.ps1 -FFmpegFixturePath <existing ffmpeg.exe>` additionally serves a real executable from a local ZIP and verifies extraction, its version and hash.

Run focused static validation with PSScriptAnalyzer 1.25.0:

```powershell
./tests/Invoke-ProfileStaticValidation.ps1 -OutputPath ./static-results.json
```

The checked-in baseline covers C–G production files and the three appearance helpers. Existing warnings are explicitly recorded, including compatibility names, exported variables and inherited sample/helper code. New warnings and all errors fail. Public-command validation rejects duplicate file-level definitions without confusing nested helper functions with public commands. GitHub Actions runs the static gate and Windows regression suite.

| Added test | Evidence |
| --- | --- |
| ProfileArchive.Behavior | Exact ZIP bytes, empty directories, overwrite/WhatIf, traversal, device/ADS paths, duplicates, symlinks and junctions. |
| ProfileDownloads.Behavior | Real native/aria2/RPC loopback transfers, headers, completion, failures, timeout, hashes, lengths, multiple URLs, fallback isolation, cookies, private-release parameter capture and FFmpeg ZIP layout. |
| ProfileSecrets.Behavior | Mocked locked/missing/custom vaults; original secret types retained; no policy reconfiguration or secret-bearing errors. |
| ProfileGit.Behavior | Real local bare remotes; preview, reset/merge/push, recovery of staged/unstaged/untracked work, ignored files, Cargo sentinels, NoPush, divergence, locks, detached HEAD and failed remotes. |
| ProfileSearch.Behavior | Reference filename/content fixtures, Unicode, recursive glob behavior, junction avoidance and mocked Everything ownership. |
| ProfileRawCopy.Behavior | ABI layout, malformed buffers, sparse/multiple extents, partial clusters, EOF, large logical lengths, real file retrieval IOCTL, and mocked VSS cleanup. No raw-device reads. |
| ProfileForensicCopy.Behavior | Regular/LOG/empty file bytes and hashes; partial totals, locked failures, verified adapter contract, stale-output rejection and import order. |
| ProfilePublicCommands.Behavior | Unique public definitions and compatibility imports. |

Downloads emit one path per successful URL. Existing outputs require `-Force`; a failed transfer keeps the prior file. `-AllowEmpty` explicitly allows zero-byte output. `-ExpectedLength` and `-ExpectedSHA256` verify before publication. aria2 URL files accept plain URLs, not arbitrary per-item options. Native cookie authentication uses `-WebSession`; Netscape files require aria2. Google Drive must supply a direct download URL/session; interactive confirmation pages are not handled by this generic downloader.

FFmpeg now defaults to a static-build ZIP. Custom `.7z` and shared DLL builds fail explicitly; the old implementation did not extract them correctly. Existing executables are checked with `-version`. Automatic dependency installation remains available when a function is invoked.

`Get-GitPull -Preview` shows branch, remote URLs, commit IDs, local changes and proposed cleanup. Execution prompts once per repository (`-Confirm:$false` is available after review); `-NoPush` keeps the merge local. Ignored files are preserved, including merge collisions. Submodules, active operations/locks, detached HEAD, assume-unchanged and skip-worktree entries require manual handling. Origin pushes must preserve ancestry and match the previewed remote commit. Recovery refs are retained, and stashed changes are intentionally not reapplied to the synchronized checkout. For recovery into a separate directory:

```powershell
git -C C:\Repo worktree add --detach C:\Recovery refs/profile-sync/ID/head
git -C C:\Recovery stash apply --index refs/profile-sync/ID/worktree
```

Use the actual `RecoveryRef` returned by the command; `/worktree` exists only when there were local changes, and `/target` preserves an existing target branch. On a failed merge, inspect the retained repository state and recovery refs; there is no destructive reset fallback.

The Rust/SIMD experiments are compatibility wrappers over tested PowerShell searches. `Find-FilesRust` searches text and returns `MatchInfo`; `Find-RustyFile` searches filenames; `Find-FilesWithGlobPattern` returns paths. They do not create Cargo/build files. Everything uses an invocation-specific folder-indexing instance when `SearchInDirectory` is supplied, or queries an existing instance otherwise. Its portable default is Everything 1.5.0.1424b with ES 1.1.0.38. Existing INI files and unrelated processes are not changed.

Forensic collection includes LOG files and reports per-file hashes, counts, errors and partial success. Legacy external RawCopy/XCopy/Robocopy adapters are disabled because their previous exit-code/file-existence checks did not establish acquisition correctness. `Invoke-RawCopy` supplies the verified adapter contract. Its extent decoder and copying components are tested, but elevated VSS/raw-volume acquisition remains unqualified. It acquires logical file data, not ADS, ACLs, slack or a disk image. Resident/compressed/encrypted files use a logical snapshot stream. Failed checks do not publish the staged file.

`Set-StoredSecret` requires a registered vault. It uses the default or sole vault unless `-Vault` is supplied; `-SecurePassword` unlocks SecretStore without changing authentication. First-use vault registration/configuration is explicit. SecureString and PSCredential are passed directly to SecretManagement.

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

Packages C–G implement the reviewed download, forensic-layout, Git reset/sync, duplicate-definition and credential-storage corrections described above. Set-InvalidHandle remains unfinished: Get-Handle does not implement the file-handle contract it expects. Moving native compilation into Get-Handle only makes importing that file safe.
