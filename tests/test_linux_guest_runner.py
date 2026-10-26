"""Linux guest command and fail-closed preflight checks; no target code executes."""
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

runner_path = pathlib.Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location('linux_guest_runner', runner_path)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class LinuxGuestRunnerTests(unittest.TestCase):
    def test_address_space_budget_is_explicit_bounded_and_literal(self):
        for budget in (128, 1024, 65536, 131072):
            with self.subTest(budget=budget):
                arguments = ['runner', '--owned-runner', '7', '--max-address-space-mb',
                             str(budget), '--virtual-display']
                timeout, display, parsed = runner.parse_runner_arguments(arguments)
                self.assertEqual((timeout, display, parsed), (7, True, budget))
                command = runner.build_launch_command(timeout, '/target', '/trace', display, parsed)
                self.assertIn('--as=' + str(budget * 1024 * 1024), command)
                self.assertIn('--nproc=64', command)
                self.assertIn('--no-new-privs', command)
        self.assertEqual(runner.parse_runner_arguments(['runner', '--owned-runner', '7']),
                         (7, False, 1024))
        for invalid in (0, 127, 131073, -1, 1024.5, '4096', True):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                runner.build_launch_command(7, '/target', '/trace', False, invalid)
        for options in (['--max-address-space-mb'], ['--max-address-space-mb', 'unlimited'],
                        ['--max-address-space-mb', '131073'], ['--max-address-space-mb', '0'],
                        ['--max-address-space-mb', '1024', '--max-address-space-mb', '65536'],
                        ['--virtual-display', '--virtual-display'], ['--unknown']):
            with self.subTest(options=options), self.assertRaises(ValueError):
                runner.parse_runner_arguments(['runner', '--owned-runner', '7'] + options)

    def test_invalid_budget_fails_before_input_access_or_launch(self):
        with (patch.object(runner.sys, 'platform', 'linux'),
              patch.object(runner.os, 'geteuid', return_value=0, create=True),
              patch.object(runner.sys, 'argv', ['runner', '--owned-runner', '7',
                                               '--max-address-space-mb', '131073']),
              patch.object(runner.pathlib, 'Path', side_effect=AssertionError('input touched')),
              patch.object(runner.subprocess, 'Popen', side_effect=AssertionError('target launched')),
              self.assertRaises(ValueError)):
            runner.main()

    def test_observed_interleaved_execve_fixture(self):
        fixture = pathlib.Path(__file__).with_name('fixtures') / 'linux-execve-resumed.strace'
        trace = fixture.read_text()
        self.assertTrue(runner.target_exec_observed(trace, '/opt/profile-analysis/target.bin'))
        self.assertFalse(runner.target_exec_observed(trace, '/different-target'))
        self.assertFalse(runner.target_exec_observed(
            trace.replace('<... execve resumed>)             = 0',
                          '<... execve resumed>)             = -1 ENOENT (No such file or directory)'),
            '/opt/profile-analysis/target.bin'))

    def test_execve_parser_rejects_false_success_and_incomplete_evidence(self):
        target = '/opt/profile-analysis/target.bin'
        start = '10 execve("' + target + '", ["target"], 0x123 /* 3 vars */ <unfinished ...>\n'
        resumed = '10 <... execve resumed>) = 0\n'
        positive = [start + '11 write(1, "other PID", 9) = 9\n' + resumed,
                    '10 execve("' + target + '", ["target"], 0x123) = 0\n',
                    start.replace('10 ', '[pid 10] ') + resumed.replace('10 ', '[pid 10] ')]
        for trace in positive:
            with self.subTest(trace=trace):
                self.assertTrue(runner.target_exec_observed(trace, target))
        negative = [
            start, resumed, start + resumed.rstrip('\n'),
            start + resumed.replace('10 ', '11 '),
            start + resumed.replace('= 0', '= -1 ENOENT (No such file or directory)'),
            start + '10 write(1, "lost resume", 11) = 11\n' + resumed,
            start + '10 execve("/bin/echo", ["other"], 0x123 <unfinished ...>\n' + resumed,
            '10 execve("/bin/echo", ["' + target + '", "execve(\\"' + target + '\\") = 0"], 0x123) = 0\n',
            '10 execve("' + target + '", ["misleading ) = 0"], 0x123) = -1 ENOENT\n',
            '10 execve("' + target + '", ["unterminated <unfinished ...>\n' + resumed,
            '10 execve("' + target + '.other", ["target"], 0x123) = 0\n',
            '10 execve("' + target + '", ["target"], 0x123) = 0',
        ]
        for trace in negative:
            with self.subTest(trace=trace):
                self.assertFalse(runner.target_exec_observed(trace, target))

    def test_default_and_display_keep_target_literal_and_unprivileged(self):
        target = '/opt/profile-analysis/input with spaces;touch injected'
        plain = runner.build_launch_command(7, target, '/evidence/trace')
        display = runner.build_launch_command(7, target, '/evidence/trace', True)
        self.assertEqual(plain[-1], target)
        self.assertEqual(display[-1], target)
        self.assertNotIn('/bin/sh', plain)
        self.assertNotIn('/usr/bin/xvfb-run', plain)
        self.assertEqual(display[:len(plain)-1], plain[:-1])
        self.assertLess(display.index('--reuid=65534'), display.index('/usr/bin/xvfb-run'))
        self.assertLess(display.index('--no-new-privs'), display.index('/usr/bin/xvfb-run'))
        self.assertIn('--as=1073741824', display)
        self.assertIn('--nproc=64', display)
        self.assertIn('--fsize=1048576', display)
        self.assertIn('--cpu=7', display)
        self.assertEqual(display[display.index('--server-args')+1],
                         '-screen 0 1280x720x24 -nolisten tcp')
        self.assertIn('-f', display[:display.index('/usr/bin/setpriv')])
        for invalid in (0, 601):
            with self.assertRaises(ValueError):
                runner.build_launch_command(invalid, target, '/evidence/trace', True)

    def test_dependency_inventory_requires_every_display_tool(self):
        self.assertEqual(runner.missing_display_tools(lambda _: True), [])
        self.assertEqual(runner.missing_display_tools(lambda p: p != '/usr/bin/xauth'),
                         ['/usr/bin/xauth'])
        self.assertEqual(len(runner.missing_display_tools(lambda _: False)), 3)

    def test_missing_display_tool_records_failure_without_launching(self):
        # Redirect fixed guest paths to inert fixtures; no binary is launched.
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / 'input.bin'
            header = bytearray(64)
            header[:6] = b'\x7fELF\x02\x01'
            header[18] = 62
            source.write_bytes(header)
            out = root / 'results'
            real_path = pathlib.Path
            paths = {
                '/home/analysis-admin/input.bin': source,
                '/home/analysis-admin/results': out,
                '/opt/profile-analysis/target.bin': root / 'target.bin',
                '/var/tmp/profile-analysis-work': root / 'work',
            }
            def guest_path(value):
                return paths.get(str(value), real_path(value))
            with (patch.object(runner.pathlib, 'Path', side_effect=guest_path),
                  patch.object(runner.sys, 'platform', 'linux'),
                  patch.object(runner.sys, 'argv', ['runner', '--owned-runner', '7', '--virtual-display',
                                                   '--max-address-space-mb', '65536']),
                  patch.object(runner.os, 'geteuid', return_value=0, create=True),
                  patch.object(runner, 'missing_display_tools', return_value=['/usr/bin/Xvfb']),
                  patch.object(runner.subprocess, 'check_output', side_effect=['lo UNKNOWN 127.0.0.1/8\n', '']),
                  patch.object(runner.subprocess, 'Popen', side_effect=AssertionError('target launched')) as launch):
                runner.main()
            launch.assert_not_called()
            record = json.loads((out / 'runtime.json').read_text())
            self.assertEqual(record['termination'], 'Unavailable')
            self.assertIsNone(record['exitCode'])
            self.assertFalse(record['targetExecObserved'])
            self.assertEqual(record['virtualDisplay']['missingTools'], ['/usr/bin/Xvfb'])
            self.assertEqual(record['uid'], 65534)
            self.assertEqual(record['maxAddressSpaceMB'], 65536)
            self.assertIn('--as=68719476736', record['command'])
            self.assertFalse((root / 'target.bin').exists())
            self.assertFalse((root / 'work').exists())
            self.assertIn('Virtual display prerequisites', record['error'])
            for name in ('stdout.txt', 'stderr.txt', 'strace.log'):
                self.assertEqual((out / name).stat().st_size, 0)


if __name__ == '__main__':
    unittest.main()
