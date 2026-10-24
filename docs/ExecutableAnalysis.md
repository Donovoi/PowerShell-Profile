# Executable analysis

`Invoke-ExecutableAnalysis` is a PowerShell orchestrator for reproducible reverse engineering. It preserves the input, collects static evidence, runs compatible decompilers, researches current documentation, and subjects the findings to an independent Codex critique and reconciliation pass.

```powershell
# A unique analysis-* folder is created under the current directory.
Invoke-ExecutableAnalysis 'C:\Downloads\program.exe'

# Choose another parent folder.
Invoke-ExecutableAnalysis ./program -OutputDirectory C:\Analysis

# Request observation in the corresponding disposable VM as well.
Invoke-ExecutableAnalysis ./linux-program -OutputDirectory C:\Analysis -Dynamic

# Quick local evidence only, without AI, installers or external analyzers.
Invoke-ExecutableAnalysis ./program -BasicOnly -SkipAI -NoInstall

# Preview without creating files, installing tools or starting a VM.
Invoke-ExecutableAnalysis ./program -WhatIf
```

Use PowerShell 7.2 or newer on Windows. Startup only defines the command. Its supporting assets are shipped in `scripts/ExecutableAnalysis`; install the complete profile checkout rather than downloading the function alone.

## What each run retains

- `report.md` and `report.json`: status, identity, coverage, failed/skipped stages, limitations and artifact SHA256 values.
- `input/`: a byte-verified copy of the source. Providers work on this copy; the original and the copy are checked again at completion.
- `basic/`: format/header observations, bounded ASCII/UTF-16 strings, Base64 decoding candidates, PE version declarations and Windows signature status where applicable.
- `basic/application-context.json` and `application/`: bounded adjacent package metadata, declared entry points, preserved ASAR and unpacked companions, plus a separate REA stage for the application archive. Original and retained companion hashes are checked at completion.
- `rea/`: complete retained REA evidence, the actual advertised tool catalog, extracted resources and native pseudocode/WAT where supported.
- `code/`: reconstructed C# projects, Java sources or direct Ghidra output. These are reconstructions, not the original source tree.
- `logs/`: exact executable/argument records, executable hashes, stdout/stderr, exit status and elapsed time. Native arguments are passed individually without a shell.
- `ai/`: research, initial findings, independent detractor review and reconciled findings, with their exact prompts and CLI event logs.
- `runtime/`: VM observations and isolation/hash/snapshot-cleanup validation when requested and supported.

Each invocation creates a new folder; it does not overwrite previous reports. The command returns one object with `Status`, `OutputDirectory`, `ReportPath`, `JsonPath`, `SHA256`, `SourceUnchanged` and `Stages`.

`CompletedWithLimitations` means the requested supported stages completed. It never means every behavior was recovered or that the program is safe. `Partial` preserves successful evidence while identifying unavailable providers, failed operations, limits or incomplete research. Invalid input arguments fail before analysis begins.

## Formats and actual providers

| Target | Analysis route | Important boundary |
| --- | --- | --- |
| Native PE | REA + Ghidra | Native pseudocode is relative to the functions Ghidra discovered. |
| Managed PE/.NET | REA metadata/CIL/resources + ILSpy project export | AnyCPU cannot be inferred solely from the PE machine field; metadata is authoritative. |
| ELF / Mach-O | REA admission record plus direct Ghidra export | REA 6.7 on Windows excludes these native formats; the direct exporter is a separate retained stage. |
| WASM | REA + WABT | Produces validated WAT; this is not source in the original language. |
| Java / JAR / APK / DEX | JADX, plus applicable REA/package metadata | Decompiled methods/resources may be incomplete; parser failures remain visible. |
| ZIP/application packages | REA inventory and verified extraction | Retained files must match the provider inventory's lengths and hashes; unsafe or incomplete retention is partial. |
| JavaScript / ASAR | Verified archive extraction followed by bounded REA application/semantic analysis | ASAR members and unpacked sidecars are retained byte for byte when available. Source selection and provider coverage are reported separately; incomplete or unknown semantics remain partial. Standalone JS is isolated from unrelated sibling files. Wakaru recovery requires its separately configured supported environment. |
| Unknown, packed or encrypted data | Basic evidence and explicit provider failures | Entropy and strings are indicators, not proof of packing, encryption or behavior. No arbitrary target-supplied decoder is executed. |

