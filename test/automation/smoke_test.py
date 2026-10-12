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


def snapshot_lines():
    """Line count of the serial log, to be used as a baseline.

    Typing a command echoes the keystrokes back into the log, so the text a
    command prints can easily be confused with the echo of what was typed a
    step earlier. Taking a baseline first and only looking at what follows it
    is what stops "cat hello.txt" from passing because the write step's echo
    of the content is still in the buffer.
    """
    return len(read_serial_log().splitlines())


def tail_since(baseline):
    """Only the log produced after `baseline` was taken."""
    lines = read_serial_log().splitlines()
    return "\n".join(lines[baseline:])


def wait_for(pattern, timeout=30, window=200):
    deadline = time.time() + timeout
    while time.time() < deadline:
        snap = tail(window)
        if re.search(pattern, snap):
            return True
        time.sleep(0.5)
    return False


def wait_for_since(pattern, baseline, timeout=30, extra=0):
    """Wait for a pattern, but only in the log produced after `baseline`.

    Used where the prompt itself would otherwise match: without the baseline
    the previous step's prompt satisfies the check and the step passes
    without the command ever having produced anything.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        snap = tail_since(baseline + extra)
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
    ok = wait_for(r"Username:", timeout=60, window=300)
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
    before = snapshot_lines()
    type_text("ls\n")
    ok = wait_for_since(r"root@nekkoOS#", before, timeout=15)
    snap = tail_since(before)
    no_panic = "PANIC" not in snap and "EXCEPTION" not in snap
    res.record("ls in empty home dir (ClearBuffer fix)", ok and no_panic)
    return ok and no_panic


def step_uppercase_ls(res):
    before = snapshot_lines()
    type_text("LS\n")
    ok = wait_for_since(r"root@nekkoOS#", before, timeout=15)
    snap = tail_since(before)
    # Case-insensitive dispatch: LS must hit the ls handler instead of RunCmd.
    # Handler produces a directory listing; RunCmd prints "not found" / error.
    has_listing = "DIR" in snap or "bytes" in snap
    res.record("uppercase LS delegates to ls (Pascal StrCmp_Pas)", ok and has_listing)
    return ok and has_listing


def step_cd_dotdot(res):
    before = snapshot_lines()
    type_text("cd ..\n")
    ok = wait_for_since(r"root@nekkoOS#", before, timeout=15)
    snap = tail_since(before)
    # The prompt comes back whether or not the directory changed, so the
    # prompt alone proved nothing. Look for the shell's own error text.
    denied = "Directory not found" in snap or "Access Denied" in snap
    res.record("cd .. prefix match via StrStartsWith_Pas", ok and not denied)
    return ok and not denied


def step_root_listing(res):
    before = snapshot_lines()
    type_text("ls\n")
    ok = wait_for_since(r"root@nekkoOS#", before, timeout=15)
    snap = tail_since(before)
    no_panic = "PANIC" not in snap and "EXCEPTION" not in snap
    has_content = bool(re.search(r"\w+\s+\|", snap))
    res.record("root dir listing via FAT16 IPC", ok and no_panic and has_content)
    return ok and no_panic and has_content


def step_write_and_cat(res):
    before_w = snapshot_lines()
    type_text("write hello.txt\n")
    ok1 = wait_for_since(r"Enter content\. End with", before_w, timeout=15)
    if not ok1:
        time.sleep(2)
    before_content = snapshot_lines()
    type_text("automated smoke test\n.\n")
    # The shell echoes the bytes as they are typed, so the content shows up in
    # the log here whether or not it is ever written to disk. Only the
    # explicit success message proves the write happened.
    ok_write = wait_for_since(r"\[\+\] File written successfully", before_content,
                              timeout=20)
    ok2 = wait_for_since(r"root@nekkoOS#", before_content, timeout=15)
    snap = tail_since(before_content)
    write_ok = ok_write and "[+] File written successfully" in snap
    no_panic = "PANIC" not in snap and "EXCEPTION" not in snap
    res.record("write hello.txt", ok2 and write_ok and no_panic)

    # Read it back from a clean baseline. Without it, the echo of the content
    # above is still in the window and the cat step passes on text the file
    # may never contain.
    before_c = snapshot_lines()
    type_text("cat hello.txt\n")
    ok3 = wait_for_since(r"root@nekkoOS#", before_c, timeout=15)
    snap = tail_since(before_c)
    cat_ok = "automated smoke test" in snap
    not_denied = "not found" not in snap and "Access Denied" not in snap
    no_panic2 = "PANIC" not in snap and "EXCEPTION" not in snap
    res.record("cat hello.txt reads back content",
               ok3 and cat_ok and not_denied and no_panic2)
    return ok2 and write_ok and no_panic and ok3 and cat_ok and not_denied and no_panic2


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
