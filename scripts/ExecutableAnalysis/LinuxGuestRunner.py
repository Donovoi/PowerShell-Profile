#!/usr/bin/python3
"""Trusted runner for the owned disposable Linux guest; never run targets on the host."""
import hashlib
import json
import os
import pathlib
import re
import signal
import stat
import subprocess
import sys
import time


def build_launch_command(timeout, target, trace, virtual_display=False,
                         max_address_space_mb=1024):
    """Return literal argv; the display server and target share unprivileged limits."""
    if not 1 <= timeout <= 600:
        raise ValueError('invalid timeout')
    if type(max_address_space_mb) is not int or not 128 <= max_address_space_mb <= 131072:
        raise ValueError('address-space budget must be 128 through 131072 MiB')
    command = [
        '/usr/bin/strace', '-f', '-qq', '-s', '256', '-o', str(trace),
        '/usr/bin/setpriv', '--reuid=65534', '--regid=65534', '--clear-groups',
        '--no-new-privs', '/usr/bin/prlimit',
        '--as=' + str(max_address_space_mb * 1024 * 1024), '--nproc=64',
        '--fsize=1048576', '--cpu=' + str(timeout), '--',
    ]
    if virtual_display:
        command += ['/usr/bin/xvfb-run', '--auto-servernum', '--server-args',
                    '-screen 0 1280x720x24 -nolisten tcp']
    return command + [str(target)]


def parse_runner_arguments(arguments):
    """Accept only the owned-controller protocol, with bounded explicit budgets."""
    if len(arguments) < 3 or arguments[1] != '--owned-runner':
        raise ValueError('invalid owned-runner invocation')
    timeout = int(arguments[2])
    virtual_display = False
    max_address_space_mb = 1024
    seen = set()
    index = 3
    while index < len(arguments):
        option = arguments[index]
        if option in seen:
            raise ValueError('duplicate runner option')
        seen.add(option)
        if option == '--virtual-display':
            virtual_display = True
        elif option == '--max-address-space-mb' and index + 1 < len(arguments):
            index += 1
            max_address_space_mb = int(arguments[index])
        else:
            raise ValueError('unknown or incomplete runner option')
        index += 1
    # Validate before the caller reads input or creates guest artifacts.
    build_launch_command(timeout, '', '', virtual_display, max_address_space_mb)
    return timeout, virtual_display, max_address_space_mb


def _outside_quoted_strings(text):
    """Ignore quoted arguments when interpreting strace completion markers."""
    result = []
    quoted = False
    escaped = False
    for character in text:
        if quoted:
            if escaped:
                escaped = False
            elif character == '\\':
                escaped = True
            elif character == '"':
                quoted = False
        elif character == '"':
            quoted = True
        else:
            result.append(character)
    return None if quoted else ''.join(result)


def target_exec_observed(trace, target):
    """Recognize completed execve success, correlating split records by PID.

    Only newline-terminated records count. Incomplete pairs, failed returns, or
    return-like text inside arguments cannot establish execution. Earlier complete
    successes remain evidence even when a later part of the trace is truncated.
    """
    expected_path = json.dumps(str(target), ensure_ascii=False)[1:-1]
    pending = {}
    for record in trace.splitlines(keepends=True):
        if not record.endswith('\n'):
            continue
        line = record.rstrip('\r\n')
        prefix = re.match(r'^(?:(\d+)\s+|\[pid\s+(\d+)\]\s+)(.*)$', line)
        pid = (prefix.group(1) or prefix.group(2)) if prefix else None
        body = prefix.group(3) if prefix else line
        resumed = re.match(r'^<\.\.\. execve resumed>(.*)$', body)
        if resumed:
            matched = pending.pop(pid, False) if pid is not None else False
            outside = _outside_quoted_strings(resumed.group(1))
            if matched and outside is not None and re.search(r'\)\s*=\s*0\s*$', outside):
                return True
            continue
        # A new record from this PID invalidates an unresolved prior execve.
        # Other PIDs may interleave freely between unfinished and resumed lines.
        if pid is not None:
            pending.pop(pid, None)
        start = re.match(r'^execve\("((?:[^"\\]|\\.)*)",', body)
        if not start or start.group(1) != expected_path:
            continue
        outside = _outside_quoted_strings(body)
        if outside is None:
            continue
        if re.search(r'\)\s*=\s*0\s*$', outside):
            return True
        if pid is not None and outside.endswith('<unfinished ...>'):
            pending[pid] = True
    return False


def missing_display_tools(executable=None):
    if executable is None:
        executable = lambda path: os.path.isfile(path) and os.access(path, os.X_OK)
    return [path for path in ('/usr/bin/xvfb-run', '/usr/bin/Xvfb', '/usr/bin/xauth')
            if not executable(path)]


