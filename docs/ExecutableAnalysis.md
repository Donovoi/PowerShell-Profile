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

For packaged applications, a launcher can be only a small part of the product. The command inspects fixed adjacent metadata, an Appx manifest in the executable directory or its immediate parent, `resources/app.asar`, and its unpacked sidecar. Manifest declarations are evidence of entry points, not proof that those binaries were analyzed. It does not recursively copy the installation, native dependencies, user data or credentials. See Electron's [ASAR format](https://www.electronjs.org/docs/latest/tutorial/asar-archives) and [application distribution](https://www.electronjs.org/docs/latest/tutorial/application-distribution) documentation for the archive/sidecar layout.

Archive integrity mismatches fail extraction by default. `-ArchiveIntegrityPolicy RecordAndContinue` explicitly permits forensic recovery of observed bytes, retains the declared-versus-observed hash contradictions, and keeps the stage partial. It does not authenticate mismatched files or execute them. Post-packaging signing can cause such differences, but the command does not assume that explanation. Semantic analysis uses the verified retained extraction tree so it does not silently reread unrelated installation files.

## Tool selection and research

The research round checks current primary documentation and compatibility. It receives only the detected format/architecture, not target filenames, hashes or strings. Actual completed web-search results are required before the round is considered complete. Recommendations remain advisory; model-generated installation commands are not executed.

The execution adapters use versions qualified together: REA 6.7.0, compatible Ghidra 12.1.x (download fallback 12.1.4), ILSpy 11.1.0.9782, WABT 1.0.42 and JADX 1.5.6. This deliberately distinguishes current releases from supported combinations. For example, Ghidra 12.2 is newer than REA's documented 12.1.x compatibility window.

Missing applicable providers are installed only on invocation, under `%LOCALAPPDATA%\PowerShellProfile\AnalysisTools`, unless `-NoInstall` is supplied. GitHub binary downloads have pinned SHA256 checks; npm/.NET packages use explicit versions. Existing compatible tools are reused. Node.js, an appropriate Java/.NET runtime, VirtualBox and signed-in Codex remain host prerequisites; unavailable capabilities are reported individually.

Codex CLI 0.163.0 or later is required. The resolver can reuse the desktop app's complete CLI bundle, including its code-mode host, or the official npm package's native executable, without changing PATH or user configuration. Batch shims are not used because they can alter literal arguments. Candidate failures are retained in `logs/codex-resolver.json`. Research and critique use the signed-in account and consume its usage. Selected local evidence/code excerpts are sent through Codex for analysis; full target binaries are not uploaded. `-SkipAI` disables all four rounds. Analyst/detractor rounds have web search, shell, MCP, applications, hooks and patching disabled. Target-derived content is explicitly treated as untrusted data.

