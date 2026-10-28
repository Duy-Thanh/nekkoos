#!/usr/bin/env python3
"""ARM64 bring-up test: boot build/arm64/kernel.bin on QEMU virt and check the UART."""
import subprocess, sys, time

EXPECT = [
    "memtest: AllocMem/FreeMem OK",
    "arm64: memtest left no frames behind",
    "arm64: page reference counting OK",
    "arm64: SYSLOGON.EXE started",
    "[+] AUTHENTICATED! Welcome to the Multiverse!",
    "NEKKO OS USERLAND SHELL (RING 3)",
    "snoop: raw disk request refused by the kernel OK",
    "arm64 EL0: mapphys MMIO read OK",
    "[+] VBLK daemon (EL0) ready, sectors: ",
    "[+] FAT Server (Ring 3) Online & Listening for File Requests!",
    "arm64: ATA.EXE (virtio) and FAT16.EXE are up",
    "arm64: HELLO.TXT from disk: Hello from the FAT16 volume on virtio-blk",
    "arm64 EL0: DISKAPP.ELF loaded from the FAT16 disk",
    "arm64 EL0: hello from user mode",
    "arm64 EL0: getuid syscall OK",
    "arm64 EL0: user program exiting",
    "[!] 000000009200000d 0000000100000004 0000000040080000",   # crash.elf contained
    "arm64: heap alloc/free OK",
    "arm64: ipc send/receive OK",
    "Zero-Context Strands Engine",
    "arm64: address space map/switch OK, 0 pages leaked",
    "arm64: RAM 512 MiB,",
    "arm64: MMU on, kernel address space at",
    "NekkoOS arm64: early init",
    "arm64: 100 ms elapsed on the generic counter, core id 0",
    "arm64: bring-up milestone 1 reached",
    "arm64: scheduler started",
]
BAD = ["UNIMPLEMENTED", "FATAL"]

import threading
p = subprocess.Popen(
    ["./run_arm64.sh"], stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
buf = bytearray()

def reader():
    while True:
        chunk = p.stdout.read1(4096)
        if not chunk:
            break
        buf.extend(chunk)

threading.Thread(target=reader, daemon=True).start()

def wait_for(pattern, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        if re.search(pattern, buf.decode(errors="replace")):
            return True
        time.sleep(0.2)
    return False

def type_keys(text):
    # Keyboard = serial console; one byte at a time like a person typing.
    for ch in text.encode():
        p.stdin.write(bytes([ch]))
        p.stdin.flush()
        time.sleep(0.05)

import re
# Log in exactly as on x86 (same PASSWD), with a DEL (backspace) in the
# user name, then list the root directory from the ARM64 shell.
if wait_for(r"Username:"):
    type_keys("rooo\x7ft\r")
    if wait_for(r"Password:"):
        type_keys("nekko123\r")
        if wait_for(r"root@nekkoOS#"):
            type_keys("ls\r")
            wait_for(r"\.\. +\| d", 20)
time.sleep(2)
p.kill()
p.communicate()
out = buf.decode(errors="replace").replace("\r", "")
ok = True
for e in EXPECT:
    hit = e in out
    ok &= hit
    print(("[PASS] " if hit else "[FAIL] ") + e)
import re
m = re.search(r"timer interrupts in 1 s: (\d+)", out)
n = int(m.group(1)) if m else -1
hit = 200 <= n <= 260
ok &= hit
print(("[PASS] " if hit else "[FAIL] ") + f"timer ticks at ~250 Hz (got {n} in 1 s)")
# User-program output is interleaved with the A/B stream, so take the longest A/B run.
tail = out.split("scheduler demo", 1)[-1]
runs = re.findall(r"[AB]+", tail)
seq = max(runs, key=len) if runs else ""
switches = sum(1 for a, b in zip(seq, seq[1:]) if a != b)
hit = switches >= 20
ok &= hit
print(("[PASS] " if hit else "[FAIL] ") + "timer interrupt context-switches between two kernel threads (A/B alternate, " + str(switches) + " switches)")
m = re.search(r"BIG.BIN 64 KiB read OK in (\d+) ms", out)
ms = int(m.group(1)) if m else -1
hit = 0 <= ms <= 2000
ok &= hit
print(("[PASS] " if hit else "[FAIL] ") + f"64 KiB file read through FAT16.EXE -> ATA.EXE within 2 s (took {ms} ms)")
# The shell's `ls` lists the home directory through FAT16.EXE -> ATA.EXE.
hit = re.search(r"root@nekkoOS# ls\n\. +\| d[-rwx]{9} \|.*\n\.\. +\| d", out) is not None
ok &= hit
print(("[PASS] " if hit else "[FAIL] ") + "shell `ls` lists a directory from the FAT16 disk")
for b in BAD:
    if b in out:
        ok = False
        print("[FAIL] unexpected: " + b)
if not ok:
    print(out)
sys.exit(0 if ok else 1)
