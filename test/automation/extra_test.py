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
        # top.exe reads every process record with GetProcessInfo; a wrapper bug
        # made the kernel write the 55-byte record over an 8-byte pointer on
        # the app's stack, and top died with a GPF on its first return.
        ok, snap = st.run_cmd("run top.exe", timeout=20, quiet_for=3)
        clean = snap.replace("\r", "")
        res.record("run top.exe shows the process table",
                   "NEKKOTOP" in clean and "SHELL.EXE" in clean
                   and "GENERAL PROTECTION" not in clean and "EXCEPTION" not in clean,
                   clean[-200:])
        st.type_text("q")
        st.wait_quiet(timeout=10, quiet_for=1.5)
        # stresstest.exe (8.3 alias STRESS~1.EXE) hammers IPC, memory and the
        # shared-buffer syscall; it used to page-fault within a second because
        # App_CreateSharedBuffer handed the vDSO stub a garbage out-pointer.
        offset = st.serial_size()
        st.type_text("run stress~1.exe\n")
        time.sleep(8)
        st.type_text("q")
        st.wait_quiet(timeout=15, quiet_for=2)
        out = st.tail_since_bytes(offset).replace("\r", "")
        res.record("stresstest runs 8 s without faulting",
                   "Comprehensive OS Stability Test" in out and "SHM=" in out
                   and "FAULT IN RING 3" not in out and "EXCEPTION" not in out,
                   out[-200:])
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

        # The ACPI daemon (acpi_app.pas) is the only thing that can really reset
        # or power off the machine, so prove both by effect, not by log text.
        before = st.read_serial_log().count("Username:")
        st.type_text("reboot\n")
        deadline = time.time() + 240
        rebooted = False
        while time.time() < deadline:
            if st.read_serial_log().count("Username:") > before:
                rebooted = True
                break
            time.sleep(1)
        res.record("reboot restarts the machine (ACPI daemon)", rebooted)

        if rebooted:
            st.step_login(res)
            st.type_text("shutdown\n")
            off = False
            deadline = time.time() + 90
            while time.time() < deadline:
                if qemu_proc.poll() is not None:
                    off = True
                    break
                time.sleep(1)
            res.record("shutdown powers the machine off (QEMU exits)", off)
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
