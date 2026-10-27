#!/usr/bin/env python3
"""Control-lock regressions, using a temporary project and fake control clients.

Run with: python3 -I tools/tests/test_control_lock.py
No command here can inspect or operate the real app, probe, or control lock.
"""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


STUB = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

state = Path(os.environ["CONTROL_LOCK_TEST_STATE"])
command = Path(sys.argv[0]).name

def gate(name):
    (state / (name + ".called")).touch()
    if not (state / (name + ".block")).exists():
        return
    (state / (name + ".ready")).touch()
    deadline = time.monotonic() + 8
    while not (state / (name + ".continue")).exists():
        if time.monotonic() > deadline:
            sys.exit(70)
        time.sleep(0.005)

def exit_code(name):
    path = state / (name + ".exit")
    return int(path.read_text()) if path.exists() else 0

def interrupted(signum, frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)

if command == "pgrep":
    if (state / "pgrep.error").exists():
        sys.exit(2)
    path = state / ("app.pid" if "Contents/MacOS" in sys.argv[-1] else "probe.pid")
    if path.exists():
        print(path.read_text().strip())
        sys.exit(0)
    sys.exit(1)
elif command == "package_app.sh":
    gate("package")
    sys.exit(exit_code("package"))
elif command == "open":
    if (state / "open.ignore-term").exists():
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    gate("open")
    result = exit_code("open")
    if not result and not (state / "open.delayed").exists():
        (state / "app.pid").write_text("4242")
    sys.exit(result)
elif command == "osascript":
    gate("quit")
    sys.exit(exit_code("quit"))
elif command == "pkill":
    gate("kill")
    if not (state / "stubborn").exists():
        (state / "app.pid").unlink(missing_ok=True)
    sys.exit(exit_code("kill"))
elif command == "perch-probe":
    (state / "probe.pid").write_text(str(os.getpid()))
    try:
        gate("probe")
        sys.exit(exit_code("probe"))
    finally:
        (state / "probe.pid").unlink(missing_ok=True)
elif command == "mv":
    gate("move")
    sys.exit(subprocess.call(["/bin/mv", *sys.argv[1:]]))
elif command == "mkdir":
    try:
        os.mkdir(sys.argv[-1])
    except OSError:
        sys.exit(1)
    if sys.argv[-1].endswith(".gate"):
        gate("mkdir")
else:
    raise RuntimeError("unexpected stub command")
'''

START_BARRIER = r'''
import os, sys, time
from pathlib import Path
marker, script, *arguments = sys.argv[1:]
deadline = time.monotonic() + 8
while not Path(marker).exists():
    if time.monotonic() > deadline:
        sys.exit(70)
    time.sleep(0.005)
