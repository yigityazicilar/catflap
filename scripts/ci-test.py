#!/usr/bin/env python3
"""Run the test suite under a time limit.

When its output goes to a pipe, as in CI, swift test prints nothing of a test run until that
run ends, so a run that stops making progress shows nothing until the job is cancelled. This
script gives swift test a terminal, so each line appears as it happens. Past the limit it
lists the tests that started and did not finish, the processes of the run that are still
alive and where their threads are, then ends them and fails. A run that leaves a process
behind fails too.

  CATFLAP_TEST_LIMIT   seconds allowed for one run of the suite (default 600)
  CATFLAP_TEST_REPEAT  times to run the suite, stopping at the first failure (default 1)

The tests are built first, outside the limit. Arguments are passed to swift test, for
example --filter.
"""
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time

# Programs of the toolchain and of this script. Anything else the run starts is a test
# process or a program under test.
TOOLING = {
    "swift", "swift-test", "swift-build", "swift-package", "swift-run", "swiftc", "swift-driver",
    "swift-frontend", "clang", "ld", "xcrun", "bash", "sh", "zsh", "env", "sleep", "ps", "sudo",
    "sample", "eu-stack", "gdb",
}
STARTED = re.compile(r"^\S+ +Test (?!run started)(.+) started\.\s*$")
ENDED = re.compile(r"^\S+ +Test (?!run with )(.+) (?:(?:passed|failed) after \d|skipped[.:])")
STACK_LINES = 1200


def say(text=""):
    print(text, flush=True)


def process_table():
    """pid -> (parent pid, start time, program name) for every process."""
    listing = subprocess.run(
        ["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "lstart=", "-o", "comm="],
        capture_output=True, text=True, errors="replace").stdout
    table = {}
    for line in listing.splitlines():
        fields = line.split(None, 7)
        if len(fields) == 8 and fields[0].isdigit():
            table[int(fields[0])] = (int(fields[1]), " ".join(fields[2:7]), os.path.basename(fields[7]))
    return table


class Family:
    """The processes one run started. A process stays a member after its parent has gone.

    Members are found by reading the process table twice a second, so a process that starts
    in the last half second before its parent goes can be missed."""

    def __init__(self, runner):
        self.runner = runner
        self.members = {}  # pid -> start time

    def alive(self):
        """pid -> (parent pid, start time, program name) of the members that still run."""
        table = process_table()
        family = {pid for pid, start in self.members.items() if pid in table and table[pid][1] == start}
        root = self.runner.pid if self.runner.poll() is None else None
        family.add(root)
        grew = True
        while grew:
            grew = False
            for pid, (parent, start, _) in table.items():
                if pid not in family and parent in family:
                    family.add(pid)
                    self.members[pid] = start
                    grew = True
        return {pid: table[pid] for pid in sorted(family - {root}) if pid in table}

    def stop(self):
        """End the runner and every member. They are frozen first, so that none of them
        starts another process while the rest are being found."""
        def signal_to(pid, sig):
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        if self.runner.poll() is None:
            signal_to(self.runner.pid, signal.SIGSTOP)
        frozen = set()
        while True:
            found = set(self.alive()) - frozen
            if not found:
                break
            for pid in found:
                signal_to(pid, signal.SIGSTOP)
            frozen |= found
        for pid in frozen:
            signal_to(pid, signal.SIGKILL)
        if self.runner.poll() is None:
            self.runner.kill()
        self.runner.wait()


class Tests:
    """Which tests have started and finished, read from the lines swift test prints."""

    def __init__(self):
        self.started = {}
        self.ended = {}

    def read(self, line):
        for pattern, counts in ((STARTED, self.started), (ENDED, self.ended)):
            match = pattern.match(line)
            if match:
                counts[match.group(1)] = counts.get(match.group(1), 0) + 1

    def report(self):
        if not self.started:
            say("  no test had started")
            return
        running = [name for name, count in self.started.items() if count > self.ended.get(name, 0)]
        say(f"  {sum(self.started.values())} started, {sum(self.ended.values())} finished; still running:")
        for name in running or ["(none: every test that started had finished)"]:
            say(f"    {name}")


def thread_stacks(pid, scratch):
    """The thread stacks of a process as lines, or None and the reason there are none."""
    sample_file = os.path.join(scratch, f"sample-{pid}.txt")
    if sys.platform == "darwin":
        commands = [["sample", str(pid), "2", "-mayDie", "-file", sample_file]]
    else:
        commands = [["eu-stack", "-p", str(pid)],
                    ["gdb", "-p", str(pid), "-batch", "-ex", "thread apply all bt 24"]]
    commands += [["sudo", "-n", *command] for command in commands]
    reasons = []
    for command in commands:
        tool = command[2] if command[0] == "sudo" else command[0]
        if not shutil.which(tool) or not shutil.which(command[0]):
            continue
        try:
            done = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                  errors="replace", timeout=90)
        except subprocess.TimeoutExpired:
            reasons.append(f"{tool} did not answer within 90 s")
            continue
        text = done.stdout
        if os.path.exists(sample_file):
            with open(sample_file, errors="replace") as file:
                text = file.read()
            os.remove(sample_file)
        said = (done.stderr + done.stdout).strip().splitlines()
        refused = [line.strip() for line in said if "not permitted" in line or "password is required" in line]
        if done.returncode == 0 and text.strip() and not refused:
            return trim(text), None
        reason = (refused[0] if refused else said[-1].strip() if said else f"{tool} printed nothing")[:110]
        if reason not in reasons:
            reasons.append(reason)
    return None, "; ".join(reasons) or "no stack tool on this machine (sample, eu-stack or gdb)"


