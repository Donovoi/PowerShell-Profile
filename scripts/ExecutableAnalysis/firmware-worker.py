#!/usr/bin/env python3
"""Bounded static Dell PFS -> UEFI -> IFR pipeline. Never runs target code.

Trusted tool executables must be supplied by the caller. This is resource and
path containment for parsers, not an OS sandbox for hostile analysis tools.
"""
import argparse
import ctypes
import hashlib
import json
import mmap
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone


class BoundError(RuntimeError):
    pass


def digest(path, deadline=None):
    result = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            if deadline is not None and time.monotonic() >= deadline:
                raise BoundError("Final inventory time budget reached")
            result.update(block)
    return result.hexdigest().upper()


def plain_path(path):
    path = Path(os.path.abspath(path))
    for item in (path, *path.parents):
        try:
            info = item.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise BoundError(f"Reparse point or symlink rejected: {item}")
    return path


def beneath(path, root):
    return os.path.commonpath((str(path), str(root))) == str(root)


def inventory(root, max_files, max_bytes, deadline=None):
    """No link traversal; cap both file and directory enumeration."""
    result, pending, total, directories = [], [plain_path(root)], 0, 0
    while pending:
        folder = pending.pop()
        with os.scandir(folder) as entries:
            for entry in entries:
                if deadline is not None and time.monotonic() >= deadline:
                    raise BoundError("Final inventory time budget reached")
                info = entry.stat(follow_symlinks=False)
                if entry.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
                    raise BoundError(f"Unsafe output link: {entry.path}")
                if entry.is_dir(follow_symlinks=False):
                    directories += 1
                    if directories > max_files * 4:
                        raise BoundError("Output directory-count limit reached")
                    pending.append(Path(entry.path))
                elif entry.is_file(follow_symlinks=False):
                    result.append((Path(entry.path), info.st_size))
                    total += info.st_size
                    if len(result) > max_files or total > max_bytes:
                        raise BoundError(f"Output limit reached: {len(result)} files, {total} bytes")
                else:
                    raise BoundError(f"Non-regular output rejected: {entry.path}")
    return result, total