os.execv("/bin/bash", ["bash", script, *arguments])
'''


class ControlLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="perch-lock-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.state = self.root / "state"
        self.tools = self.root / "tools"
        for path in (self.bin, self.state, self.tools, self.root / ".build/debug"):
            path.mkdir(parents=True)
        source = Path(__file__).resolve().parents[1] / "control-lock.sh"
        self.script = self.tools / "control-lock.sh"
        shutil.copy2(source, self.script)
        self.lock = self.root / ".control-session.lock"
        self.gate = self.root / ".control-session.lock.gate"
        self.stub = self.bin / "stub"
        self.stub.write_text(STUB)
        self.stub.chmod(0o755)
        for name in ("pgrep", "pkill", "open", "osascript"):
            (self.bin / name).symlink_to(self.stub)
        (self.tools / "package_app.sh").symlink_to(self.stub)
        (self.root / ".build/debug/perch-probe").symlink_to(self.stub)
        # Bounded retries finish quickly; synchronization uses marker gates.
        (self.bin / "sleep").write_text("#!/bin/sh\nexec /bin/sleep 0.01\n")
        (self.bin / "sleep").chmod(0o755)
        self.environment = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                                CONTROL_LOCK_TEST_STATE=str(self.state))
        self.processes = []
        self.addCleanup(self.stop_processes)

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)

    def start(self, *arguments, barrier=None):
        if barrier is None:
            command = ["/bin/bash", str(self.script), *arguments]
        else:
            command = [sys.executable, "-I", "-c", START_BARRIER, str(barrier), str(self.script), *arguments]
        process = subprocess.Popen(command, env=self.environment, cwd=self.root,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        self.processes.append(process)
        return process

    def finish(self, process, expected=None):
        stdout, stderr = process.communicate(timeout=12)
        if expected is not None:
            self.assertEqual(process.returncode, expected, (stdout, stderr))
        return process.returncode, stdout, stderr

    def run_lock(self, *arguments, expected=0):
        return self.finish(self.start(*arguments), expected)

    def mark(self, name, contents=""):
        (self.state / name).write_text(contents)

    def await_marker(self, name):
        deadline = time.monotonic() + 8
        while not (self.state / name).exists():
            if time.monotonic() > deadline:
                self.fail("stub did not reach marker: " + name)
            time.sleep(0.005)

    def fields(self):
        return dict(line.split("=", 1) for line in self.lock.read_text().splitlines())

    def assert_free(self):
        self.assertFalse(self.lock.exists())
        self.assertFalse(self.gate.exists())
        self.assertEqual(list(self.root.glob(".control-session.lock.tmp.*")), [])

    def test_reservation_blocks_other_and_same_owner_until_release(self):
        self.run_lock("acquire", "session-a", "app")
        original = self.lock.read_bytes()
        for owner in ("session-b", "session-a"):
            self.run_lock("acquire", owner, "app", expected=1)
            self.assertEqual(self.lock.read_bytes(), original)
        self.run_lock("release", "session-b", expected=1)
        self.assertEqual(self.lock.read_bytes(), original)
        self.run_lock("release", "session-a")
        self.assert_free()
        self.run_lock("acquire", "session-b", "probe")
        self.assertEqual(self.fields()["owner"], "session-b")

    def test_parallel_acquires_have_exactly_one_winner(self):
        barrier = self.state / "go"
        processes = [self.start("acquire", "session-" + str(index), "app", barrier=barrier)
                     for index in range(8)]
        barrier.touch()
        results = [self.finish(process)[0] for process in processes]
        self.assertEqual(results.count(0), 1, results)
        self.assertEqual(results.count(1), 7, results)
        self.assertFalse(self.gate.exists())
        self.assertEqual(self.fields()["owner"], "session-" + str(results.index(0)))

    def test_concurrent_release_and_acquire_preserve_a_single_reservation(self):
        self.run_lock("acquire", "session-a", "app")
        barrier = self.state / "go"
        release = self.start("release", "session-a", barrier=barrier)
        acquire = self.start("acquire", "session-b", "app", barrier=barrier)
        barrier.touch()
        self.finish(release, 0)
        result = self.finish(acquire)[0]
        self.assertIn(result, (0, 1))
        if result == 0:
            self.assertEqual(self.fields()["owner"], "session-b")
        else:
            self.assert_free()

    def test_process_without_reservation_blocks_acquire_and_unforced_stop(self):
        self.mark("app.pid", "4242")
        self.run_lock("acquire", "session-a", "app", expected=1)
        self.run_lock("app-stop", "session-a", expected=1)
        self.assertFalse((self.state / "quit.called").exists())
        self.assertFalse(self.lock.exists())
        self.run_lock("app-stop", "session-a", "force")
        self.assert_free()

    def test_force_release_does_not_release_a_live_process(self):
        self.run_lock("acquire", "session-a", "app")
        self.mark("app.pid", "4242")
        self.run_lock("release", "session-b", "force", expected=1)
        self.assertEqual(self.fields()["owner"], "session-a")
        self.assertTrue((self.state / "app.pid").exists())

    def test_process_inspection_failure_does_not_mean_no_client(self):
        self.mark("pgrep.error")
        self.run_lock("acquire", "session-a", "app", expected=1)
        self.assert_free()

    def test_empty_and_malformed_reservations_require_explicit_recovery(self):
        for contents in ("", "owner=session-a\n", "owner=\nrole=app\n", "state=stopping\n"):
            with self.subTest(contents=contents):
                self.lock.write_text(contents)
                self.run_lock("acquire", "session-a", "app", expected=1)
                self.run_lock("release", "session-a", expected=1)
                self.run_lock("app-stop", "session-a", "force", expected=1)
                self.assertEqual(self.lock.read_text(), contents)
                self.assertFalse((self.state / "quit.called").exists())
                self.run_lock("release", "session-a", "force")
                self.assert_free()

    def test_packaging_failure_cleans_only_its_own_reservation(self):
        self.mark("package.exit", "9")
        self.run_lock("app-start", "session-a", expected=9)
        self.assertFalse((self.state / "open.called").exists())
        self.assert_free()

    def test_launch_failure_retains_uncertain_reservation_and_cleans_gate(self):
        self.mark("open.exit", "8")
        self.run_lock("app-start", "session-a", expected=8)
        self.assertEqual(self.fields()["state"], "launching")
        self.assertFalse(self.gate.exists())
        self.run_lock("release", "session-a", expected=1)
        self.run_lock("release", "session-a", "force")
        self.assert_free()

    def test_start_and_stop_update_and_release_reservation(self):
        self.run_lock("app-start", "session-a")
        fields = self.fields()
        self.assertEqual(fields["state"], "running")
        self.assertEqual(fields["pid"], "4242")
        self.assertFalse(self.gate.exists())
        self.run_lock("app-stop", "session-b", expected=1)
        self.assertFalse((self.state / "quit.called").exists())
        self.run_lock("app-stop", "session-a")
        self.assert_free()

    def test_asynchronous_launch_retains_reservation_before_process_appears(self):
        self.mark("open.delayed")
        self.run_lock("app-start", "session-a")
        self.assertEqual(self.fields()["pid"], "0")
        self.assertEqual(self.fields()["state"], "launching")
        self.run_lock("acquire", "session-b", "app", expected=1)
        self.run_lock("app-stop", "session-a", expected=1)
        self.run_lock("app-stop", "session-a", "force", expected=1)
        self.run_lock("release", "session-a", expected=1)
        self.assertFalse((self.state / "quit.called").exists())
        self.mark("app.pid", "4242")
        self.run_lock("app-stop", "session-a")
        self.assert_free()

    def test_forced_replacement_during_build_prevents_stale_launch_and_cleanup(self):
        # Reusing the same owner specifically proves identity is token-based.
        self.mark("package.block")
        startup = self.start("app-start", "session-a")
        self.await_marker("package.ready")
        old_token = self.fields()["token"]
        self.run_lock("release", "session-b", "force")
        self.run_lock("acquire", "session-a", "app")
        replacement = self.lock.read_bytes()
        self.assertNotEqual(self.fields()["token"], old_token)
        self.mark("package.continue")
        self.finish(startup, 1)
        self.assertFalse((self.state / "open.called").exists())
        self.assertEqual(self.lock.read_bytes(), replacement)
        self.assertFalse(self.gate.exists())

    def test_signal_during_gated_launch_cleans_without_reentering_own_gate(self):
        self.mark("open.block")
        startup = self.start("app-start", "session-a")
        self.await_marker("open.ready")
        self.assertTrue(self.gate.exists())
        startup.send_signal(signal.SIGTERM)
        self.finish(startup, 143)
        self.assertFalse(self.gate.exists())
        self.assertEqual(self.fields()["state"], "launching")
        self.run_lock("acquire", "session-b", "app", expected=1)
        self.run_lock("release", "session-a", "force")
        self.assert_free()
        self.run_lock("acquire", "session-b", "app")

    def test_signal_during_gate_initialization_cleans_owned_marker(self):
        (self.bin / "mkdir").symlink_to(self.stub)
        self.mark("mkdir.block")
        acquire = self.start("acquire", "session-a", "app")
        self.await_marker("mkdir.ready")
        acquire.send_signal(signal.SIGTERM)
        self.mark("mkdir.continue")
        self.finish(acquire, 143)
        self.assert_free()

    def test_repeated_signal_does_not_interrupt_owned_gate_cleanup(self):
        self.mark("open.block")
        self.mark("open.ignore-term")
        startup = self.start("app-start", "session-a")
        self.await_marker("open.ready")
        startup.send_signal(signal.SIGTERM)
        # The child deliberately holds cleanup until its bounded kill escalates.
        time.sleep(0.04)
        startup.send_signal(signal.SIGTERM)
        self.finish(startup, 143)
        self.assertFalse(self.gate.exists())
        self.assertEqual(self.fields()["state"], "launching")

    def test_hung_open_is_bounded_and_retains_uncertain_launch(self):
        self.mark("open.block")
        self.run_lock("app-start", "session-a", expected=124)
        self.assertEqual(self.fields()["state"], "launching")
        self.assertFalse(self.gate.exists())
        self.run_lock("release", "session-a", "force")
        self.assert_free()

    def test_legacy_reservation_requires_deliberate_upgrade_before_stop(self):
        legacy = "owner=session-a\nrole=app\npid=4242\nacquiredAt=2026-01-01T00:00:00Z\nnote=test\n"
        self.lock.write_text(legacy)
        self.mark("app.pid", "4242")
        self.run_lock("app-stop", "session-a", expected=1)
        self.assertEqual(self.lock.read_text(), legacy)
        self.assertFalse((self.state / "quit.called").exists())
        self.run_lock("app-stop", "session-a", "force")
        self.assert_free()

    def test_legacy_owner_can_release_when_no_client_remains(self):
        self.lock.write_text("owner=session-a\nrole=app\npid=0\nacquiredAt=2026-01-01T00:00:00Z\nnote=\n")
        self.run_lock("release", "session-b", expected=1)
        self.run_lock("release", "session-a")
        self.assert_free()

    def test_only_force_recovers_a_demonstrably_dead_gate(self):
        finished = subprocess.Popen(["/usr/bin/true"])
        finished.wait(timeout=5)
        marker = self.gate / (str(finished.pid) + "." + "a" * 32)
        marker.mkdir(parents=True)
        self.run_lock("acquire", "session-a", "app", expected=1)
        self.assertTrue(marker.exists())
        self.run_lock("release", "session-a", "force")
        self.assert_free()
        self.run_lock("acquire", "session-a", "app")

    def test_live_old_gate_cannot_be_forced_or_evicted_by_age(self):
        marker = self.gate / (str(os.getpid()) + "." + "a" * 32)
        marker.mkdir(parents=True)
        os.utime(self.gate, (0, 0))
        self.run_lock("release", "session-a", "force", expected=1)
        self.assertTrue(marker.exists())

    def test_parallel_force_recovery_does_not_remove_a_successor_gate(self):
        finished = subprocess.Popen(["/usr/bin/true"])
        finished.wait(timeout=5)
        marker = self.gate / (str(finished.pid) + "." + "a" * 32)
        marker.mkdir(parents=True)
        barrier = self.state / "go"
        recoveries = [self.start("release", "session-" + str(index), "force", barrier=barrier)
                      for index in range(4)]
        barrier.touch()
        for recovery in recoveries:
            self.finish(recovery, 0)
        self.assert_free()

    def test_unverifiable_gate_cannot_be_forced(self):
        self.gate.mkdir()
        self.run_lock("release", "session-a", "force", expected=1)
        (self.gate / "unknown").mkdir()
        self.run_lock("release", "session-a", "force", expected=1)
        self.assertTrue((self.gate / "unknown").exists())

    def test_stubborn_process_keeps_reservation_and_allows_later_stop_retry(self):
        self.run_lock("acquire", "session-a", "app")
        token = self.fields()["token"]
        self.mark("app.pid", "4242")
        self.mark("stubborn")
        self.run_lock("app-stop", "session-a", expected=1)
        self.assertEqual(self.fields()["token"], token)
        self.assertEqual(self.fields()["state"], "stopping")
        self.run_lock("acquire", "session-b", "app", expected=1)
        self.assertFalse(self.gate.exists())
        (self.state / "stubborn").unlink()
        self.run_lock("app-stop", "session-a")
        self.assert_free()

    def test_active_stop_blocks_release_and_second_stop_even_without_process(self):
        self.run_lock("acquire", "session-a", "app")
        self.mark("quit.block")
        stopping = self.start("app-stop", "session-a")
        self.await_marker("quit.ready")
        self.assertEqual(self.fields()["state"], "stopping")
        self.run_lock("release", "session-a", "force", expected=1)
        self.run_lock("app-stop", "session-a", "force", expected=1)
        self.run_lock("acquire", "session-b", "app", expected=1)
        self.mark("quit.continue")
        self.finish(stopping, 0)
        self.assert_free()

    def test_reservation_update_is_atomic(self):
        self.run_lock("acquire", "session-a", "app")
        original = self.lock.read_bytes()
        (self.bin / "mv").symlink_to(self.stub)
        self.mark("move.block")
        stopping = self.start("app-stop", "session-a")
        self.await_marker("move.ready")
        self.assertEqual(self.lock.read_bytes(), original)
        temporary = list(self.root.glob(".control-session.lock.tmp.*"))
        self.assertEqual(len(temporary), 1)
        self.assertIn("state=stopping\n", temporary[0].read_text())
        self.mark("move.continue")
        self.finish(stopping, 0)
        self.assert_free()

    def test_probe_exit_releases_reservation_and_preserves_exit_status(self):
        self.mark("probe.exit", "7")
        output = self.state / "probe-output"
        self.run_lock("probe", "session-a", "synthetic-address", str(output), expected=7)
        self.assertTrue(output.exists())
        self.assert_free()
        self.assertNotIn("synthetic-address", (self.root / ".control-session.log").read_text())

    def test_probe_signal_stops_only_owned_child_and_releases(self):
        self.mark("probe.block")
        process = self.start("probe", "session-a", "synthetic-address", str(self.state / "probe-output"))
        self.await_marker("probe.ready")
        process.send_signal(signal.SIGTERM)
        self.finish(process, 143)
        self.assertFalse((self.state / "probe.pid").exists())
        self.assert_free()


if __name__ == "__main__":
    unittest.main(verbosity=2)
