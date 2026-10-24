# Profile reliability checks

Run from a PowerShell 7 session on Windows. No Pester installation is required.

~~~powershell
pwsh -NoProfile -File .\tests\Invoke-ProfileValidation.ps1 -TestRoot "$([Environment]::GetFolderPath('MyDocuments'))\ProfileValidation-$(Get-Date -Format yyyyMMdd-HHmmss)"
~~~

Use a new test directory. The runner preserves logs and fixtures, records the PowerShell/Windows versions in validation.json, and fails if parsing or any test script fails.

| Check | What executes |
| --- | --- |
| ProfileStartup.Behavior | Real function/profile imports with module imports, volume discovery and interactive UI commands mocked. Repeated import, caller preferences, optional tools, bindings, PATH, invocation-time admin guards and screen-event filtering. |
| ProfileAppearance.Behavior | Store/MSIX installation metadata and generated prompt fixtures, built-in fallback, native failures, retry state, every custom PSReadLine binding and directory-bookmark preservation on reload. Network and installation are forbidden in local-startup fixtures. |
| ProfileExecutableAnalysis.Behavior | Input preservation, exact artifact hashes, literal paths, default/unique output, WhatIf, format discrimination, decoding, OS routing with mocked VM helpers, native argument/timeout/output bounds, independent provider resolution and false AI-success rejection. |
| ProfileAnalysisBridge.Behavior | A local fake MCP peer exercises session ownership, literal paths, actual coverage, function/evidence limits, timeouts, malformed UTF-8/JSON, provider errors, version mismatch, input mutation and failed extraction/evidence retention. Requires Node.js; no external provider or network. |
| ProfileAnalysisVm.Behavior | Linux VM preflight, format rejection and containment checks with fixture state. Does not start or modify a real VM. |
| ProfileAnalysisWindowsVm.Behavior | Windows PE rejection, isolation requirements, exclusive locks, guest success/failure, controller/task-result disagreements, standard account/profile checks, snapshot-restoration failure, credential cleanup and WhatIf with mocked VirtualBox. Real watchdog launcher/child parameter boundaries accept the full 2,100-second licensed deadline and reject invalid ranges using an inert ownership manifest before any VM access. Fresh-setup checks cover verified reboot boundaries, powered-off CPU changes, unquoted numeric settings, unexpected shutdown and failed topology verification. Does not start or modify a real VM. |
| ProfileAnalysisWindowsPayload.Behavior | Real disposable payload files and ZIP extraction: entry-point and companion bytes, empty directories, hashes, final source inventory, corrupt archives/manifests, unsafe/duplicate paths, resource limits, overlap refusal and extended Windows paths. Executes the guest extractor under PowerShell 7 and Windows PowerShell 5.1 without running target code. |
| ProfileAnalysisWindowsSession.Behavior | Parses the guest asset and compiles native declarations without invoking session APIs. Tests private JSON handling, mutation-lock collisions, readiness retries, disabled autologon counters and existing-secret refusal. Mocked watchdog cases cover matching/invalid cancellation, running/paused expiry, changed UUID and unexpected VM state. Bounded deployment diagnostics preserve native errors and activity IDs. An actual Windows PowerShell 5.1 missing-file WinRT request verifies COM interface projection; typed fixtures test result/cancellation handling. No AppX deployment or registry, LSA, session, task or VM changes. |
| ProfileAnalysisWindowsDeploymentProfile.Behavior | Compiles native declarations under PowerShell 7 and Windows PowerShell 5.1, then uses fake APIs to test local administrator identity, profile ownership, exact privilege restoration, normal-profile proof, ABI layouts, failure preservation and release of only the acquired handle. Existing profiles are preserved. No host profile or token changes. |
| ProfileAnalysisWindowsActivationDiagnostics.Behavior | Fake event APIs exercise six fixed channels, bounded time and text, exact package-identity attribution, unavailable/disabled channels, native errors and artifact size limits. No host events are queried or log settings changed. |
| ProfileAnalysisWindowsObservationBounds.Behavior | Compiles actual native recording helpers under PS7/PS5.1 and feeds adversarial process/window histories without invoking native APIs. Checks cumulative counts, text truncation, partial-result reasons and the report size budget. |
| ProfileAnalysisWindowsPackageInput.Behavior | Real inert ZIP/XML fixtures exercise complete file equivalence, ZIP64, strict URI decoding, bounded metadata/expansion, source locks, mutation, traversal/collisions, XML safety and WhatIf. No package deployment. |
| ProfileAnalysisWindowsLicensedDeployment.Behavior | Fake filesystem and DISM boundaries verify exact private package/license inputs, native error preservation, restart handling and rejection before deployment. Runs under PS7 and PS5.1; no host package changes. |
| ProfileAnalysisWindowsProgress.Behavior | Actual PowerShell and native checkpoint writers exercise atomic replacement, bounded histories and metadata, failed writes, and PS7/PS5.1 compatibility. Checkpoints remain diagnostic evidence and cannot replace a final runtime report. No target or native activation APIs execute on the host. |
| ProfileAnalysisWindowsTokenInspection.Behavior | The actual native identity helper inspects only its test process token under PS7/PS5.1. Verifies query/duplicate access, identity and administrator evidence, failure-operation preservation and unchanged caller identity. No target activation or VM changes. |
| ProfileAnalysisWindowsFileInventory.Behavior | Actual inventory and finalization logic with real inert files plus a deterministic clock: streaming cancellation, elapsed/entry quotas, read errors, partial coverage and final-report preservation after a primary launch failure. Runs under PS7/PS5.1. |
| ProfileAnalysisWindowsInventorySink.Behavior | Actual file, registry and connection collectors publish bounded scalar records and progress. Tests retain rows on failures, enforce row/text limits and avoid materializing unlimited registry data. Runs under PS7/PS5.1. |
| ProfileAnalysisWindowsInventoryWorker.Behavior | Actual runspace workers and finalization face real 60-second blocked native calls in owned child processes. Tests verify timely partial snapshots, final-report persistence, original-error preservation, nonzero exit on write failure and no caller termination without runner ownership. Runs under PS7/PS5.1. |
| ProfileCore.Behavior | Dependency imports and caches with HTTP mocked; a fresh-session bootstrap; real native child processes for argument boundaries, stdout/stderr, exit codes, stream pressure, timeout cleanup and redirection; BOM fixtures; logger output; elevation payload executed unelevated. |
| ProfileDependencies.Behavior | Actual orchestration and binding against current function signatures, with package installation and SYSTEM APIs mocked. Default and explicit package sets, CurrentUser scope, global imports and error propagation. |
| Install-Profile.Status | Real file-sharing locks, atomic replacement, bounded retries and fallback error reporting. |
| Install-Profile.Integration | Disposable Git/profile directories, loaded fixture DLLs, exact fixture lock-owner termination, detached worker handoff, invalid staging, target restrictions and rollback. |
| Existing thumbnail checks | Import checks and mocked worker behavior; no real Windows thumbnail worker is stopped. |