def main():
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise RuntimeError('Use the owned offline guest controller to invoke this runner.')
    timeout, virtual_display, max_address_space_mb = parse_runner_arguments(sys.argv)
    source = pathlib.Path('/home/analysis-admin/input.bin')
    out = pathlib.Path('/home/analysis-admin/results')
    if source.is_symlink() or not source.is_file() or source.stat().st_size > 512 * 1024 * 1024:
        raise ValueError('input must be a bounded regular file')
    data = source.read_bytes()
    if data[:6] != b'\x7fELF\x02\x01' or int.from_bytes(data[18:20], 'little') != 62:
        raise ValueError('only little-endian x86-64 ELF is supported')
    target = pathlib.Path('/opt/profile-analysis/target.bin')
    command = build_launch_command(timeout, target, out / 'strace.log', virtual_display,
                                   max_address_space_mb)
    out.mkdir(mode=0o755, exist_ok=False)
    before = {
        'sha256': hashlib.sha256(data).hexdigest(),
        'network': subprocess.check_output(['/usr/sbin/ip', '-brief', 'address'], text=True),
        'routes': subprocess.check_output(['/usr/sbin/ip', 'route'], text=True),
    }
    if any(line.split()[0] != 'lo' for line in before['network'].splitlines()) or before['routes'].strip():
        raise RuntimeError('guest network isolation check failed')
    missing = missing_display_tools() if virtual_display else []
    display = {'requested': virtual_display, 'provider': 'Xvfb' if virtual_display else None,
               'missingTools': missing, 'tcpListening': False if virtual_display else None,
               'geometry': '1280x720x24' if virtual_display else None}
    # These files exist even when a prerequisite fails before target execution.
    for name in ('stdout.txt', 'stderr.txt', 'strace.log'):
        (out / name).touch(mode=0o644, exist_ok=False)
    start = time.monotonic()
    reason = 'Unavailable' if missing else 'Exited'
    exitcode = None
    work = pathlib.Path('/var/tmp/profile-analysis-work')
    files = []
    if not missing:
        if target.is_symlink() or work.exists() or work.is_symlink():
            raise RuntimeError('guest target/work paths are not clean')
        target.write_bytes(data)
        target.chmod(0o555)
        work.mkdir(mode=0o700)
        os.chown(work, 65534, 65534)
        with (out / 'stdout.txt').open('wb') as stdout, (out / 'stderr.txt').open('wb') as stderr:
            child = subprocess.Popen(
                command, cwd=work, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                start_new_session=True,
                env={'PATH': '/usr/bin:/bin', 'HOME': str(work), 'LANG': 'C.UTF-8'},
            )
            while child.poll() is None:
                if time.monotonic() - start >= timeout:
                    reason = 'Timeout'
                if sum(p.stat().st_size for p in out.iterdir() if p.is_file()) > 12 * 1024 * 1024:
                    reason = 'OutputLimit'
                if reason != 'Exited':
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=3)
                    break
                time.sleep(.1)
            # Detached descendants remain inside the VM; power-off is the final boundary.
            exitcode = child.returncode
        for directory, dirs, names in os.walk(work, followlinks=False):
            dirs[:] = dirs[:100]
            for name in names:
                path = pathlib.Path(directory) / name
                try:
                    info = path.lstat()
                    item = {'path': str(path.relative_to(work)), 'bytes': info.st_size,
                            'symlink': stat.S_ISLNK(info.st_mode)}
                    if stat.S_ISREG(info.st_mode) and info.st_size <= 1048576:
                        item['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
                    files.append(item)
                except OSError:
                    pass
                if len(files) >= 1000:
                    break
            if len(files) >= 1000:
                break
    trace = (out / 'strace.log').read_text(errors='replace')
    # strace follows descendants, including xvfb-run's target. A wrapper exit alone
    # does not establish that the selected executable was started successfully.
    target_exec = target_exec_observed(trace, target)
    if reason == 'Exited' and exitcode == 0 and not target_exec:
        reason = 'TargetExecutionUnverified'
    report = {
        'schema': 2, 'target': before, 'exitCode': exitcode, 'termination': reason,
        'elapsedSeconds': round(time.monotonic() - start, 3), 'createdFiles': files,
        'uid': 65534, 'virtualDisplay': display, 'command': command,
        'targetExecObserved': target_exec,
        'maxAddressSpaceMB': max_address_space_mb,
        'runnerSHA256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
        'limitations': ['Offline, unprivileged x86-64 Linux execution only.',
                        'The address-space budget limits virtual mappings per process, not resident RAM.',
                        'No command-line arguments or GUI interaction.',
                        'Guest observations are evidence, not proof of complete behavior.'],
    }
    if missing:
        report['error'] = 'Virtual display prerequisites are unavailable: ' + ', '.join(missing)
    (out / 'runtime.json').write_text(json.dumps(report, indent=2))
    for path in out.iterdir():
        if path.stat().st_size > 12 * 1024 * 1024:
            with path.open('r+b') as stream:
                stream.truncate(12 * 1024 * 1024)
        path.chmod(0o644)
    print(json.dumps({'status': reason, 'sha256': before['sha256']}))


if __name__ == '__main__':
    main()
