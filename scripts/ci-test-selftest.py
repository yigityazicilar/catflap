#!/usr/bin/env python3
"""Exercise wrapper verdicts and cleanup without building Swift."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

# Importing the wrapper must not leave an untracked bytecode file in CI snapshots.
sys.dont_write_bytecode = True
WRAPPER = Path(os.environ.get("CATFLAP_SELFTEST_WRAPPER", Path(__file__).with_name("ci-test.py")))


def load_wrapper():
    spec = importlib.util.spec_from_file_location("ci_test", WRAPPER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


if sys.argv[1:2] == ["--worker"]:
    wrapper = load_wrapper()
    # Stack collectors are not under test and can take minutes on a refusing host.
    wrapper.thread_stacks = lambda *args: (None, "disabled in wrapper self-test")
    sys.exit(wrapper.run_once([], float(os.environ["SELFTEST_LIMIT"]), os.environ["SELFTEST_DIR"]))


class WrapperTests(unittest.TestCase):
    def run_case(self, mode, expected, message=None, terminate=False):
        with tempfile.TemporaryDirectory(prefix="ci-wrapper-selftest.") as directory:
            root = Path(directory)
            swift = root / "swift"
            swift.write_text("#!" + sys.executable + "\n" + '''import os, signal, subprocess, sys, time
from pathlib import Path
root = Path(os.environ["SELFTEST_DIR"])
mode = os.environ["SELFTEST_MODE"]
(root / "runner").write_text(str(os.getpid()))
if mode == "failure": sys.exit(23)
if mode == "fault":
    print("harness-error: synthetic fault", flush=True)
    sys.exit(0)
if mode == "clean": sys.exit(0)
if mode == "orphan":
    # The intermediate parent exits before the wrapper's next process snapshot.
    pid = subprocess.check_output([sys.executable, "-c", "import subprocess, sys; p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], stdout=subprocess.DEVNULL); print(p.pid)"], text=True)
    (root / "helper").write_text(pid)
elif mode == "sleep":
    helper = subprocess.Popen(["sleep", "60"])
    (root / "helper").write_text(str(helper.pid))
else:
    (root / "ready").touch()
    time.sleep(60)
''')
            swift.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                       SELFTEST_DIR=directory, SELFTEST_MODE=mode, SELFTEST_LIMIT="1")
            start = time.monotonic()
            child = subprocess.Popen([sys.executable, __file__, "--worker"], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                if terminate:
                    deadline = time.monotonic() + 10
                    while not (root / "ready").exists() and child.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.02)
                    self.assertTrue((root / "ready").exists(), "runner did not start")
                    child.send_signal(signal.SIGTERM)
                output, _ = child.communicate(timeout=20)
                self.assertEqual(child.returncode, expected, output)
                if message:
                    self.assertIn(message, output)
                self.assertLess(time.monotonic() - start, 15, output)
                # The runner has its own session; even an unobserved orphan retains it.
                pid = int((root / "runner").read_text())
                listing = subprocess.check_output(["ps", "-A", "-o", "pgid=" if sys.platform == "darwin" else "sid=", "-o", "stat="], text=True)
                live = [line for line in listing.splitlines()
                        if line.split()[0] == str(pid) and not line.split()[1].startswith("Z")]
                self.assertEqual(live, [], "wrapper left live session members")
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate()
                if (root / "helper").exists():
                    try:
                        os.kill(int((root / "helper").read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                if (root / "runner").exists():
                    try:
                        os.killpg(int((root / "runner").read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_clean(self): self.run_case("clean", 0)
    def test_failure(self): self.run_case("failure", 23)
    def test_fault(self): self.run_case("fault", 1, "harness reported a fault")
    def test_orphan(self): self.run_case("orphan", 1, "left processes running")
    def test_sleep(self): self.run_case("sleep", 1, "left processes running")
    def test_timeout(self): self.run_case("timeout", 124, "did not finish within")
    def test_sigterm(self): self.run_case("signal", 143, terminate=True)


if __name__ == "__main__":
    unittest.main()