The previously recorded suite baseline passed on PowerShell 7.6.7 / Windows 10.0.26300. The additional packaged-runtime checks and their qualification status are described below; they must also pass before publishing these changes. Older PowerShell 7 minors, interactive console rendering, actual UAC/SYSTEM launches and live package feeds are not qualified by deterministic tests. Mocked installers prove dispatch and failure handling, not provider/network availability.

## Executable-analysis integration qualification

Separate local checks on 23 October 2026 used real providers and benign, known-answer fixtures:

| Integration | Verified result |
| --- | --- |
| REA 6.7.0 / Ghidra 12.1 native PE | Discovered and decompiled the fixture function returning 42; retained evidence and unchanged input hash. |
| Direct Ghidra ELF and thin Mach-O | Recovered the corresponding function returning 42, including literal metacharacters in input paths. REA's Windows admission failure remains recorded separately. |
| Managed PE / ILSpy 11.1.0.9782 | Exported the expected C# project, greeting and addition method, with input hash and invocation provenance. |
| WABT 1.0.42 / WASM | Retained WAT with the expected exported function and `i32.const 42`. |
| JADX 1.5.6 / Java class | Recovered the expected Java method returning 42 and its fixture string. The unavailable REA class-file route remains explicit. |
| REA ZIP extraction | Retained `hello.txt` with exact expected bytes and provider-inventory hash/length checks. |
| REA ASAR extraction | A real archive fixture retained exact `package.json`, JavaScript `knownAnswer = 42`, and unpacked native-member bytes. Semantic partial/unknown coverage remains partial. Protocol fixtures additionally cover bounded selection, extraction limits, strict integrity rejection and explicit untrusted recovery. |
| Codex CLI 0.163.0 | Actual completed web retrieval, analysis, independent detractor review and reconciliation; the latest complete managed-fixture run recorded eight web searches. Provider/tool errors and fabricated research success are separately tested as failures/partial results. |
| Linux VirtualBox runtime | Fresh Ubuntu provisioning, expected stdout/exit from a benign ELF, timeout termination, hash and offline/unprivileged checks, clean snapshot restoration and powered-off end state. Lock contention and failed-preflight lock release were also checked. |
| Windows VirtualBox runtime | Native PE stdout/exit/file and managed PE stdout/stderr/exit/file/HKCU values matched known fixtures. Created-file hashes matched expected contents. A three-second deadline terminated a job containing the target and child processes, returning the expected partial timeout result. Standard account, loaded profile, canonical TEMP path, task/credential cleanup, input hashes, exact clean snapshot restoration and final power-off were verified. |