def trim(text):
    """The stack lines of a tool's output, with Swift names readable."""
    lines = text.splitlines()
    if any(line.startswith("Call graph:") for line in lines):  # sample
        first = next(i for i, line in enumerate(lines) if line.startswith("Call graph:"))
        lines = lines[first:]
        for i, line in enumerate(lines):
            if line.startswith(("Total number in stack", "Binary Images:")):
                lines = lines[:i]
                break
    elif any(line.startswith("Thread ") for line in lines):  # gdb
        lines = [line for line in lines if line.startswith(("Thread ", "#"))]
    if shutil.which("swift"):
        named = subprocess.run(["swift", "demangle", "--simplified"], input="\n".join(lines),
                               capture_output=True, text=True, errors="replace")
        if named.returncode == 0 and named.stdout.strip():
            lines = named.stdout.splitlines()
    return lines


def report(limit, tests, family, scratch):
    say(f"\nerror: the test run did not finish within {limit} s")
    say("--- tests")
    tests.report()
    alive = family.alive()
    say("--- processes of this run still alive")
    for pid, (parent, start, program) in alive.items():
        say(f"  pid {pid}, parent {parent}, started {start}: {program}")
    ours = [(pid, entry[2]) for pid, entry in alive.items() if entry[2] not in TOOLING]
    for pid, program in ours[:3]:
        say(f"--- threads of {program} (pid {pid})")
        try:
            lines, reason = thread_stacks(pid, scratch)
        except Exception as error:  # the rest of the report matters more than one stack
            lines, reason = None, f"{type(error).__name__}: {error}"
        if lines is None:
            say(f"  none: {reason}")
            continue
        for line in lines[:STACK_LINES]:
            say(line[:200])
        if len(lines) > STACK_LINES:
            say(f"  ... {len(lines) - STACK_LINES} more lines")
    if len(ours) > 3:
        say(f"--- {len(ours) - 3} more processes not shown")


def run_once(arguments, limit, scratch):
    master, slave = pty.openpty()
    settings = termios.tcgetattr(slave)
    settings[1] &= ~termios.OPOST  # leave line endings as they are written
    termios.tcsetattr(slave, termios.TCSANOW, settings)
    runner = subprocess.Popen(["swift", "test", "--skip-build", *arguments], stdin=subprocess.DEVNULL,
                              stdout=slave, stderr=slave, env=dict(os.environ, TERM="dumb"))
    os.close(slave)
    family, tests = Family(runner), Tests()
    deadline = time.monotonic() + limit
    next_look, unread, open_output = 0.0, b"", True
    try:
        while True:
            chunk = b""
            if open_output and select.select([master], [], [], 0.25)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    chunk = b""
                open_output = bool(chunk)
            elif not open_output:
                time.sleep(0.25)
            if chunk:
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                *lines, unread = (unread + chunk).split(b"\n")
                for line in lines:
                    tests.read(line.decode("utf-8", "replace"))
            now = time.monotonic()
            if now >= next_look:
                family.alive()
                next_look = now + 0.5
            if not chunk and runner.poll() is not None:
                break
            if now >= deadline:
                report(limit, tests, family, scratch)
                return 124
        left = {}
        for _ in range(6):  # a process that is on its way out is not left behind
            left = {pid: entry for pid, entry in family.alive().items() if entry[2] not in TOOLING}
            if not left:
                break
            time.sleep(0.5)
        if left:
            say("\nerror: the tests left processes running:")
            for pid, (parent, start, program) in left.items():
                say(f"  pid {pid}, parent {parent}, started {start}: {program}")
            return runner.returncode or 1
        return runner.returncode
    finally:
        family.stop()
        os.close(master)


def main():
    limit = int(os.environ.get("CATFLAP_TEST_LIMIT", "600"))
    repeat = int(os.environ.get("CATFLAP_TEST_REPEAT", "1"))
    built = subprocess.run(["swift", "build", "--build-tests"])
    if built.returncode != 0:
        return built.returncode
    with tempfile.TemporaryDirectory(prefix="catflap-ci-test.") as scratch:
        for number in range(1, repeat + 1):
            if repeat > 1:
                say(f"== test run {number} of {repeat}")
            status = run_once(sys.argv[1:], limit, scratch)
            if status != 0:
                return status
    return 0


if __name__ == "__main__":
    sys.exit(main())
