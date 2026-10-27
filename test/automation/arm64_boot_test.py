#!/usr/bin/env python3
"""ARM64 bring-up test: boot build/arm64/kernel.elf on QEMU virt and check the UART."""
import subprocess, sys, time

EXPECT = [
    "NekkoOS arm64: early init",
    "arm64: 100 ms elapsed on the generic counter, core id 0",
    "arm64: bring-up milestone 1 reached",
]
BAD = ["UNIMPLEMENTED", "FATAL"]

p = subprocess.Popen(
    ["qemu-system-aarch64", "-machine", "virt", "-cpu", "cortex-a72", "-m", "512M",
     "-nographic", "-kernel", "build/arm64/kernel.elf"],
    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(4)
p.kill()
out = p.communicate()[0].replace("\r", "")
ok = True
for e in EXPECT:
    hit = e in out
    ok &= hit
    print(("[PASS] " if hit else "[FAIL] ") + e)
for b in BAD:
    if b in out:
        ok = False
        print("[FAIL] unexpected: " + b)
if not ok:
    print(out)
sys.exit(0 if ok else 1)