These fixtures qualify the exercised adapters, not all input formats, arbitrary protected programs, every guest execution path or complete semantic recovery. Real interactive installed-profile checks separately verify Oh My Posh rendering and custom keybindings; CI uses controlled startup fixtures.

Package-context regression checks exercise actual junction refusal, source/copy hashes, direct-ASAR copy reuse, metadata/byte/entry/depth limits, safe XML parsing and overwrite refusal. Top-level Windows runtime routing now passes the original selected executable and bounded application-root options to the layout-aware adapter, with an expected input hash; it must not reduce a detected package to the preserved single executable. Unverifiable context remains an explicit failure/unsupported result. Guest exception diagnostics are tested under Windows PowerShell 5.1 as well as through the mocked orchestration boundary; nonzero target exit codes remain explicit partial outcomes.

An installed Codex desktop package (`26.1016.8622.0`) was examined separately on 24 October 2026. The manifest identified `ChatGPT.exe` as the desktop entry point; `Codex.exe` was a small update trampoline. REA recovered 80 selected functions from 8,894 discovered local functions. The application pass retained all 21,236 ASAR members (636,206,219 observed bytes), independently compared every member with the Electron ASAR reader, and completed research, analysis, detractor and reconciliation rounds. Eight unpacked-member integrity contradictions remained explicitly untrusted; source and preserved-copy hashes were unchanged. This was bounded static recovery, not complete application behavior or original-source reconstruction.

The same preserved desktop entry point was tried in a separate full clone of the owned Windows guest. Process creation failed with native error 14001 (side-by-side configuration incorrect), before any target behavior was observed. The corrected report retained that error and the failed operation. The clone was restored, powered off and removed; both original analysis guests and both Whonix guests retained their original states, snapshot IDs and byte-identical configurations. That failure qualified the diagnostic path, not packaged application execution. The new layout and registered-package modes address this limitation separately.

### Packaged Windows runtime qualification in progress

`DesktopLayout` preserves the selected directory's files and empty directories, verifies exact hashes and inventory in preparation and after observation, extracts bounded verified bytes in the guest, and uses a standard interactive console plus a suspended-before-assignment Job launch. `RegisteredPackage` is explicit: it attempts original signed Appx staging/registration/provisioning and standard-user AUMID activation. Declared services can run with their declared privileges, so this mode relies on the offline VM and independent host watchdog rather than a per-process Job. Registration does not copy host credentials, application sign-in state, ACLs or the host package-registration database.