No general tool can decrypt arbitrary strong encryption without appropriate keys. This command does not invent keys, claim decryption from Base64 decoding, or mistake a successful process exit for complete recovery. It does not automatically fetch URLs found inside the target.

For packaged applications, a launcher can be only a small part of the product. Static analysis inspects fixed adjacent metadata, an Appx manifest in the executable directory or its immediate parent, `resources/app.asar`, and its unpacked sidecar. Manifest declarations are evidence of entry points, not proof that those binaries were analyzed. This static companion pass does not recursively copy the installation or user data. The optional Windows runtime stage separately preserves a complete selected application directory as described below. See Electron's [ASAR format](https://www.electronjs.org/docs/latest/tutorial/asar-archives) and [application distribution](https://www.electronjs.org/docs/latest/tutorial/application-distribution) documentation for the archive/sidecar layout.

Archive integrity mismatches fail extraction by default. `-ArchiveIntegrityPolicy RecordAndContinue` explicitly permits forensic recovery of observed bytes, retains the declared-versus-observed hash contradictions, and keeps the stage partial. It does not authenticate mismatched files or execute them. Post-packaging signing can cause such differences, but the command does not assume that explanation. Semantic analysis uses the verified retained extraction tree so it does not silently reread unrelated installation files.

## Tool selection and research

The research round checks current primary documentation and compatibility. It receives only the detected format/architecture, not target filenames, hashes or strings. Actual completed web-search results are required before the round is considered complete. Recommendations remain advisory; model-generated installation commands are not executed.

The execution adapters use versions qualified together: REA 6.7.0, compatible Ghidra 12.1.x (download fallback 12.1.4), ILSpy 11.1.0.9782, WABT 1.0.42 and JADX 1.5.6. This deliberately distinguishes current releases from supported combinations. For example, Ghidra 12.2 is newer than REA's documented 12.1.x compatibility window.

Missing applicable providers are installed only on invocation, under `%LOCALAPPDATA%\PowerShellProfile\AnalysisTools`, unless `-NoInstall` is supplied. GitHub binary downloads have pinned SHA256 checks; npm/.NET packages use explicit versions. Existing compatible tools are reused. Node.js, an appropriate Java/.NET runtime, VirtualBox and signed-in Codex remain host prerequisites; unavailable capabilities are reported individually.

Codex CLI 0.163.0 or later is required. The resolver can reuse the desktop app's complete CLI bundle, including its code-mode host, or the official npm package's native executable, without changing PATH or user configuration. Batch shims are not used because they can alter literal arguments. Candidate failures are retained in `logs/codex-resolver.json`. Research and critique use the signed-in account and consume its usage. Selected local evidence/code excerpts are sent through Codex for analysis; full target binaries are not uploaded. `-SkipAI` disables all four rounds. Analyst/detractor rounds have web search, shell, MCP, applications, hooks and patching disabled. Target-derived content is explicitly treated as untrusted data.

