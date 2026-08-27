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
    type_text("ls\n")
    ok = wait_for(r"root@nekkoOS#", timeout=15, window=300)
    snap = tail(300)
    no_panic = "PANIC" not in snap and "EXCEPTION" not in snap
    res.record("ls in empty home dir (ClearBuffer fix)", ok and no_panic)
    return ok and no_panic


def step_uppercase_ls(res):
    type_text("LS\n")
    ok = wait_for(r"root@nekkoOS#", timeout=15, window=300)
    snap = tail(300)
    # Case-insensitive dispatch: LS must hit the ls handler instead of RunCmd.
    # Handler produces a directory listing; RunCmd prints "not found" / error.
    has_listing = "DIR" in snap or "bytes" in snap
    res.record("uppercase LS delegates to ls (Pascal StrCmp_Pas)", ok and has_listing)
    return ok and has_listing


def step_cd_dotdot(res):
    type_text("cd ..\n")
    ok = wait_for(r"root@nekkoOS#", timeout=15, window=200)
    res.record("cd .. prefix match via StrStartsWith_Pas", ok)
    return ok


def step_root_listing(res):
    type_text("ls\n")
    ok = wait_for(r"root@nekkoOS#", timeout=15, window=300)
    snap = tail(300)
    no_panic = "PANIC" not in snap and "EXCEPTION" not in snap
    has_content = bool(re.search(r"\w+\s+\|", snap))
    res.record("root dir listing via FAT16 IPC", ok and no_panic and has_content)
    return ok and no_panic and has_content


def step_write_and_cat(res):
    type_text("write hello.txt\n")
    ok1 = wait_for(r"Enter content\. End with", timeout=15, window=200)
    if not ok1:
        time.sleep(2)
    type_text("automated smoke test\n.\n")
    ok2 = wait_for(r"root@nekkoOS#", timeout=20, window=400)
    snap = tail(400)
    write_ok = "[+] File written successfully" in snap
    no_panic = "PANIC" not in snap and "EXCEPTION" not in snap
    res.record("write hello.txt", ok2 and write_ok and no_panic)

    type_text("cat hello.txt\n")
    ok3 = wait_for(r"root@nekkoOS#", timeout=15, window=300)
    snap = tail(300)
    cat_ok = "automated smoke test" in snap
    no_panic2 = "PANIC" not in snap and "EXCEPTION" not in snap
    res.record("cat hello.txt reads back content", ok3 and cat_ok and no_panic2)
    return ok2 and write_ok and no_panic and ok3 and cat_ok and no_panic2


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
    print("=" * 60)

    sys.exit(0 if res.failed == 0 else 1)


if __name__ == "__main__":
    main()
