#!/usr/bin/env python3
"""Run the test suite under a time limit.

When its output goes to a pipe, as in CI, swift test prints nothing of a test run until that
run ends, so a run that stops making progress shows nothing until the job is cancelled. This
script gives swift test a terminal, so each line appears as it happens. Past the limit it
lists the tests that started and did not finish, the processes of the run that are still
alive and where their threads are, then ends them and fails. A run that leaves a process
behind fails too, and so does one in which the test harness reports a fault of the program
under test: a line starting "harness-error:", which the harness writes where it cannot fail a
test itself.

Beside the run, a sampler process of its own writes the time, the load and the memory twice a
second. At the end, lines starting "stall-watch:" say whether the sampler itself stopped
(then the whole machine paused) and what the machine looked like around each long silence of
the test output. They are information only and never fail a run.

  CATFLAP_TEST_LIMIT     seconds allowed for one run of the suite (default 600)
  CATFLAP_TEST_REPEAT    times to run the suite, stopping at the first failure (default 1)
  CATFLAP_STALL_SILENCE  seconds without test output that count as a silence (default 10)

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
FAULT = re.compile(r"harness-error: (.*?)\s*$")
STACK_LINES = 1200
SILENCE = float(os.environ.get("CATFLAP_STALL_SILENCE", "10"))
SAMPLER_GAP = 2.0  # the sampler writes every 0.5 s; a longer gap means it was not running


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
    """Which tests have started and finished, and the faults the test harness reported,
    read from the lines swift test prints."""

    def __init__(self):
        self.started = {}
        self.ended = {}
        self.faults = []

    def read(self, line):
        for pattern, counts in ((STARTED, self.started), (ENDED, self.ended)):
            match = pattern.match(line)
            if match:
                counts[match.group(1)] = counts.get(match.group(1), 0) + 1
        fault = FAULT.search(line)
        if fault:
            self.faults.append(fault.group(1))

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


def memory_now():
    """Free and compressed memory and swap use in one short line, or "" where not known."""
    try:
        if sys.platform == "darwin":
            text = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
            size = int(re.search(r"page size of (\d+) bytes", text).group(1))
            pages = {m.group(1): int(m.group(2)) for m in re.finditer(r"^(.+?):\s+(\d+)\.?$", text, re.M)}
            mib = lambda key: pages.get(key, 0) * size // 1048576
            return (f"free={mib('Pages free')}MiB compressed={mib('Pages occupied by compressor')}MiB "
                    f"swapins={pages.get('Swapins', 0)} swapouts={pages.get('Swapouts', 0)}")
        with open("/proc/meminfo") as file:
            info = {line.split(":")[0]: int(line.split()[1]) for line in file if len(line.split()) > 1}
        used = (info.get("SwapTotal", 0) - info.get("SwapFree", 0)) // 1024
        return f"available={info.get('MemAvailable', 0) // 1024}MiB swapused={used}MiB"
    except Exception:
        return ""


def sample(path, parent):
    """The stall sampler, run as a process of its own: a line every half second with the time
    and the load, with the memory every two seconds. A gap in its lines means that it was not
    running either, so the whole machine paused, not only the test process. It ends by itself
    once the wrapper that started it is gone, however that ended."""
    with open(path, "a", buffering=1) as out:
        memory_at = 0.0
        while os.getppid() == parent:
            now = time.time()
            memory = ""
            if now - memory_at >= 2:
                memory, memory_at = memory_now(), now
            load = " ".join(f"{value:.2f}" for value in os.getloadavg())
            out.write(f"{now:.3f} {load} {memory}\n")
            time.sleep(0.5)


def stall_report(path, silences):
    """What the sampler saw: its own longest gaps, and the machine at the start and end of
    each long silence of the test output."""
    try:
        with open(path) as file:
            rows = [line.split(None, 4) for line in file if len(line.split()) >= 4]
    except OSError:
        return
    if not rows:
        return
    times = [float(row[0]) for row in rows]
    stamp = lambda t: time.strftime("%H:%M:%S", time.gmtime(t)) + f".{int(t % 1 * 10)}"
    def around(t):
        before = [row for row in rows if float(row[0]) <= t] or rows[:1]
        memory = next((row[4].strip() for row in reversed(before) if len(row) > 4 and row[4].strip()), "")
        return f"load {' '.join(before[-1][1:4])}" + (f", {memory}" if memory else "")
    gaps = sorted(((later - earlier, earlier) for earlier, later in zip(times, times[1:])), reverse=True)
    longest = gaps[0] if gaps else (0.0, times[0])
    say(f"stall-watch: the sampler wrote {len(times)} lines; its longest gap was {longest[0]:.1f} s, "
        f"at {stamp(longest[1])} UTC")
    for gap, at in gaps[:3]:
        if gap >= SAMPLER_GAP:
            say(f"stall-watch: the sampler stopped too, for {gap:.1f} s from {stamp(at)} UTC: the whole "
                f"machine paused; before it {around(at)}")
    for start, length in sorted(silences, key=lambda s: -s[1])[:5]:
        say(f"stall-watch: no test output for {length:.1f} s from {stamp(start)} UTC; at its start "
            f"{around(start)}; at its end {around(start + length)}")
    say(f"stall-watch: at the end, {around(times[-1])}")


def stop_on_signal(number, frame):
    raise SystemExit(128 + number)


def run_once(arguments, limit, scratch):
    samples = os.path.join(scratch, "stall-samples.txt")
    silences, quiet_since = [], time.time()
    sampler = family = master = None
    # SIGTERM or SIGHUP ends the run through the same cleanup as any other end: the tests,
    # what they started and the sampler are stopped, and the wrapper exits 128 + the signal.
    previous = {number: signal.signal(number, stop_on_signal) for number in (signal.SIGTERM, signal.SIGHUP)}
    try:
        sampler = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--stall-sampler", samples,
                                    str(os.getpid())],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
                heard = time.time()
                if heard - quiet_since >= SILENCE:
                    silences.append((quiet_since, heard - quiet_since))
                quiet_since = heard
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
        if unread:
            tests.read(unread.decode("utf-8", "replace"))
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
        if tests.faults:
            say("\nerror: the test harness reported a fault of the program under test:")
            for fault in tests.faults:
                say(f"  {fault}")
        if left or tests.faults:
            return runner.returncode or 1
        return runner.returncode
    finally:
        for number in previous:
            signal.signal(number, signal.SIG_IGN)  # a second signal must not cut the cleanup short
        if family:
            family.stop()
        if master is not None:
            os.close(master)
        if sampler:
            sampler.terminate()
            try:
                sampler.wait(5)
            except subprocess.TimeoutExpired:
                sampler.kill()
                sampler.wait()
        for number, handler in previous.items():
            signal.signal(number, handler)
        stall_report(samples, silences)
        try:
            os.remove(samples)
        except OSError:
            pass


def main():
    if sys.argv[1:2] == ["--stall-sampler"]:
        sample(sys.argv[2], int(sys.argv[3]))
        return 0
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