class WindowsJob:
    """Contain child processes and cap their committed process memory."""
    def __init__(self, memory):
        self.handle = None
        if os.name != "nt":
            return
        from ctypes import wintypes
        class Basic(ctypes.Structure):
            _fields_ = [("per_process", ctypes.c_int64), ("per_job", ctypes.c_int64),
                        ("flags", wintypes.DWORD), ("min_working", ctypes.c_size_t),
                        ("max_working", ctypes.c_size_t), ("active", wintypes.DWORD),
                        ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD),
                        ("scheduling", wintypes.DWORD)]
        class Counters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in ("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]
        class Extended(ctypes.Structure):
            _fields_ = [("basic", Basic), ("io", Counters), ("process_memory", ctypes.c_size_t),
                        ("job_memory", ctypes.c_size_t), ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.CreateJobObjectW.restype = wintypes.HANDLE
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        self.api.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        self.api.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        self.api.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.handle = self.api.CreateJobObjectW(None, None)
        limits = Extended()
        limits.basic.flags = 0x2000 | 0x100 | 0x200  # kill on close, process + job memory
        limits.process_memory = memory
        limits.job_memory = memory
        if not self.handle or not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            self.close()
            raise BoundError("Could not establish Windows child memory/process limits")

    def attach(self, process):
        if self.handle and not self.api.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise BoundError("Could not attach tool process to its Windows job")

    def close(self):
        if self.handle:
            self.api.TerminateJobObject(self.handle, 1)
            self.api.CloseHandle(self.handle)
            self.handle = None


def parser_mode(args):
    root = plain_path(args.output)
    source = plain_path(args.input)
    library = plain_path(args.bios_utilities)
    if args.python_dependencies:
        sys.path.insert(0, str(plain_path(args.python_dependencies)))
    sys.path.insert(0, str(library))
    # Hooks apply before importing the parser. Imports may read trusted tools,
    # but writes must stay under the parser root. Subprocess/network execution
    # is forbidden even if a future parser begins delegating work.
    def check_write(value):
        if isinstance(value, int):
            return
        candidate = plain_path(os.fsdecode(value))
        if not beneath(candidate, root):
            raise BoundError(f"Parser write outside extraction root rejected: {candidate}")

    def audit(event, values):
        if event in ("subprocess.Popen", "os.system", "os.exec", "os.posix_spawn", "os.startfile") or event.startswith("socket."):
            raise BoundError(f"Parser execution/network action rejected: {event}")
        if event == "open":
            mode, flags = values[1], values[2]
            if (isinstance(mode, str) and any(c in mode for c in "wax+")) or (isinstance(flags, int) and flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND)):
                check_write(values[0])
        elif event in ("os.mkdir", "os.remove", "os.rmdir", "os.chmod", "os.utime"):
            check_write(values[0])
        elif event in ("os.rename", "os.replace"):
            check_write(values[0]); check_write(values[1])
        elif event in ("os.symlink", "os.link"):
            raise BoundError("Parser link creation rejected")
    sys.addaudithook(audit)
    from biosutilities.dell_pfs_extract import DellPfsExtract
    extractor = DellPfsExtract(input_object=str(source), extract_path=str(root), advanced=True, structure=True)
    # ThinOS package parsing can invoke an archiver and is deliberately outside
    # this provider. Only the Dell compressed PFS path is enabled.
    if extractor._is_pfs_pkg(extractor.input_buffer) or not extractor.check_format():
        raise BoundError("Input is not a supported Dell compressed PFS image")
    if not extractor.parse_format():
        raise BoundError("Dell PFS parser did not report success")


def firmware_volumes(path):
    """Recognize bounded, checksum-valid FV headers, not filename claims."""
    if path.stat().st_size < 56:
        return []
    found = []
    with open(path, "rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        offset = 0
        while len(found) < 128:
            marker = data.find(b"_FVH", offset)
            if marker < 0:
                break
            offset = marker + 4
            start = marker - 40
            if start < 0 or start + 56 > len(data):
                continue
            length = struct.unpack_from("<Q", data, start + 32)[0]
            header = struct.unpack_from("<H", data, start + 48)[0]
            if 56 <= header <= 4096 and header % 2 == 0 and header <= length <= len(data) - start:
                words = struct.unpack_from("<" + "H" * (header // 2), data, start)
                if sum(words) & 0xFFFF == 0:
                    found.append({"Offset": start, "Length": length, "HeaderLength": header})
    return found


class Pipeline:
    def __init__(self, args):
        self.args = args
        self.source, self.root = plain_path(args.input), plain_path(args.output)
        if self.root.exists():
            raise BoundError("Output directory must not already exist")
        self.root.mkdir(parents=True)
        self.started = time.monotonic()
        self.calls, self.variants, self.diagnostics = [], [], []
        self.parents, self.stage_roots = {}, []
        self.last_bytes, self.last_files = 0, 0
        self.result = {"SchemaVersion": 1, "Status": "Succeeded", "InputPath": str(self.source),
                       "InputSHA256Before": digest(self.source), "InputSHA256After": None,
                       "InputUnchanged": False, "TargetExecuted": False, "Files": [],
                       "Variants": self.variants, "Tools": [], "ToolCalls": self.calls,
                       "Diagnostics": self.diagnostics, "DiagnosticsTruncated": False, "DiagnosticsOmitted": 0, "Limitations": [
                           "Static extraction does not validate firmware authenticity, flashability, runtime behavior or hardware applicability.",
                           "PFS reconstruction may contain filled PFAT gaps; reconstructed components are not a full physical flash dump.",
                           "IFR covers unique PE32 section bodies within the configured module budget; other HII storage layouts and languages may be absent.",
                           "Growth in each tool's isolated output directory and logs is polled every 100 ms plus enumeration time against cumulative byte/file counts; thresholds may overshoot before termination. Full inventories run at stage boundaries. Final metadata is outside the payload budget.",
                           "Path checks and parser audit hooks are not an OS sandbox for malicious trusted tools."],
                       "Limits": {"MaxOutputBytes": args.max_output_bytes, "MaxFiles": args.max_files,
                                  "MaxIFRModules": args.max_ifr_modules, "MaxMemoryBytes": args.max_memory_bytes,
                                  "TimeoutSeconds": args.timeout}, "Summary": {"InventoryComplete": False}}

    def check(self, scan=True):
        if time.monotonic() - self.started >= self.args.timeout:
            raise BoundError("Firmware pipeline timeout reached")
        if scan:
            result, self.last_bytes = inventory(self.root, self.args.max_files, self.args.max_output_bytes)
            self.last_files = len(result)
            return result, self.last_bytes

    def note(self, message, stage=None):
        if self.result["Status"] != "Failed":
            self.result["Status"] = "Partial"
        if len(self.diagnostics) < 2048:
            self.diagnostics.append({"Stage": stage, "Message": message})
        else:
            self.result["DiagnosticsTruncated"] = True
            self.result["DiagnosticsOmitted"] += 1

    def tool(self, name, value):
        path = plain_path(value)
        if not path.is_file() or beneath(path, self.root) or path == self.source:
            raise BoundError(f"Invalid trusted tool path for {name}")
        sha = digest(path)
        if sha == self.result["InputSHA256Before"]:
            raise BoundError(f"Input content cannot be used as a tool: {name}")
        self.result["Tools"].append({"Name": name, "Path": str(path), "SHA256": sha})
        return str(path)

    def run(self, name, command, cwd):
        self.check(scan=False)
        existing, existing_bytes = inventory(cwd, self.args.max_files, self.args.max_output_bytes)
        previous_bytes = self.last_bytes - existing_bytes
        previous_files = self.last_files - len(existing)
        if previous_bytes < 0 or previous_files < 0:
            raise BoundError("Output accounting changed unexpectedly before tool execution")
        number = len(self.calls) + 1
        logs = self.root / "tool-logs"
        logs.mkdir(exist_ok=True)
        stdout, stderr = logs / f"{number:04}-{name}.stdout", logs / f"{number:04}-{name}.stderr"
        record = {"Stage": name, "FilePath": command[0], "ArgumentList": command[1:],
                  "ExecutableSHA256": digest(command[0]), "WorkingDirectory": str(cwd),
                  "StandardOutputPath": str(stdout.relative_to(self.root)), "StandardErrorPath": str(stderr.relative_to(self.root)),
                  "StartedUtc": datetime.now(timezone.utc).isoformat(), "Status": "Started", "ExitCode": None}
        self.calls.append(record)
        def monitor():
            self.check(scan=False)
            local_files, local_bytes = inventory(cwd, self.args.max_files, self.args.max_output_bytes)
            log_bytes = stdout.stat().st_size + stderr.stat().st_size
            if log_bytes > 16 * 1024 * 1024:
                raise BoundError(f"Tool log limit reached: {name}")
            self.last_bytes = previous_bytes + local_bytes + log_bytes
            self.last_files = previous_files + len(local_files) + 2
            if self.last_bytes > self.args.max_output_bytes or self.last_files > self.args.max_files:
                raise BoundError(f"Output limit reached: {self.last_files} files, {self.last_bytes} bytes")
        process, job = None, WindowsJob(self.args.max_memory_bytes)
        started = time.monotonic()
        try:
            with open(stdout, "xb") as out, open(stderr, "xb") as err:
                environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1")
                options = {"creationflags": 0x08000000} if os.name == "nt" else {"start_new_session": True}
                if os.name != "nt":
                    def restrict():
                        import resource
                        resource.setrlimit(resource.RLIMIT_AS, (self.args.max_memory_bytes, self.args.max_memory_bytes))
                    options["preexec_fn"] = restrict
                process = subprocess.Popen(command, cwd=cwd, stdin=subprocess.DEVNULL, stdout=out, stderr=err, env=environment, **options)
                job.attach(process)
                while process.poll() is None:
                    monitor()
                    time.sleep(0.1)
                record["ExitCode"] = process.returncode
                record["Status"] = "Completed" if process.returncode == 0 else "Failed"
                monitor()
        except Exception as error:
            record["Status"] = "Aborted"
            record["Reason"] = str(error)
            raise
        finally:
            if process and process.poll() is None:
                if os.name == "nt":
                    process.kill()
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            job.close()
            record["Seconds"] = round(time.monotonic() - started, 3)
        # Observed IFRExtractor 1.6.1 outcomes: code 2 is an explicit absence,
        # code 3 is insufficient data and must remain a Partial observation.
        # Never normalize an unexpected exit code, message or stderr content.
        observed_text = (stdout.read_text(encoding="utf-8", errors="replace").strip()
                         if name == "IFR" and stdout.stat().st_size <= 128 and stderr.stat().st_size == 0 else None)
        no_forms = record["ExitCode"] == 2 and observed_text == "No IFR data found"
        insufficient_forms = (record["ExitCode"] == 3
                              and observed_text == "Not enough IFR data found to complete extraction")
        if no_forms:
            record["Status"] = "NoForms"
            record["Observation"] = "IFRExtractor explicitly reported no IFR data in this PE32 body."
        elif insufficient_forms:
            record["Status"] = "InsufficientData"
            record["Observation"] = observed_text
            self.note(observed_text + "; this module's form extraction is incomplete", name)
        for path in (stdout, stderr):
            with open(path, encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    metadata_field = name == "PFS" and re.match(r"^\s*Unknown(?:\s+\d+)?\s*:\s*0x[0-9a-f]+\s*$", line, re.I)
                    if re.search(r"\b(warn(?:ing)?|error|invalid|unknown|failed|gap)\b", line, re.I) and not metadata_field:
                        self.note(line.strip()[:2048], name)
        if record["ExitCode"] != 0 and not (no_forms or insufficient_forms):
            self.note(f"Tool exited with code {record['ExitCode']}; inspect retained stdout/stderr", name)
        return record

    def copy(self, source, destination, parent):
        self.check(scan=False)
        if self.last_bytes + source.stat().st_size > self.args.max_output_bytes:
            raise BoundError("Output byte budget would be exceeded by preserved parser input")
        destination.parent.mkdir(parents=True, exist_ok=True)
        with open(source, "rb") as src, open(destination, "xb") as dst:
            shutil.copyfileobj(src, dst, 1024 * 1024)
        self.parents[str(destination)] = str(parent)
        self.last_bytes += destination.stat().st_size
        self.last_files += 1

    def execute(self):
        if self.result["InputSHA256Before"] != self.args.expected_sha256.upper():
            raise BoundError("Input changed before worker startup")
        if self.source.stat().st_size > 1024 * 1024 * 1024:
            raise BoundError("Input exceeds the one GiB parser limit")
        python = self.tool("Python", sys.executable)
        uefi = self.tool("UEFIExtract", self.args.uefi_extract)
        ifr = self.tool("IFRExtractor", self.args.ifr_extractor)
        self.tool("Worker", __file__)
        library = plain_path(self.args.bios_utilities)
        files, _ = inventory(library / "biosutilities", 1024, 64 * 1024 * 1024)
        sources = [{"Path": str(path.relative_to(library)), "SHA256": digest(path)} for path, _ in files if path.suffix == ".py"]
        self.result["Tools"].append({"Name": "BIOSUtilities", "Path": str(library), "Sources": sources})
        pfs = self.root / "pfs"
        pfs.mkdir()
        self.stage_roots.append((pfs, "PFS", str(self.source)))
        command = [python, "-B"]
        if self.args.python_dependencies:
            dependencies = plain_path(self.args.python_dependencies)
            dependency_files, _ = inventory(dependencies, 4096, 128 * 1024 * 1024)
            self.result["Tools"].append({"Name": "PythonDependencies", "Path": str(dependencies),
                                        "Files": [{"Path": str(path.relative_to(dependencies)), "SHA256": digest(path)} for path, _ in dependency_files]})
            command.extend(["-I", "-S"])
        command.extend([str(Path(__file__).absolute()), "--parser", "--input", str(self.source), "--output", str(pfs), "--bios-utilities", str(library)])
        if self.args.python_dependencies:
            command.extend(["--python-dependencies", str(dependencies)])
        call = self.run("PFS", command, pfs)
        if call["ExitCode"] != 0:
            raise BoundError("Dell PFS extraction failed")
        entries, _ = self.check()
        components = []
        for path, _ in sorted(entries):
            if beneath(path, pfs) and path.name.endswith(".data.bin"):
                volumes = firmware_volumes(path)
                if volumes:
                    components.append((path, volumes))
        if not components:
            self.note("No PFS component contained a checksum-valid UEFI firmware volume header", "PFS")
        seen, scanned, total_modules, module_groups = {}, 0, 0, []
        for index, (component, volumes) in enumerate(components, 1):
            label = f"variant-{index:03}"
            folder = self.root / "uefi" / label
            copied = folder / "firmware.bin"
            self.copy(component, copied, component)
            self.stage_roots.append((folder, "UEFI", str(component)))
            variant = {"Id": label, "ComponentPath": str(component.relative_to(self.root)),
                       "SHA256": digest(component), "Bytes": component.stat().st_size,
                       "FirmwareVolumes": volumes, "UEFIInputPath": str(copied.relative_to(self.root)), "IFRModules": []}
            self.variants.append(variant)
            call = self.run("UEFI", [uefi, str(copied)], folder)
            variant["UEFIStatus"] = call["Status"]
            entries, _ = self.check()
            modules = sorted(path for path, _ in entries if beneath(path, folder) and path.name == "body.bin" and re.search(r"\bPE32 image section$", path.parent.name, re.I))
            total_modules += len(modules)
            module_groups.append((variant, modules))
        # Complete every component's UEFI pass first. Within each variant, give
        # likely setup/form modules first access to a bounded IFR scan budget.
        for variant, modules in module_groups:
            modules.sort(key=lambda path: (not bool(re.search(r"setup|form", str(path), re.I)), str(path)))
            for module in modules:
                self.check(scan=False)
                sha = digest(module)
                if sha in seen:
                    variant["IFRModules"].append({"Path": str(module.relative_to(self.root)), "SHA256": sha, "DuplicateOf": seen[sha]})
                    continue
                if scanned >= self.args.max_ifr_modules:
                    self.note("Unique PE32 module scan limit reached; remaining modules were not examined", "IFR")
                    break
                scanned += 1
                ifr_folder = self.root / "ifr" / f"module-{scanned:04}"
                ifr_input = ifr_folder / "module.bin"
                self.copy(module, ifr_input, module)
                self.stage_roots.append((ifr_folder, "IFR", str(module)))
                seen[sha] = str(ifr_input.relative_to(self.root))
                call = self.run("IFR", [ifr, str(ifr_input), "verbose"], ifr_folder)
                variant["IFRModules"].append({"Path": str(module.relative_to(self.root)), "SHA256": sha,
                                              "InputPath": str(ifr_input.relative_to(self.root)), "Status": call["Status"]})
        self.result["Summary"].update(Variants=len(self.variants), PE32Bodies=total_modules, UniqueIFRModulesScanned=scanned,
                                      IFRNoForms=sum(call["Status"] == "NoForms" for call in self.calls),
                                      IFRInsufficientData=sum(call["Status"] == "InsufficientData" for call in self.calls),
                                      FailedToolCalls=sum(call["Status"] in ("Failed", "Aborted") for call in self.calls))
        self.menu_summary()

    def menu_summary(self):
        entries, _ = self.check()
        packages = sorted(path for path, _ in entries if beneath(path, self.root / "ifr") and path.name.endswith(".ifr.txt"))
        self.result["FormPackageTextPaths"] = [str(path) for path in packages]
        rows, read_bytes, truncated = [], 0, False
        read_limit = 32 * 1024 * 1024
        for package in packages:
            with open(package, "rb") as stream:
                number = 0
                while True:
                    # A single sentinel byte distinguishes an exact-size EOF
                    # from a longer line without allocating an unbounded line.
                    raw = stream.readline(max(0, read_limit - read_bytes) + 1)
                    if not raw:
                        break
                    number += 1
                    read_bytes += len(raw)
                    if read_bytes > read_limit or len(rows) >= 2048:
                        truncated = True
                        break
                    line = raw.decode("utf-8", errors="replace").strip()
                    if re.search(r"\b(FormSet Guid:|Form FormId:|(?:OneOf|CheckBox|Numeric|String|Password|OrderedList|Action|Ref) Prompt:)", line):
                        rows.append({"Path": str(package.relative_to(self.root)), "Line": number,
                                     "Declaration": line.split(" { ", 1)[0][:768]})
            if truncated:
                break
        summary = {"Scope": "Extracted HII declarations; visibility, conditions, defaults and hardware applicability require review of the full IFR.",
                   "FormPackageTextPaths": self.result["FormPackageTextPaths"], "Declarations": rows,
                   "Truncated": truncated, "ReadLimitBytes": read_limit, "ReadBytes": read_bytes,
                   "ReadSentinelBytes": max(0, read_bytes - read_limit)}
        path = self.root / "menu-summary.json"
        with open(path, "x", encoding="utf-8") as stream:
            json.dump(summary, stream, indent=2)
        self.result["MenuSummaryPath"] = str(path)
        self.result["Summary"].update(FormPackages=len(packages), MenuDeclarations=len(rows), MenuSummaryTruncated=truncated)
        if truncated:
            self.note("Menu summary reached its bounded read/declaration limit; full IFR files are retained", "IFR")

    def finish(self):
        try:
            after = digest(self.source)
            self.result["InputSHA256After"] = after
            self.result["InputUnchanged"] = after == self.result["InputSHA256Before"] == self.args.expected_sha256.upper()
        except OSError as error:
            self.note(f"Input could not be hashed after extraction: {error}")
        if not self.result["InputUnchanged"]:
            self.result["Status"] = "Failed"
            self.note("Input preservation check failed")
        try:
            deadline = self.started + self.args.timeout + 1.5
            entries, total = inventory(self.root, self.args.max_files, self.args.max_output_bytes, deadline)
            hashes = {str(path): digest(path, deadline) for path, _ in entries}
            hashes[str(self.source)] = self.result["InputSHA256Before"]
            roots = {str(root): (stage, parent) for root, stage, parent in self.stage_roots}
            for path, size in sorted(entries):
                if time.monotonic() >= deadline:
                    raise BoundError("Final inventory time budget reached")
                stage, parent = "ToolLog", None
                for ancestor in path.parents:
                    if str(ancestor) in roots:
                        stage, parent = roots[str(ancestor)]
                        break
                    if ancestor == self.root:
                        break
                parent = self.parents.get(str(path), parent)
                self.result["Files"].append({"Path": str(path.relative_to(self.root)), "Bytes": size,
                                             "SHA256": hashes[str(path)], "Stage": stage,
                                             "ParentPath": str(Path(parent).relative_to(self.root)) if parent and beneath(Path(parent), self.root) else parent,
                                             "ParentSHA256": hashes.get(parent)})
            self.result["Summary"].update(InventoryComplete=True, Files=len(entries), Bytes=total)
        except (OSError, BoundError) as error:
            self.note(f"Final inventory incomplete: {error}")
        self.result["Summary"]["Seconds"] = round(time.monotonic() - self.started, 3)
        # Final metadata is deliberately outside the payload limit, so a budget
        # failure can still leave an honest machine-readable result.
        plain_path(self.root)
        with open(self.root / "firmware-result.json", "x", encoding="utf-8") as stream:
            json.dump(self.result, stream, indent=2)
        print(json.dumps({"Status": self.result["Status"], "Summary": self.result["Summary"]}))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--bios-utilities", required=True)
    parser.add_argument("--parser", action="store_true")
    parser.add_argument("--python-dependencies")
    parser.add_argument("--uefi-extract")
    parser.add_argument("--ifr-extractor")
    parser.add_argument("--expected-sha256", default="")
    parser.add_argument("--timeout", type=int, default=597)
    parser.add_argument("--max-output-bytes", type=int, default=1024 ** 3)
    parser.add_argument("--max-files", type=int, default=30000)
    parser.add_argument("--max-ifr-modules", type=int, default=1024)
    parser.add_argument("--max-memory-bytes", type=int, default=2 * 1024 ** 3)
    args = parser.parse_args()
    if args.parser:
        parser_mode(args)
        return
    pipeline = Pipeline(args)
    try:
        pipeline.execute()
    except Exception as error:
        pipeline.result["Status"] = "Failed" if not pipeline.variants else "Partial"
        pipeline.note(f"{type(error).__name__}: {error}")
    finally:
        pipeline.finish()


if __name__ == "__main__":
    main()
