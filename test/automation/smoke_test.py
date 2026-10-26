#!/usr/bin/env python3
"""NekkoOS automated QEMU smoke test suite.

Boots hdd.img headless, drives the OS through a smoke-suite via QEMU
monitor sendkey, and reports per-step PASS/FAIL from the serial log.

Usage:
    python3 test/automation/smoke_test.py

Requirements:
    - qemu-system-x86_64 (with KVM preferred)
    - OVMF_X64.fd in repo root
    - hdd.img already built (run ./build.sh first)
    - passwd with known user root / password nekko123
"""

import os
import re
import shutil
import socket
import subprocess
import sys
import time


# ============================================================================
# Config
# ============================================================================

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QEMU_BIN = "qemu-system-x86_64"
OVMF = os.path.join(REPO, "OVMF_X64.fd")
HDD = os.path.join(REPO, "hdd.img")
SERIAL_LOG = os.path.join(REPO, "test", "automation", "serial.log")
MON_SOCK = os.path.join(REPO, "test", "automation", "qemu-mon.sock")
LOG_ARCHIVE_DIR = os.path.join(REPO, "test", "automation", "logs")
PASSWD_USER = "root"
PASSWD_PASS = "nekko123"

QEMU_ARGS = [
    QEMU_BIN,
    "-accel", "kvm",
    "-machine", "q35,smm=on",
    "-global", "ICH9-LPC.disable_s3=1",
    "-global", "ICH9-LPC.disable_s4=1",
    "-smp", "2",
    "-device", "piix3-ide,id=ide",
    "-drive", f"file={HDD},format=raw,if=none,id=drv0",
    "-device", "ide-hd,bus=ide.0,drive=drv0",
    "-bios", OVMF,
    "-net", "nic", "-net", "user",
    "-m", "4G",
    "-fw_cfg", "name=opt/nekko_key,string=DUY_THANH_IS_THE_KING",
    "-serial", f"file:{SERIAL_LOG}",
    "-monitor", f"unix:{MON_SOCK},server,nowait",
]

KEYMAP = {
    " ": "spc", "-": "minus", ".": "dot", ",": "comma", "/": "slash",
    ";": "semicolon", "'": "apostrophe", "[": "bracket_left",
    "]": "bracket_right", "\\": "backslash", "=": "equal", "`": "grave_accent",
    "\n": "ret", "\t": "tab",
}


# ============================================================================
# Helpers
# ============================================================================

def die(msg):
    print(f"[FATAL] {msg}")
    archived = archive_serial_log("fatal")
    if archived:
        print(f"[*] archived serial log: {archived}")
    findings, log_lines = audit_log()
    print(f"[*] serial log has {log_lines} lines; tail:")
    snap = read_serial_log().splitlines()
    for line in snap[-40:]:
        print(f"    {line.strip()}")
    if findings:
        print(f"[*] LOG FINDINGS ({len(findings)}):")
        for lineno, label, line in findings[:20]:
            print(f"    L{lineno:<5} {label}: {line[:100]}")
    print("[*] read the archived log before concluding anything")
    cleanup()
    sys.exit(1)


