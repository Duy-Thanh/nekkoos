#!/usr/bin/env python3
"""ARM64 counterpart of extra_test.py + the file steps of smoke_test.py.

Boots build/arm64/kernel.bin, logs in over the serial console and exercises
the kernel builtins, mkdir/rmdir, write/cat, sudo (right and wrong password),
reboot and shutdown. Everything goes through the same apps and daemons as on
x86 (SHELL.EXE, FAT16.EXE, the virtio disk daemon as ATA.EXE)."""
import re
import subprocess
import sys
import threading
import time

PASSWORD = "nekko123"


class Vm:
    def __init__(self):
        self.p = subprocess.Popen(["./run_arm64.sh"], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.buf = bytearray()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            chunk = self.p.stdout.read1(4096)
            if not chunk:
                break
            self.buf.extend(chunk)

    def text(self, start=0):
        return self.buf[start:].decode(errors="replace").replace("\r", "")

    def wait_for(self, pattern, timeout=40, start=0):
        end = time.time() + timeout
        while time.time() < end:
            if re.search(pattern, self.text(start)):
                return True
            time.sleep(0.2)
        return False

    def wait_quiet(self, quiet=1.5, timeout=30):
        end = time.time() + timeout
        last, since = len(self.buf), time.time()
        while time.time() < end:
            time.sleep(0.2)
            if len(self.buf) != last:
                last, since = len(self.buf), time.time()
            elif time.time() - since >= quiet:
                return True
        return False

    def type(self, s):
        for ch in s.encode():
            self.p.stdin.write(bytes([ch]))
            self.p.stdin.flush()
            time.sleep(0.04)

    def cmd(self, line, quiet=1.5):
        start = len(self.buf)
        self.type(line + "\r")
        self.wait_quiet(quiet)
        return self.text(start)


class Result:
    def __init__(self):
        self.passed = self.failed = 0

    def record(self, name, ok, detail=""):
        if ok:
            self.passed += 1
        else:
            self.failed += 1
        print(("[PASS] " if ok else "[FAIL] ") + name + ("" if ok else f"  -- {detail}"))


def main():
    res = Result()
    vm = Vm()
    try:
        ok = vm.wait_for(r"Username:", 60)
        res.record("boot to login prompt", ok)
        if not ok:
            return res
        vm.type("root\r")
        vm.wait_for(r"Password:", 20)
        vm.type(PASSWORD + "\r")
        ok = vm.wait_for(r"root@nekkoOS#", 30)
        res.record("login as root", ok)
        if not ok:
            return res
        vm.wait_quiet(2)

        def step(line, pattern, name, quiet=1.5):
            out = vm.cmd(line, quiet)
            hit = re.search(pattern, out) is not None
            bad = re.search(r"FATAL exception|UNIMPLEMENTED", out)
            res.record(name, hit and not bad, f"got: {out[-200:]!r}")
            return out

        step("uname", r"NekkoOS Microkernel aarch64", "uname names this architecture")
        step("help", r"Commands: clear, help, mem", "help")
        step("mem", r"Free memory:.*MB", "mem")
        step("uptime", r"System Uptime:.*seconds", "uptime")
        step("date", r"\d", "date prints something numeric")
        step("pci", r"PCI", "pci answers without crashing")
        step("bogus-command", r"Unknown Command|not found", "unknown command")
        step("mkdir extradir", r"root@nekkoOS#", "mkdir via daemon")
        step("ls", r"(?i)extradir", "mkdir result visible in ls")
        step("rmdir extradir", r"root@nekkoOS#", "rmdir via daemon")
        step("ls", r"^(?![\s\S]*(?i:extradir))", "rmdir result: gone from ls")

        start = len(vm.buf)
        vm.type("write hello.txt\r")
        vm.wait_quiet(1.5)
        vm.type("written on arm64\r.\r")
        vm.wait_quiet(2)
        res.record("write a file", re.search(r"(?i)written successfully", vm.text(start)) is not None,
                   repr(vm.text(start)[-200:]))
        step("cat hello.txt", r"written on arm64", "cat reads it back")

        def sudo(line, password, pattern, name):
            start = len(vm.buf)
            vm.type(line + "\r")
            if not vm.wait_for(r"\[sudo\] Password:", 20, start):
                res.record(name, False, "no [sudo] Password: prompt")
                return
            vm.type(password + "\r")
            vm.wait_quiet(2, 30)
            res.record(name, re.search(pattern, vm.text(start)) is not None,
                       repr(vm.text(start)[-200:]))

        sudo("sudo mkdir sdir", PASSWORD, r"Directory Created Successfully", "sudo mkdir")
        sudo("sudo ls", PASSWORD, r"(?i)sdir", "sudo ls lists the new directory")
        sudo("sudo rmdir sdir", PASSWORD, r"obliterated", "sudo rmdir")
        sudo("sudo ls", "wrongpassword", r"Sorry, try again", "sudo rejects a wrong password")

        before = vm.text().count("Username:")
        vm.type("reboot\r")
        rebooted = vm.wait_for(r"(Username:[\s\S]*){%d}" % (before + 1), 120)
        res.record("reboot restarts the machine (PSCI)", rebooted)
        if rebooted:
            vm.type("root\r")
            vm.wait_for(r"Password:", 20, len(vm.buf) - 200)
            vm.type(PASSWORD + "\r")
            vm.wait_quiet(3)
            vm.type("shutdown\r")
            end = time.time() + 90
            while time.time() < end and vm.p.poll() is None:
                time.sleep(1)
            res.record("shutdown powers the machine off (QEMU exits)", vm.p.poll() is not None)
    finally:
        if vm.p.poll() is None:
            vm.p.kill()
        with open("test/automation/logs/arm64-extra.log", "w") as f:
            f.write(vm.text())
    return res


if __name__ == "__main__":
    r = main()
    print(f"  {r.passed}/{r.passed + r.failed} passed")
    sys.exit(0 if r.failed == 0 else 1)