The session/readiness helper and mocked watchdog tests passed under PowerShell 7 and Windows PowerShell 5.1. Native session declarations were compiled but no LSA/session APIs were invoked on the host. These tests establish bounded retries, explicit migration of proven inactive provisioning credentials, rejection of unrelated secrets, deferred PowerShell verification while cleanup is pending, cancellation matching and exact-UUID shutdown dispatch. The production session/watchdog assets also passed PSScriptAnalyzer 1.25.0 with the repository settings.

A separate live session-only test in the fresh isolated Windows clone established the standard-user console, verified deletion of the temporary autologon secret and task, and classified the old inactive secret as a matching provisioning credential. Deliberately expiring the independent watchdog at five seconds powered off only the bound VM, with shutdown verified after 5.7 seconds. The clean snapshot was restored and both working analysis VMs and both Whonix VMs retained their original states, snapshots and configuration hashes. This session test did not launch Codex or establish package registration.

Run the focused checks with new output directories, or use the full runner above:

```powershell
pwsh -NoProfile -File .\tests\ProfileAnalysisWindowsPayload.Behavior.ps1 -TestRoot C:\Tests\Payload-New
pwsh -NoProfile -File .\tests\ProfileAnalysisWindowsSession.Behavior.ps1 -TestRoot C:\Tests\Session-New
powershell.exe -NoProfile -File .\tests\ProfileAnalysisWindowsSession.Behavior.ps1 -TestRoot C:\Tests\Session-PS51-New
pwsh -NoProfile -File .\tests\ProfileAnalysisWindowsDeploymentProfile.Behavior.ps1 -TestRoot C:\Tests\DeploymentProfile-New
powershell.exe -NoProfile -File .\tests\ProfileAnalysisWindowsDeploymentProfile.Behavior.ps1 -TestRoot C:\Tests\DeploymentProfile-PS51-New
```

Codex registered-package startup was live-qualified on 2026-10-24 in a new, independent full clone of the clean Windows baseline. Package `OpenAI.Codex_26.1021.2667.0_x64__2p2nqsd0c76g0` used its original signed MSIX and vendor-issued offline license, with all eight VM network adapters disabled. The selected executable SHA256 was `0FAFA8BEC7C7F1210F28E4D005E1282486A6E28E2A007C47A1787AE12F1C38B5`. All 3,636 preserved files and 562 directories were revalidated; the original package/license inputs and their preserved copies also remained unchanged.

The real standard-user console, removal of temporary logon secrets, Windows package deployment/registration, activated image hash and package/user identity passed. Observation lasted 600.931 seconds, retained 18 processes and one window, and produced a visually inspected sign-in screen in both the VM display and retained window capture. One Escape key dismissed the Windows Start menu for inspection; no app controls, sign-in, host account state or internet activation were used. The controller completed with exit code zero and all six inventory workers completed and were disposed. Sixteen retained artifact hashes matched. The independent watchdog was cancelled only after verified power-off, the clean snapshot was restored, temporary credential files were removed and the exclusive lock was released. Both working analysis VMs and both Whonix VMs retained their states, snapshot IDs and byte-identical configurations.

The analysis result intentionally remained `Partial`: Codex was still running at the observation limit, HKCU snapshots reached the 2,000-key cap, and one active temporary file could not be hashed because it was locked. These are recorded coverage limits, not a claim of complete behavior analysis. Authenticated features, newer Codex builds and other applications remain unqualified. Codex requires the registered-package path for this result; desktop-layout preservation alone does not establish MSIX activation or meaningful GUI startup. Registered activation has no redirected target stdout/stderr, which are reported as unavailable. A loader-context probe, zero exit code or saved PNG alone is insufficient for qualification.

