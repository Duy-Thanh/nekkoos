#!/usr/bin/env python3
"""
Builtin-command test for NekkoOS: the kernel shell (syscall 88) and friends.

smoke_test.py covers boot/login/ls/write/cat/shutdown. It does NOT run any of
the commands the kernel itself answers, so a regression in InternalShell, PCI,
RTC or PMM statistics would pass 10/10. This script boots, logs in, and runs
each builtin, checking for the text that command prints.

Reuses the QEMU wiring and helpers of smoke_test.py; run it the same way:
    python3 test/automation/extra_test.py
"""
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke_test as st  # noqa: E402


def step_builtin(res, cmd, pattern, name):
    ok, snap = st.run_cmd(cmd)
    clean = snap.replace("\r", "")
    hit = re.search(pattern, clean) is not None
    bad = "PANIC" in clean or "EXCEPTION" in clean
    res.record(name, ok and hit and not bad,
               "" if (hit and not bad) else f"expected /{pattern}/ in: {clean[-160:]!r}")
    return ok and hit and not bad


def step_sudo(res, cmd, password, pattern, name):
    """Type `cmd`, answer the [sudo] Password prompt, check the reply."""
    offset = st.serial_size()
    st.type_text(cmd + "\n")
    if not st.wait_for(r"\[sudo\] Password:", timeout=20, window=300):
        res.record(name, False, "no [sudo] Password: prompt")
        return False
    st.type_text(password + "\n")
    st.wait_quiet(timeout=25, quiet_for=1.5)
    out = st.tail_since_bytes(offset).replace("\r", "")
    hit = re.search(pattern, out) is not None
    res.record(name, hit, "" if hit else f"expected /{pattern}/ in: {out[-200:]!r}")
    return hit


def main():
    print("=" * 60)
    print(" NekkoOS builtin-command test")
    print("=" * 60)

    st.require(st.OVMF, "OVMF firmware")
    st.require(st.HDD, "disk image (hdd.img)")
    st.cleanup()

    res = st.Result()
    qemu_proc = None
    try:
        print("[*] Starting QEMU...")
        with open(st.SERIAL_LOG, "wb"):
            pass
        qemu_proc = subprocess.Popen(st.QEMU_ARGS, stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        if not st.step_boot_to_login(res):
            st.die("OS did not reach login prompt within timeout")
        if not st.step_login(res):
            st.die("Login flow failed")

        step_builtin(res, "uname", r"NekkoOS Microkernel x86_64", "uname")
        step_builtin(res, "help", r"Commands: clear, help, mem", "help")
        step_builtin(res, "mem", r"Free memory:.*MB", "mem")
        step_builtin(res, "uptime", r"System Uptime:.*seconds", "uptime")
        step_builtin(res, "date", r"\d", "date prints something numeric")
        step_builtin(res, "pci", r"Total PCI devices found", "pci scan")
        step_builtin(res, "bogus-command", r"Unknown Command|not found", "unknown command")
        step_builtin(res, "mkdir extradir", r"root@nekkoOS#", "mkdir via daemon")
        step_builtin(res, "ls", r"(?i)extradir", "mkdir result visible in ls")
        step_builtin(res, "rmdir extradir", r"root@nekkoOS#", "rmdir via daemon")
        step_sudo(res, "sudo mkdir sdir", st.PASSWD_PASS,
                  r"Directory Created Successfully", "sudo mkdir (kernel relays to FAT16 daemon)")
        step_sudo(res, "sudo ls", st.PASSWD_PASS, r"(?i)sdir", "sudo ls lists the new directory")
        step_sudo(res, "sudo rmdir sdir", st.PASSWD_PASS,
                  r"obliterated", "sudo rmdir")
        step_sudo(res, "sudo ls", "wrongpassword", r"Sorry, try again",
                  "sudo rejects a wrong password")
        st.step_shutdown(res)
    except KeyboardInterrupt:
        print("\n[INTERRUPTED]")
    finally:
        archived = None
        try:
            time.sleep(1.0)
            archived = st.archive_serial_log("extra")
        except Exception as exc:
            print(f"[!] could not archive serial log: {exc}")
        if qemu_proc and qemu_proc.poll() is None:
            qemu_proc.terminate()
            try:
                qemu_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qemu_proc.kill()
        st.cleanup()

    print()
    print("=" * 60)
    total = res.passed + res.failed
    print(f"  {res.passed}/{total} passed, {res.failed} failed")
    if archived:
        print(f"  archived to: {archived}")
    print("=" * 60)
    sys.exit(0 if res.failed == 0 else 1)


if __name__ == "__main__":
    main()
