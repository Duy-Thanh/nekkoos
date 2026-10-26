#!/usr/bin/env bash
# =========================================================================
#  verify_pascal_link.sh - guard the "no C#, no RTTI" invariants.
#
#  The kernel, the apps and the EFI bootloader are all linked by lld straight
#  from Pascal and NASM objects (see build.sh), so the build itself proves
#  that every symbol resolves. What it does NOT stop is the next unit
#  quietly reintroducing something lld only complains about at the very end
#  (or something that links but is wrong):
#
#    * a .cs file creeping back into src/ (the project dropped C# on purpose)
#    * RTTI symbols in any object (AGENTS.md 6.3 - a record in a unit's
#      interface section is the usual cause; lld then fails with
#      "undefined symbol: RTTI_$SYSTEM_...")
#    * a build artifact in the tree that is not a PE with the exports the
#      bootloader and the kernel loader look up
#
#  Run it after ./build.sh.
# =========================================================================
set -e
cd "$(dirname "$0")"
fail=0

echo "[verify] no C# in the tree..."
stray=$(find src -name '*.cs' -print)
if [ -n "$stray" ]; then echo "[verify] FAIL: C# sources present:"; echo "$stray"; fail=1; fi

echo "[verify] no RTTI in any Pascal object..."
for o in build/*.o; do
    [ -e "$o" ] || continue
    if objdump -t "$o" 2>/dev/null | grep -qF 'RTTI_$'; then
        echo "[verify] FAIL: RTTI symbols in $o"
        objdump -t "$o" | grep -F 'RTTI_$' | head -3
        fail=1
    fi
done

echo "[verify] image exports..."
export_of() { objdump -p "$1" 2>/dev/null | grep -c "$2" || true; }
[ -f Kernel.exe ] && [ "$(export_of Kernel.exe KernelMain)" -ge 1 ] || { echo "[verify] FAIL: Kernel.exe missing or does not export KernelMain"; fail=1; }
for app in Shell.exe SysLogon.exe FAT16.exe ATA.exe Mouse.exe acpi.exe; do
    [ -f "$app" ] && [ "$(export_of "$app" AppMain)" -ge 1 ] || { echo "[verify] FAIL: $app missing or does not export AppMain"; fail=1; }
done
[ -f efi/boot/bootx64.efi ] || { echo "[verify] FAIL: efi/boot/bootx64.efi missing"; fail=1; }

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "[verify] OK: Pascal + NASM only, RTTI-free, entry points present."