Useful primary references: [REA installation and provider compatibility](https://github.com/morluto/rea/blob/main/docs/installation.md), [Windows REA admission boundaries](https://github.com/morluto/rea/blob/main/docs/windows-ghidra-p0.md), [Ghidra decompiler API](https://ghidra.re/ghidra_docs/api/ghidra/app/decompiler/DecompInterface.html), [ILSpy CLI](https://github.com/icsharpcode/ILSpy/tree/master/ICSharpCode.ILSpyCmd), [JADX](https://github.com/skylot/jadx), [WABT](https://github.com/WebAssembly/wabt), [Codex non-interactive execution](https://learn.chatgpt.com/docs/non-interactive-mode).

## Runtime containment

Static analysis does not launch the target on the host. `-Dynamic` opts into a dedicated, owned VM with a matching guest OS. An unrelated VM is never reused. The clean snapshot is restored before execution and again in cleanup. Networking, shared folders, clipboard, drag-and-drop, USB and other host integrations must pass isolation checks. The application starts under a verified standard guest account; explicitly requested registered Windows packages can also install privileged services inside that VM. Transferred executable and application-file hashes must match their preserved sources.

The command selects `Profile-Analysis-Windows` for Windows x86/x64 PE executables and `Profile-Analysis-Linux` for supported x86-64 ELF executables. DLLs need an explicit execution harness and receive static analysis only; requesting their runtime analysis records an unsupported stage before provisioning or starting a VM. Override an owned VM name with `-VirtualMachineName`. An exclusive per-VM lock prevents simultaneous analyses from restoring or powering down each other's guest.

The Linux adapter captures `strace`, stdout/stderr, exit status and bounded file metadata. The Windows adapter retains process, window and selected filesystem, registry and connection observations. It can preserve an application layout and prepare an actual interactive console for a GUI launch. It does not click through GUI flows, supply program arguments, sign in, enable networking or exercise every execution path. macOS, other CPU architectures and unsupported guest formats require a corresponding runtime adapter. A VM is a containment measure, not a formal guarantee against escape.

Programs requiring unavailable guest dependencies, elevated privileges, GUI interaction or networking may expose only a startup failure or timeout. Retaining that evidence does not establish successful feature coverage.

`Initialize-ExecutableAnalysisVm` creates the dedicated Ubuntu 24.04 LTS VM, verifies the official cloud-image checksum, temporarily enables NAT only to install guest tools, then creates a powered-off isolated snapshot. It preserves unrelated VMs. Provisioning artifacts that contain bootstrap credentials are removed; the remaining credential is protected using Windows DPAPI.

`Initialize-ExecutableAnalysisWindowsVm` creates a dedicated Windows 11 guest from a caller-supplied local x64 installation ISO and the installed VirtualBox Guest Additions ISO. Setup is offline. Windows media and any required license are supplied by the caller.

Provisioning starts Setup with four CPUs. VirtualBox converts the first guest-requested reboot to a power-off; the host verifies the recorded reset reason, removes that temporary setting, and starts the installed disk with one CPU. This avoids the multi-CPU first-boot problems observed with the Hyper-V/NEM backend without changing host security or virtualization settings. An unexplained shutdown or failed CPU verification stops provisioning. The manifest records the current provisioning phase and verified reboot time. Guest-service readiness, account setup and a powered-off clean snapshot are required before the VM is marked ready. The reset conversion uses VirtualBox's `VBoxInternal2/TurnResetIntoPowerOff` mechanism and its host-written reset reason ([implementation](https://www.virtualbox.org/browser/vbox/trunk/src/VBox/Main/src-client/ConsoleImpl.cpp)); qualification is version-specific, not a promise for every hypervisor release.

The Windows guest uses a dedicated built-in Administrator management account for provisioning, package deployment and evidence transfer, with a random password protected by Windows DPAPI on the host. The application launches as the separate `analysis-user` account, whose absence from the Administrators group is checked in addition to its token. Declared package services may run under their declared privileged accounts. UAC remains enabled. Protected recovery credentials are saved before guest password changes, so a provisioning timeout does not discard the credentials needed for recovery.

A single-file launch uses a temporary password-logon Scheduled Task at limited privilege to load the standard user's Windows profile. An application-layout launch instead prepares a real interactive console: a temporary VM-only autologon password is held in an LSA secret, and a trusted SYSTEM task removes it and the autologon settings before payload deployment. Readiness requires matching local account/SID, an active console, a verified non-administrator console token, absent temporary secrets and removal of the cleanup task. The runner then uses an InteractiveToken task bound to that session. A token from `LogonUser` alone is not treated as a desktop session.

Interactive preparation disables the owned guest's display and standby idle timers for both AC and DC power, using fixed setting GUIDs and bounded `powercfg` commands. Configure and readiness records include the active scheme and all four verified zero-second values; native power APIs read them without parsing localized command output. The previous values are retained in the private session ownership record. Unsupported settings, failed writes or subsequent policy changes prevent readiness. This changes only the disposable guest and is undone by snapshot restoration; it does not alter host power settings, screen-lock policy or arbitrary display-driver behavior. See Microsoft's [powercfg reference](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options) and [numeric power-setting API](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-powerreadacvalueindex).

Older owned baselines can retain a disabled provisioning autologon secret. The host supplies only the VM's retained administrator/bootstrap/recovery credentials through the restricted temporary configuration. Replacement requires disabled autologon, no plaintext registry password, a local account, and an empty secret or an exact in-memory match to that account's retained credential. Unknown nonempty secrets and active autologon are refused. Reports retain only the migration classification and account name.

First interactive logon can be slow on a small guest. The SYSTEM cleanup task has a five-minute execution limit; host session preparation has a ten-minute deadline and uses a lightweight completion-file probe before PowerShell verification. No payload is transferred or deployed until the full readiness checks pass.

The runner verifies the loaded user registry hive and writable HKCU before launching the target. Temporary credential files are restricted to management administrators and SYSTEM, then deleted before launch or signed package deployment; passwords are not passed in process arguments or stored in task actions. These are generated VM credentials, not host application credentials. No host Codex sign-in state or user profile is transferred. The host requires agreement between the session, task, runner and cleanup records before accepting the observations.

For the single-file path, the controller verifies the task account by SID and grants only its required batch-logon right inside the disposable guest. A real batch-logon token must pass identity and non-administrator checks before execution. Controller evidence is kept in the protected guest directory; ordinary program evidence is read using the standard account. Snapshot restoration removes temporary guest policy, registration and service changes. A privileged guest target can tamper with guest-generated evidence; host isolation, deadlines and original-source checks remain separate checks.

On first use, provide the media explicitly:

```powershell
Initialize-ExecutableAnalysisWindowsVm -IsoPath C:\Downloads\Windows11.iso
# Or let the analysis command initialize it before its runtime stage:
Invoke-ExecutableAnalysis C:\Samples\program.exe -Dynamic -WindowsIsoPath C:\Downloads\Windows11.iso
```

`-Dynamic` reuses a ready owned guest, or initializes the corresponding guest unless `-NoInstall` is set. A missing Windows ISO, unavailable virtualization provider, incompatible executable or failed isolation check leaves the runtime stage incomplete with its reason. Execution never falls back to the host.

### Windows application layouts and registered packages

The Windows runtime discovers an Appx manifest beside the selected executable or one directory above it, or an adjacent `resources/app.asar`. Use `-WindowsApplicationRoot` to select a different complete root. The selected executable must be inside that root. The low-level `Invoke-ExecutableAnalysisWindowsVm` equivalent is `-ApplicationRoot`. A standalone executable still uses the single-file path; Linux runtime remains a single-file adapter.

The runtime payload is a new uncompressed ZIP plus `payload-manifest.json`, containing relative file names, directory names including empty directories, byte counts, SHA256 hashes and the selected entry point. Preparation validates every file and repeats the bounded source inventory to detect added or missing paths. Guest extraction verifies archive/manifest identities, every member's length/hash and complete counts. Unsafe paths, duplicate names, reparse points and source/output overlap fail. Original source files and directory inventory are checked again after observation. ACLs, owners, timestamps, host package-registration state and external dependencies are not recreated by copying the directory. Application user data, host sign-in state and credentials outside that root are not copied.

| Windows launch mode | Behavior and containment |
| --- | --- |
| `DesktopLayout` (default) | Launches the exact executable with its preserved neighboring files and working directory. It creates the process suspended, assigns it to a Windows Job before resuming, and applies Job process/memory/time limits. It does not register MSIX identity, extensions or services. |
| `RegisteredPackage` (explicit) | Requires an Appx application declaration matching the selected executable. Attempts original signed layout staging, management-account registration and provisioning, then standard-user registration and AUMID activation. No manifest editing, re-signing, development-mode substitution or license bypass is performed. Declared services/extensions may start during deployment, including LocalSystem services. Activation and services are contained by the entire offline VM and independent host deadline; Job process/memory limits do not apply. |

```powershell
# Preserve a complete desktop application for a standard-user GUI launch.
Invoke-ExecutableAnalysis 'C:\Apps\Example\app\Example.exe' -Dynamic `
    -WindowsApplicationRoot 'C:\Apps\Example'

# Explicitly request signed Appx registration and activation inside the VM.
Invoke-ExecutableAnalysis 'C:\Apps\Example\app\Example.exe' -Dynamic `
    -WindowsApplicationRoot 'C:\Apps\Example' -WindowsLaunchMode RegisteredPackage
```

Signed registration can fail because an offline license, dependency, supported OS feature or deployment permission is unavailable. Such failures remain explicit; the command does not silently fall back to an unregistered launch. Registration uses the exact staged package full name verified against its name, publisher, version, architecture and resource ID. The returned activation PID must have the expected package identity, executable hash and standard-user SID/token. Microsoft's [staging](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packagemanager.stagepackageasync), [registration by full name](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packagemanager.registerpackagebyfullnameasync), [provisioning](https://learn.microsoft.com/en-us/uwp/api/windows.management.deployment.packagemanager.provisionpackageforallusersasync) and [AUMID activation](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-iapplicationactivationmanager-activateapplication) APIs describe these separate steps.

For packages with a vendor-issued offline license, supply both `-WindowsPackageArchivePath` and `-WindowsPackageLicensePath` with `-Dynamic -WindowsLaunchMode RegisteredPackage`. The low-level equivalents are `-PackageArchivePath` and `-PackageLicensePath`. These must name the original signed MSIX/AppX container and its XML license. The command preserves both, verifies every archived application file against the selected installed layout, and checks both source and preserved bytes after observation. `[Content_Types].xml` is the sole permitted container-only file. URI-encoded package names are decoded once and checked for unsafe paths and collisions; ZIP metadata and expansion are bounded. Licenses are limited to 1 MiB with DTDs and external XML entities prohibited.

The guest uses [Add-AppxProvisionedPackage](https://learn.microsoft.com/en-us/powershell/module/dism/add-appxprovisionedpackage) with the original package and license. Its `-Online` parameter selects the running guest OS; all VM network adapters remain disabled. Windows validates signatures and licensing applicability, and the harness verifies the exact provisioned identity and rejects a required restart. It never uses `-SkipLicense`. Host account state and the host license store are not copied. For Codex, OpenAI publishes a signed container and offline license in its [Windows deployment guide](https://learn.chatgpt.com/docs/enterprise/windows-deployment#install-from-an-offline-package); a newer container must not be substituted for the selected build.

```powershell
Invoke-ExecutableAnalysis 'C:\Apps\Example\app\Example.exe' -Dynamic `
    -WindowsLaunchMode RegisteredPackage `
    -WindowsPackageArchivePath 'C:\Installers\Example.msix' `
    -WindowsPackageLicensePath 'C:\Installers\Example-License.xml'
```

Signed deployment also requires a loaded normal local profile for the guest management account. The trusted helper uses that account's existing token, verifies its SID, hive and profile directory, restores the original privilege state and releases only a profile handle it acquired. This adds no password or logon task. Deployment failures retain bounded native error details, activity IDs and AppX event records; a cleanup error does not replace the original deployment failure.

After a registered launch attempt, `activation-events.json` retains bounded events from six fixed Windows channels. Each channel reports availability and read failures. Events containing the exact package identity are distinguished from other events in the same time window; context alone is not attributed to the target. Collection does not enable logs or change their settings. The original activation HRESULT and operation remain in `runtime.json` even if event collection fails.

For a preserved application payload, an independent host watchdog starts before payload transfer and deployment. Its deadline is the requested runtime plus 1,200 seconds for preparation and evidence collection, or plus 1,500 seconds when a signed container and offline license are supplied. Licensed deployment allows 1,200 seconds beyond observation for the controller, leaving a combined 300-second allowance for transfer and evidence collection outside it. These are whole-workflow bounds, not a promise of a full collection period after a slow transfer. At expiry the watchdog verifies the exact owned VM identity and powers off only that VM; identity inspection, power-off and verification each have a 15-second command bound. It never restores snapshots or touches another VM. Normal cleanup verifies power-off, cancels the matching watchdog, then restores the recorded clean snapshot. Uncertain shutdown keeps the deadline armed and the VM locked while waiting for its bounded completion. A watchdog that remains active quarantines the VM against another run. The report retains the watchdog's ready/result records and cleanup verification.

Registered activation does not redirect the target's stdout/stderr. Those streams are reported as unavailable; the trusted runner's own diagnostic streams are separate. Window observations and optional bounded PNG captures can help assess launch, but a window handle or a successfully saved image does not prove meaningful rendered content. Captures require visual inspection and can fail or be blank. Package services and broker-launched processes are not fully observed by a direct-process Job or periodic process sampling.

The activated process must have the expected package identity, executable hash and standard-user SID. Token inspection requests query and duplicate access because .NET's administrator-membership check duplicates primary tokens; it does not impersonate the token or grant privileges. Identity-check failures retain the specific inspection operation and fail qualification.

Runtime history retains at most 128 distinct processes and 64 windows. Reaching a history limit ends observation with an explicit partial-result reason. Process names, image paths and window titles have separate text limits and truncation flags so repeated child launches cannot grow the runtime report without bound.

In registered mode, the file and HKCU `before` snapshots are taken after machine-level package deployment and before standard-user registration/activation. Their deltas therefore exclude earlier deployment and service-start activity. File scope remains the bounded work and temporary directories, and registry scope remains the analysis user's HKCU Software; these observations do not trace machine-wide service or registry changes.

File, registry and connection inventories run in separate workers with waits of 120, 30 and 30 seconds respectively. Collectors publish bounded scalar rows as they work. A timeout preserves those rows with explicit partial coverage and worker diagnostics, even if a filesystem, registry or CIM call blocks. The dedicated runner saves the final report before exiting to terminate any remaining workers; it does not wait for blocked native calls to finish. Text and row caps also mark coverage partial when reached. Mandatory identity checks and bounded snapshot formatting remain subject to the independent VM watchdog. Preserved payloads allow 600 seconds beyond target observation for runner preparation and final collection; standalone inputs retain 300 seconds. Bounded artifact reads allow 60 seconds in a payload guest and 30 seconds for standalone inputs, plus ten seconds for the host command to finish. These allowances do not extend the whole-VM deadline.

A failed launch retains its underlying Windows error code, OS message and failed operation. Inspect `TargetOutcome`, `Execution.ExitCode`, `Execution.Reason` and any window evidence. A nonzero exit is partial/error behavior. A GUI still running at the observation deadline is partial with `RunningAtObservationLimit`; an exit code of zero does not prove that every feature works. Codex package `26.1021.2667.0` was live-qualified on 2026-10-24 using its original signed container and offline license: exact identity and standard-user execution, a rendered sign-in screen, final evidence collection and clean-snapshot restoration all passed. The report remained partial because the application was still running, registry snapshots reached their configured key cap, and one active temporary file was locked. This qualifies offline unauthenticated startup of that build; other applications, versions and authenticated features require separate validation. See [validation details](../tests/Validation.md).

`runtime-progress.json` and, for registered activation, `activation-progress.json` preserve bounded phase checkpoints when a run is interrupted. They help distinguish preparation, activation, observation and final inventory work. A checkpoint never substitutes for the final `runtime.json` or proves successful startup. An unavailable optional checkpoint is recorded separately; missing final runtime evidence still fails qualification.

## Budgets and validation

Inputs default to a 1 GiB size limit. `-MaxInputBytes` can raise it explicitly, up to 2 GiB minus one byte; larger inputs are rejected before creating an analysis folder.

`-MaxCompanionBytes` separately defaults to 1 GiB for adjacent files. Setting it to zero inventories candidates without copying them; `-BasicOnly` also uses zero. The companion inventory stops at 5,000 entries and 16 sidecar directory levels, metadata is limited to 1 MiB per file, and reparse points are refused. Missing optional sidecars are recorded; the extraction provider determines whether a member actually requires one. `-MaxJavaScriptFiles` (default 40) and `-MaxJavaScriptBytes` (default 32 MiB) bound semantic input independently of recovered source retention. Selection prioritizes `package.json`, its declared main file and main/preload bundles. Unselected source remains explicitly unanalyzed.

REA extraction retention permits up to 50,000 file/directory entries, 64 MiB per file and 1 GiB of total provider evidence. Limits stop retention with an explicit partial result. Each REA call is bounded by the remaining `-TimeoutSeconds` budget; a caller's larger timeout is no longer silently reduced to five minutes.

Large application graphs can need larger budgets. `-MaxJavaScriptHeapMB` defaults to 1024 MiB per worker and accepts up to 8192; it limits the JavaScript heap, not total resident memory. `-MaxProviderEvidenceBytes` defaults to 1 GiB per REA stage and accepts up to 16 GiB. This includes full evidence exports, which can exceed the source-file size. Increase these explicitly when needed, for example `-MaxJavaScriptHeapMB 2048 -MaxProviderEvidenceBytes 2GB`. Raising a budget does not imply complete semantic recovery.

When REA completes an operation but its response exceeds the MCP transport budget, the bridge exports the retained evidence and resolves only the exact evidence ID and operation named in that failure. Parsing is capped at 256 MiB and the overall evidence budget still applies. The original transport response and the complete export remain available. Recovered source files are rehashed after the semantic provider closes; mutation or disappearance fails the run.

`-MaxFunctions 0` attempts all discovered native functions within the overall evidence/time limits. A positive value bounds function attempts. `-TimeoutSeconds` bounds analyzer processes; `-AIReviewTimeoutSeconds` bounds each AI round; `-RuntimeSeconds` bounds the guest target. Basic string scanning is limited to 16 MiB, 20,000 strings and 8,192 characters per retained string, with truncation disclosed. Each process's combined stdout/stderr is capped at 64 MiB by a shared streaming budget.

Runtime payload budgets are independent of static companion/provider budgets. `-MaxRuntimePackageBytes` defaults to 8 GiB and accepts up to 64 GiB; `-MaxRuntimePackageFiles` defaults to 10,000 and accepts up to 50,000. The low-level equivalents are `-MaxPackageBytes` and `-MaxPackageFiles`. Directory depth is limited to 64, directories to 200,000, and guest payload manifests to 32 MiB. The uncompressed archive and extracted guest files need disk space beyond the source installation. Budget or inventory failures prevent deployment rather than silently dropping companions.

Runtime constraints can change a program's behavior. Windows Job launches permit at most 32 active assigned processes, with defaults of 1 GiB committed memory per process and 4 GiB for the Job. The low-level command exposes `-MaxProcessMemoryMB` (128–8192) and `-MaxJobMemoryMB` (128–16384); the Job budget must be at least the process budget. It checks combined stdout/stderr against an 8 MiB threshold every 100 ms, so output can overshoot before termination. Registered activation instead polls package processes every 500 ms and uses the VM's configured resources and host watchdog; it has no enforced Job process, memory or redirected-output budget. Host retention caps each guest artifact at 16 MiB. Linux uses a 1 GiB address-space limit, a 64-process user limit, a 1 MiB per-file size limit and a CPU-time limit matching the requested runtime. An allocation failure or early exit under these constraints does not establish behavior without them.

CI exercises deterministic local fixtures and a fake MCP peer; it does not claim to qualify live provider feeds, account authentication or guest OS installation. Separate real integration checks cover the actual REA/Ghidra/ILSpy/WABT/JADX tools and disposable VM behavior. Tests check meaningful recovered values/bytes and clean end states rather than only exit codes. See `tests/Validation.md` for the required regression commands.