Registered-mode file and HKCU baselines begin after machine-level deployment and before standard-user registration/activation. Qualification of those deltas does not cover earlier package installation or service-start activity, HKLM, or files outside the bounded work/temporary-directory scope. Deployment records and service observations are separate evidence, not a complete trace of those changes.

Fresh Windows provisioning was separately qualified on VirtualBox 7.2.20 with Hyper-V active, using the caller-supplied `Windows11_Client_x64_en-us_26300_9457.iso`, image 6. A new, unregistered VM and empty 64 GiB virtual disk reached `Ready` and a powered-off isolated clean snapshot in about 51 minutes. Setup's verified first reset automatically changed the VM from four CPUs to one; Guest Additions readiness, standard-account creation and credential rotation completed without keyboard input, pause/resume, forced restart or manual service recovery. The temporary reset-conversion setting was absent afterward. Both existing analysis VMs and both Whonix VMs retained their original states, snapshot IDs and byte-identical configurations. Other installation media and hypervisor versions remain unqualified.

That newly provisioned guest also passed native and managed runtime fixtures with exact exit codes, stdout/stderr, created-file hashes and the expected HKCU registry value. A separate 30-second deadline terminated a 120-second fixture and its observed `cmd`/`PING` children at 30.1 seconds. Each run verified standard-user execution, credential/task cleanup, source integrity and powered-off clean-snapshot restoration. The managed positive case used a 60-second allowance after a shorter 10-second trial timed out; production runtime limits were unchanged.

## Intentional API corrections

### Packages C–G

The Windows suite also requires `aria2c.exe` on PATH. It uses a loopback HTTP server and disposable local Git remotes; it does not use real credentials, reset user repositories, install a profile, or read raw evidence disks. `ProfileDownloads.Behavior.ps1 -FFmpegFixturePath <existing ffmpeg.exe>` additionally serves a real executable from a local ZIP and verifies extraction, its version and hash.

Run focused static validation with PSScriptAnalyzer 1.25.0:

```powershell
./tests/Invoke-ProfileStaticValidation.ps1 -OutputPath ./static-results.json
```

The checked-in baseline covers C–G production files, the appearance helpers and executable-analysis PowerShell code. Existing warnings are explicitly recorded, including compatibility names, exported variables and inherited sample/helper code. New warnings and all errors fail. Public-command validation rejects duplicate file-level definitions without confusing nested helper functions with public commands. GitHub Actions runs the static gate and Windows regression suite.

| Added test | Evidence |
| --- | --- |
| ProfileArchive.Behavior | Exact ZIP bytes, empty directories, overwrite/WhatIf, traversal, device/ADS paths, duplicates, symlinks and junctions. |
| ProfileDownloads.Behavior | Real native/aria2/RPC loopback transfers, headers, completion, failures, timeout, hashes, lengths, multiple URLs, fallback isolation, cookies, private-release parameter capture and FFmpeg ZIP layout. |
| ProfileSecrets.Behavior | Mocked locked/missing/custom vaults; original secret types retained; no policy reconfiguration or secret-bearing errors. |
| ProfileGit.Behavior | Real local bare remotes; preview, reset/merge/push, recovery of staged/unstaged/untracked work, ignored files, Cargo sentinels, NoPush, divergence, locks, detached HEAD and failed remotes. |
| ProfileSearch.Behavior | Reference filename/content fixtures, Unicode, recursive glob behavior, junction avoidance and mocked Everything ownership. |
| ProfileRawCopy.Behavior | ABI layout, malformed buffers, sparse/multiple extents, partial clusters, EOF, large logical lengths, real file retrieval IOCTL, and mocked VSS cleanup. No raw-device reads. |
| ProfileForensicCopy.Behavior | Regular/LOG/empty file bytes and hashes; partial totals, locked failures, verified adapter contract, stale-output rejection and import order. |
| ProfilePublicCommands.Behavior | Unique public definitions, all 265 original public commands, compatibility imports, ImageForensics module, aliases and variables. |

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