Useful primary references: [REA installation and provider compatibility](https://github.com/morluto/rea/blob/main/docs/installation.md), [Windows REA admission boundaries](https://github.com/morluto/rea/blob/main/docs/windows-ghidra-p0.md), [Ghidra decompiler API](https://ghidra.re/ghidra_docs/api/ghidra/app/decompiler/DecompInterface.html), [ILSpy CLI](https://github.com/icsharpcode/ILSpy/tree/master/ICSharpCode.ILSpyCmd), [JADX](https://github.com/skylot/jadx), [WABT](https://github.com/WebAssembly/wabt), [Codex non-interactive execution](https://learn.chatgpt.com/docs/non-interactive-mode).

## Runtime containment

Static analysis does not launch the target on the host. `-Dynamic` opts into a dedicated, owned VM with a matching guest OS. An unrelated VM is never reused. The clean snapshot is restored before execution and again in cleanup. Networking, shared folders, clipboard, drag-and-drop, USB and other host integrations must pass isolation checks. Targets run under an unprivileged guest account with a time limit; the transferred target hash must match.

The command selects `Profile-Analysis-Windows` for Windows x86/x64 PE executables and `Profile-Analysis-Linux` for supported x86-64 ELF executables. DLLs need an explicit execution harness and receive static analysis only; requesting their runtime analysis records an unsupported stage before provisioning or starting a VM. Override an owned VM name with `-VirtualMachineName`. An exclusive per-VM lock prevents simultaneous analyses from restoring or powering down each other's guest.

The Linux adapter captures `strace`, stdout/stderr, exit status and bounded file metadata. The Windows adapter runs the target under a standard account in a bounded Windows Job and retains process/output and selected system observations. Neither adapter exercises GUI flows, arguments, networking or every execution path. macOS, other CPU architectures and unsupported guest formats require a corresponding runtime adapter. A VM is a containment measure, not a formal guarantee against escape.

Programs requiring unavailable guest dependencies, elevated privileges, GUI interaction or networking may expose only a startup failure or timeout. Retaining that evidence does not establish successful feature coverage.

`Initialize-ExecutableAnalysisVm` creates the dedicated Ubuntu 24.04 LTS VM, verifies the official cloud-image checksum, temporarily enables NAT only to install guest tools, then creates a powered-off isolated snapshot. It preserves unrelated VMs. Provisioning artifacts that contain bootstrap credentials are removed; the remaining credential is protected using Windows DPAPI.

`Initialize-ExecutableAnalysisWindowsVm` creates a dedicated Windows 11 guest from a caller-supplied local x64 installation ISO and the installed VirtualBox Guest Additions ISO. Setup is offline. Windows media and any required license are supplied by the caller.

Provisioning starts Setup with four CPUs. VirtualBox converts the first guest-requested reboot to a power-off; the host verifies the recorded reset reason, removes that temporary setting, and starts the installed disk with one CPU. This avoids the multi-CPU first-boot problems observed with the Hyper-V/NEM backend without changing host security or virtualization settings. An unexplained shutdown or failed CPU verification stops provisioning. The manifest records the current provisioning phase and verified reboot time. Guest-service readiness, account setup and a powered-off clean snapshot are required before the VM is marked ready. The reset conversion uses VirtualBox's `VBoxInternal2/TurnResetIntoPowerOff` mechanism and its host-written reset reason ([implementation](https://www.virtualbox.org/browser/vbox/trunk/src/VBox/Main/src-client/ConsoleImpl.cpp)); qualification is version-specific, not a promise for every hypervisor release.

The Windows guest uses a dedicated built-in Administrator management account for provisioning and evidence transfer, with a random password protected by Windows DPAPI on the host. Targets run as the separate `analysis-user` account, whose absence from the Administrators group is checked in addition to its token. UAC remains enabled. Protected recovery credentials are saved before guest password changes, so a provisioning timeout does not discard the credentials needed for recovery.

A trusted guest controller uses a temporary password-logon Scheduled Task at limited privilege to load that standard user's Windows profile. The runner verifies the loaded user registry hive and writable HKCU before launching the target. Temporary launch credentials are restricted to management administrators and SYSTEM, then deleted before the target starts; they are not passed in process arguments or stored in the task action. The host requires agreement between the task result, runner report and verified task removal before reporting completion.

The controller verifies the task account by SID and grants only its required batch-logon right inside the disposable guest. A real batch-logon token must pass identity and non-administrator checks before execution. Controller evidence is kept in the protected guest directory; ordinary program evidence is read using the standard account. Snapshot restoration removes the temporary guest policy change.

On first use, provide the media explicitly:

```powershell
Initialize-ExecutableAnalysisWindowsVm -IsoPath C:\Downloads\Windows11.iso
# Or let the analysis command initialize it before its runtime stage:
Invoke-ExecutableAnalysis C:\Samples\program.exe -Dynamic -WindowsIsoPath C:\Downloads\Windows11.iso
```

`-Dynamic` reuses a ready owned guest, or initializes the corresponding guest unless `-NoInstall` is set. A missing Windows ISO, unavailable virtualization provider, incompatible executable or failed isolation check leaves the runtime stage incomplete with its reason. Execution never falls back to the host.

The runtime adapters transfer one executable. Detected application companions/package activation metadata, or an unverifiable adjacent context, therefore make the top-level runtime stage `Unsupported` before a VM is initialized. Packaged GUI applications need a separate deployment/activation adapter. A failed launch retains the underlying Windows error code, OS message and failed operation. `Completed` means the observation finished; inspect `Execution.ExitCode` and `Reason` before interpreting application behavior.

## Budgets and validation

Inputs default to a 1 GiB size limit. `-MaxInputBytes` can raise it explicitly, up to 2 GiB minus one byte; larger inputs are rejected before creating an analysis folder.

`-MaxCompanionBytes` separately defaults to 1 GiB for adjacent files. Setting it to zero inventories candidates without copying them; `-BasicOnly` also uses zero. The companion inventory stops at 5,000 entries and 16 sidecar directory levels, metadata is limited to 1 MiB per file, and reparse points are refused. Missing optional sidecars are recorded; the extraction provider determines whether a member actually requires one. `-MaxJavaScriptFiles` (default 40) and `-MaxJavaScriptBytes` (default 32 MiB) bound semantic input independently of recovered source retention. Selection prioritizes `package.json`, its declared main file and main/preload bundles. Unselected source remains explicitly unanalyzed.

REA extraction retention permits up to 50,000 file/directory entries, 64 MiB per file and 1 GiB of total provider evidence. Limits stop retention with an explicit partial result. Each REA call is bounded by the remaining `-TimeoutSeconds` budget; a caller's larger timeout is no longer silently reduced to five minutes.

Large application graphs can need larger budgets. `-MaxJavaScriptHeapMB` defaults to 1024 MiB per worker and accepts up to 8192; it limits the JavaScript heap, not total resident memory. `-MaxProviderEvidenceBytes` defaults to 1 GiB per REA stage and accepts up to 16 GiB. This includes full evidence exports, which can exceed the source-file size. Increase these explicitly when needed, for example `-MaxJavaScriptHeapMB 2048 -MaxProviderEvidenceBytes 2GB`. Raising a budget does not imply complete semantic recovery.

When REA completes an operation but its response exceeds the MCP transport budget, the bridge exports the retained evidence and resolves only the exact evidence ID and operation named in that failure. Parsing is capped at 256 MiB and the overall evidence budget still applies. The original transport response and the complete export remain available. Recovered source files are rehashed after the semantic provider closes; mutation or disappearance fails the run.

`-MaxFunctions 0` attempts all discovered native functions within the overall evidence/time limits. A positive value bounds function attempts. `-TimeoutSeconds` bounds analyzer processes; `-AIReviewTimeoutSeconds` bounds each AI round; `-RuntimeSeconds` bounds the guest target. Basic string scanning is limited to 16 MiB, 20,000 strings and 8,192 characters per retained string, with truncation disclosed. Each process's combined stdout/stderr is capped at 64 MiB by a shared streaming budget.

Runtime constraints can change a program's behavior. Windows permits at most 32 active processes, 512 MiB of committed memory per process and 1 GiB for the job. It checks combined stdout/stderr against an 8 MiB threshold every 100 ms, so output can overshoot before termination; host retention separately caps each guest artifact at 16 MiB. Linux uses a 1 GiB address-space limit, a 64-process user limit, a 1 MiB per-file size limit and a CPU-time limit matching the requested runtime. An allocation failure or early exit under these constraints does not establish how the program behaves without them.

CI exercises deterministic local fixtures and a fake MCP peer; it does not claim to qualify live provider feeds, account authentication or guest OS installation. Separate real integration checks cover the actual REA/Ghidra/ILSpy/WABT/JADX tools and disposable VM behavior. Tests check meaningful recovered values/bytes and clean end states rather than only exit codes. See `tests/Validation.md` for the required regression commands.
