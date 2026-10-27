#!/usr/bin/env python3
"""ARM64 bring-up test: boot build/arm64/kernel.bin on QEMU virt and check the UART."""
import subprocess, sys, time

EXPECT = [
    "arm64: address space map/switch OK, 0 pages leaked",
    "arm64: RAM 512 MiB,",
    "arm64: MMU on, kernel address space at",
    "NekkoOS arm64: early init",
    "arm64: 100 ms elapsed on the generic counter, core id 0",
    "arm64: bring-up milestone 1 reached",
    "arm64: scheduler started",
]
BAD = ["UNIMPLEMENTED", "FATAL"]

p = subprocess.Popen(
    ["qemu-system-aarch64", "-machine", "virt", "-cpu", "cortex-a72", "-m", "512M",
     "-nographic", "-kernel", "build/arm64/kernel.bin"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(6)
p.kill()
out = p.communicate()[0].replace("\r", "")
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
m = re.search(r"scheduler started\n([AB]+)", out)
seq = m.group(1) if m else ""
switches = sum(1 for a, b in zip(seq, seq[1:]) if a != b)
hit = switches >= 20
ok &= hit
print(("[PASS] " if hit else "[FAIL] ") + "timer interrupt context-switches between two kernel threads (A/B alternate, " + str(switches) + " switches)")
for b in BAD:
    if b in out:
        ok = False
        print("[FAIL] unexpected: " + b)
if not ok:
    print(out)
sys.exit(0 if ok else 1)