def cleanup():
    subprocess.run(["pkill", "-f", "qemu-system-x86_64"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    for p in [MON_SOCK, MON_SOCK + ".lock"]:
        if os.path.exists(p):
            os.remove(p)
    lock = HDD + ".lock"
    if os.path.exists(lock):
        os.remove(lock)


def archive_serial_log(reason="run"):
    """Copy the live serial log aside *before* QEMU is torn down.

    The guest's UART buffer is only guaranteed to have reached the file while
    QEMU is still alive; killing it truncates the log at the last block
    boundary, which is how a failing run ends up losing the very lines that
    would explain the failure. Copy first, let cleanup() kill afterwards.
    """
    if not os.path.exists(SERIAL_LOG):
        return None
    os.makedirs(LOG_ARCHIVE_DIR, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = os.path.join(LOG_ARCHIVE_DIR, f"serial-{stamp}-{reason}.log")
    shutil.copyfile(SERIAL_LOG, dest)
    return dest


def read_serial_log():
    if not os.path.exists(SERIAL_LOG):
        return ""
    with open(SERIAL_LOG, "rb") as f:
        return f.read().decode(errors="replace")


# Lines worth surfacing even when every step reported PASS. A green run with
# one of these in the log is not green, it is a green run hiding a problem.
LOG_ERROR_SIGNATURES = [
    (r"PANIC", "kernel panic"),
    (r"EXCEPTION 0x", "CPU exception"),
    (r"Timeout waiting for .* handshake", "daemon handshake timeout"),
    (r"ACCESS DENIED", "access denied"),
    (r"OVERFLOW", "buffer overflow"),
    (r"overrun|segmentation fault", "memory fault"),
    (r"transfer aborted|vanish", "aborted transfer"),
    (r"\[WARN\]", "warning"),
]


def audit_log():
    """Scan the serial log for signs of trouble, pass or fail.

    Returns (findings, line_count) so the caller can report the log even when
    there is nothing wrong with it.
    """
    findings = []
    text = read_serial_log()
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped:
            continue
        for pattern, label in LOG_ERROR_SIGNATURES:
            if re.search(pattern, line):
                findings.append((lineno, label, stripped))
                break
    return findings, len(text.splitlines())


def require(path, what):
    if not os.path.exists(path):
        die(f"{what} not found: {path}")


def mon_send(cmds, per_cmd_delay=0.06):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(MON_SOCK)
    s.settimeout(0.3)
    time.sleep(0.15)
    try:
        s.recv(65536)
    except Exception:
        pass
    for c in cmds:
        try:
            s.recv(65536)
        except Exception:
            pass
        s.sendall((c + "\n").encode())
        time.sleep(per_cmd_delay)
    time.sleep(0.2)
    out = []
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            out.append(chunk.decode(errors="replace"))
    except Exception:
        pass
    s.close()
    return "".join(out)


def text_to_keys(text, per_cmd_delay=0.06):
    cmds = []
    for ch in text:
        if ch == "\n":
            cmds.append("sendkey ret")
            continue
        if ch.isupper():
            cmds.append(f"sendkey shift-{ch.lower()}")
            continue
        cmds.append(f"sendkey {KEYMAP.get(ch, ch)}")
    return cmds, per_cmd_delay


def type_text(text, per_cmd_delay=0.06):
    cmds, _ = text_to_keys(text, per_cmd_delay)
    mon_send(cmds, per_cmd_delay)


def tail(n=50):
    if not os.path.exists(SERIAL_LOG):
        return ""
    with open(SERIAL_LOG, "rb") as f:
        data = f.read()
    text = data.decode(errors="replace")
    lines = text.splitlines()
    return "\n".join(lines[-n:])


def serial_size():
    try:
        return os.path.getsize(SERIAL_LOG)
    except OSError:
        return 0


def tail_since_bytes(offset):
    with open(SERIAL_LOG, "rb") as f:
        f.seek(offset)
        return f.read().decode(errors="replace")


def wait_quiet(quiet_for=0.8, timeout=25):
    """Wait until the serial log stops producing bytes.

    There is no usable "prompt returned" event to wait for after a command.
    The shell echoes the keystrokes back onto the same serial line as the
    prompt it is already sitting on, so the line ends up as
    "root@nekkoOS# cd ..#10[!] Directory not found..." and the prompt the step
    wants to wait for is present before the command has done anything. Waiting
    for it returns on the echo, and the output written afterwards is never read
    - which is how a step reports PASS for a command the OS refused.

    An ls adds more lines below it, so even a change in line count is not a
    signal of completion. The only one that is: the log going quiet.
    """
    last = serial_size()
    since = time.time()
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.12)
        cur = serial_size()
        if cur != last:
            last = cur
            since = time.time()
        elif time.time() - since >= quiet_for:
            return True
    return False


def wait_for_echo(cmd, offset, timeout=15):
    """Wait until the typed command has been echoed back, after `offset`.

    The keystrokes arrive over the QEMU monitor one at a time, so the echo lags
    the send by a noticeable margin - and a slow daemon means the log can be
    quiet again before its output has been produced. Waiting for the echo
    first tells the harness the keystrokes landed, so the quiet window that
    follows measures "the command finished" rather than "nothing has happened
    yet".

    Only the slice after `offset` is searched. Without that bound the needle
    matches the echo of the same command typed at an earlier step, and the wait
    returns before this run has even started.

    Without this, a run reported "cat hello.txt reads back content" as FAIL
    while the archived log showed the content on the very next line: the
    snapshot was taken inside the gap between typing and the reply.
    """
    deadline = time.time() + timeout
    needle = cmd.replace(" ", "")
    while time.time() < deadline:
        window = tail_since_bytes(offset).replace("\r", "")
        if needle in window.replace(" ", ""):
            return True
        time.sleep(0.1)
    return False


def run_cmd(cmd, timeout=25, quiet_for=1.0):
    """Type one command and return (completed, everything the log produced).

    The baseline is a byte offset taken before the first keystroke, so the echo
    of the command and its output are both captured - but they are only
    inspected once the echo has landed and the log has then gone quiet, which
    is what makes the returned text trustworthy. A caller that checked a
    pattern as soon as it appeared would still race the output.
    """
    offset = serial_size()
    type_text(cmd + "\n")
    echoed = wait_for_echo(cmd, offset)
    ok = wait_quiet(timeout=timeout, quiet_for=quiet_for)
    return echoed and ok, tail_since_bytes(offset)


def wait_for(pattern, timeout=30, window=200):
    deadline = time.time() + timeout
    while time.time() < deadline:
        snap = tail(window)
        if re.search(pattern, snap):
            return True
        time.sleep(0.5)
    return False


# ============================================================================
# Test steps
# ============================================================================

class Result:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.steps = []

    def record(self, name, ok, detail=""):
        status = "PASS" if ok else "FAIL"
        self.steps.append((name, status, detail))
        if ok:
            self.passed += 1
        else:
            self.failed += 1
        symbol = "✓" if ok else "✗"
        print(f"  {symbol} [{status}] {name}" + (f" — {detail}" if detail else ""))


def step_boot_to_login(res):
    # The kernel gives a wedged daemon 30 seconds before it prints
    # "[!] Timeout waiting for X handshake!" and carries on, and boot itself
    # has been measured anywhere between 11 and 130 seconds. A 60-second cap
    # on this step therefore kills the run during the very wait whose result
    # we want to read, which turns an observable timeout into a blank failure
    # with nothing in the log to explain it.
    ok = wait_for(r"Username:", timeout=150, window=300)
    if ok:
        # The mouse daemon is still initialising the 8042 for a moment after the
        # prompt appears, and keystrokes that arrive meanwhile are discarded by
        # its drain. Boots used to be slow enough (the handshake bug, now fixed)
        # that the harness never typed this early.
        time.sleep(4)
    res.record("boot to login prompt", ok)
    return ok


def step_login(res):
    type_text(f"{PASSWD_USER}\n")
    if not wait_for(r"Password:", timeout=20, window=200):
        res.record("login password prompt after username", False, "no Password: prompt")
        return False
    type_text(f"{PASSWD_PASS}\n")
    ok = wait_for(r"root@nekkoOS#", timeout=25, window=400)
    res.record("login success (root shell prompt)", ok)
    return ok


def step_ls_empty_home(res):
    ok, snap = run_cmd("ls")
    no_panic = "PANIC" not in snap and "EXCEPTION" not in snap
    res.record("ls in empty home dir (ClearBuffer fix)", ok and no_panic)
    return ok and no_panic


def step_uppercase_ls(res):
    ok, snap = run_cmd("LS")
    # Case-insensitive dispatch: LS must hit the ls handler instead of RunCmd.
    # Handler produces a directory listing; RunCmd prints "not found" / error.
    has_listing = "DIR" in snap or "bytes" in snap
    not_error = "not found" not in snap and "Access Denied" not in snap
    res.record("uppercase LS delegates to ls (Pascal StrCmp_Pas)",
               ok and has_listing and not_error)
    return ok and has_listing and not_error


def step_cd_dotdot(res):
    ok, snap = run_cmd("cd ..")
    # The prompt comes back whether or not the directory changed, and it comes
    # back before the command has run at all, so neither the prompt nor the
    # line count proves anything. Only this text does.
    denied = "Directory not found" in snap or "Access Denied" in snap
    res.record("cd .. changes to parent directory", ok and not denied)
    return ok and not denied


def step_root_listing(res):
    ok, snap = run_cmd("ls")
    no_panic = "PANIC" not in snap and "EXCEPTION" not in snap
    # After a successful "cd .." from HOME the listing must show the volume
    # root's entries, not the home directory again.
    has_content = bool(re.search(r"\w+\s+\|", snap))
    res.record("root dir listing via FAT16 IPC", ok and no_panic and has_content)
    return ok and no_panic and has_content


def step_write_and_cat(res):
    ok, snap = run_cmd("write hello.txt")
    entered_content = "Enter content" in snap
    off = serial_size()
    type_text("automated smoke test\n.\n")
    ok2 = wait_quiet(timeout=25)
    write_snap = tail_since_bytes(off)
    # The shell echoes the bytes as they are typed, so the content shows up in
    # the log here whether or not it is ever written to disk. Only the
    # explicit success message proves the write happened.
    write_ok = "[+] File written successfully" in write_snap
    no_panic = "PANIC" not in write_snap and "EXCEPTION" not in write_snap
    res.record("write hello.txt", ok2 and entered_content and write_ok and no_panic)

    # The write's own success message only proves the daemon thinks it wrote.
    # A reply that reports success while the entry never lands is exactly the
    # failure "write then cat" is blind to, so list the directory and confirm
    # the file is actually there under its 8.3 name before reading it back.
    # This is also the only place the real on-disk name is observable: a name
    # that arrives mangled never shows up in a listing.
    ok_ls, ls_snap = run_cmd("ls")
    # The listing renders the 11-byte FAT name as base + "." + extension, so
    # "hello.txt" appears as HELLO.TXT, not "HELLO   TXT".
    listed = re.search(r"\bHELLO\.TXT\b", ls_snap) is not None
    listed_size = re.search(r"HELLO\.TXT.*?(\d+)\s*bytes", ls_snap)
    if listed and listed_size and int(listed_size.group(1)) == 0:
        # Present but zero length: the name is right, the content is not.
        listed = False
    res.record("hello.txt appears in the directory listing with its size",
               ok_ls and listed)

    # Read it back from a clean baseline. Without it, the echo of the content
    # above is still in the window and the cat step passes on text the file
    # may never contain.
    ok3, cat_snap = run_cmd("cat hello.txt")
    cat_ok = "automated smoke test" in cat_snap
    not_denied = "not found" not in cat_snap and "Access Denied" not in cat_snap
    no_panic2 = "PANIC" not in cat_snap and "EXCEPTION" not in cat_snap
    res.record("cat hello.txt reads back content",
               ok3 and cat_ok and not_denied and no_panic2)
    return (entered_content and write_ok and no_panic and ok_ls and listed
            and ok3 and cat_ok and not_denied and no_panic2)


def step_shutdown(res):
    type_text("shutdown\n")
    ok = wait_for(r"signing off", timeout=20, window=300)
    snap = tail(300)
    no_panic = "PANIC" not in snap and "EXCEPTION" not in snap
    res.record("graceful shutdown", ok or no_panic)
    return True


# ============================================================================
# Main
# ============================================================================

def main():
    print("=" * 60)
    print(" NekkoOS QEMU Automated Smoke Test")
    print("=" * 60)

    require(OVMF, "OVMF firmware")
    require(HDD, "disk image (hdd.img)")
    if not shutil.which(QEMU_BIN):
        die(f"{QEMU_BIN} not found in PATH")

    cleanup()

    res = Result()
    qemu_proc = None

    try:
        print("[*] Starting QEMU...")
        with open(SERIAL_LOG, "wb"):
            pass
        qemu_proc = subprocess.Popen(
            QEMU_ARGS,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        if not step_boot_to_login(res):
            die("OS did not reach login prompt within timeout")

        if not step_login(res):
            die("Login flow failed")

        step_ls_empty_home(res)
        step_uppercase_ls(res)
        step_cd_dotdot(res)
        step_root_listing(res)
        step_write_and_cat(res)
        step_shutdown(res)

    except KeyboardInterrupt:
        print("\n[INTERRUPTED]")
    finally:
        # Read and archive the log while QEMU is still alive. Terminating first
        # truncates it, which is how a 9/9 that hid a handshake timeout went
        # unnoticed.
        archived = None
        findings = []
        log_lines = 0
        try:
            time.sleep(1.0)
            findings, log_lines = audit_log()
            archived = archive_serial_log("final")
        except Exception as exc:
            print(f"[!] could not audit serial log: {exc}")
        if qemu_proc and qemu_proc.poll() is None:
            qemu_proc.terminate()
            try:
                qemu_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qemu_proc.kill()
        cleanup()

    print()
    print("=" * 60)
    print(" RESULTS")
    print("=" * 60)
    for name, status, detail in res.steps:
        marker = "PASS" if status == "PASS" else "FAIL"
        print(f"  [{marker}] {name}" + (f" — {detail}" if detail else ""))
    print("-" * 60)
    total = res.passed + res.failed
    print(f"  {res.passed}/{total} passed, {res.failed} failed")
    print("-" * 60)

    # Report the log whatever the verdict was. These lines are the evidence
    # for claims about the kernel that the PASS/FAIL list cannot see.
    print(f"  serial log: {SERIAL_LOG} ({log_lines} lines)")
    if archived:
        print(f"  archived to: {archived}")
    if findings:
        print(f"  LOG FINDINGS ({len(findings)}) — serial log has trouble the")
        print(f"  step results do not cover:")
        for lineno, label, line in findings[:20]:
            print(f"    L{lineno:<5} {label}: {line[:100]}")
        if len(findings) > 20:
            print(f"    ... and {len(findings) - 20} more, see the archived log")
    else:
        print("  LOG FINDINGS: none")

    print("=" * 60)

    sys.exit(0 if res.failed == 0 else 1)


if __name__ == "__main__":
    main()
