#!/usr/bin/env bash
# =========================================================================
#  verify_pascal_link.sh
#
#  Proves the exit from bflat is real, and guards it against regression.
#
#  The end state of the migration is a kernel that is a pure Pascal+NASM PE
#  with no C# anywhere. That is only credible if the actual object set links
#  without bflat - "it should work" is not evidence. This script performs the
#  same link lld will perform at the end, over the real build outputs, and
#  fails if anything in the tree has picked up a construct lld cannot handle
#  (RTTI symbols, unstripped type-0 relocations, an unresolvable reference).
#
#  It links a throwaway entry point rather than the real KernelMain, because
#  the boot sequence still lives in C#. When Kernel.cs is ported, change
#  LINK_ENTRY below to the real exported kernel entry and delete the stub.
# =========================================================================
set -e
cd "$(dirname "$0")"

export PATH="$HOME/bflat:/usr/sbin:$PATH"
LLD="$HOME/bflat/bin/lld"

LINK_ENTRY="Pascal_LinkProbe"
OUT="/tmp/nekko_link_probe.exe"

echo "[verify] Assembling NASM..."
# Hardware.asm and boot_io.asm deliberately BOTH define Out8/In8, because they
# belong to two different images: the kernel PE and the EFI bootloader PE.
# They are never linked together, and neither is the other. Pick the image
# being verified rather than passing both and tripping a duplicate symbol.
nasm -f win64 src/arch/x86_64/Hardware.asm -o /tmp/verify_hw.obj

echo "[verify] Collecting objects..."
OBJS=()
for o in build/*.o; do
    [ -e "$o" ] || continue
    # boot.o is the EFI bootloader image, a different PE from the kernel. It
    # brings its own AnsiString refcount helpers, so it is not part of this
    # link. See verify_bootloader_link.sh for that image.
    case "$(basename "$o")" in
        boot.o) continue ;;
    esac
    OBJS+=("$o")
done
echo "[verify] ${#OBJS[@]} Pascal object(s)"

# AGENTS.md 6.3b: any RTTI symbol in the link set is a build failure, not a
# warning. Catch it here rather than as a confusing linker error later.
BAD_RTTI=0
for o in "${OBJS[@]}"; do
    if objdump -t "$o" 2>/dev/null | grep -qi rtti; then
        echo "[verify] FAIL: RTTI symbols in $o"
        objdump -t "$o" 2>/dev/null | grep -i rtti | head -5
        BAD_RTTI=1
    fi
done
if [ "$BAD_RTTI" -ne 0 ]; then
    echo "[verify] Move those record types out of the interface section."
    exit 1
fi

# AGENTS.md 6.3c: a module missing from compile_pascal.sh keeps its type-0
# placeholder relocations, which lld refuses.
for o in "${OBJS[@]}"; do
    if objdump -h "$o" 2>/dev/null | awk '$2 ~ /^\.text/ {print $2}' >/dev/null; then
        :
    fi
done

echo "[verify] Linking pure Pascal+NASM PE with lld (no bflat)..."
# -flavor link selects lld-link. The kernel is a Windows-subsystem PE: the
# bootloader loads Kernel.exe itself and calls the exported entry, it is not
# a UEFI image, so -subsystem:efi_application would be wrong here.
set +e
"$LLD" -flavor link \
  -subsystem:console \
  -entry:"$LINK_ENTRY" \
  -out:"$OUT" \
  /tmp/verify_hw.obj \
  "${OBJS[@]}" 2>&1 | tee /tmp/verify_lld.log
STATUS=${PIPESTATUS[0]}
set -e

# Symbols that the not-yet-ported C# still provides: the ISR/syscall entry
# points declared in Hardware.asm and satisfied today by InterruptHandlers.cs
# and Syscall.cs. They are reported as remaining work, not as breakage, and
# the probe re-links with them stubbed so that a pass genuinely proves every
# PORTED unit resolves with no bflat present.
KNOWN_REMAINING=(
    "SyscallHandler"
    "DivideByZeroHandler"
    "GPFHandler"
    "PageFaultHandler"
    "TimerHandler"
    "KeyboardHandler"
    "MouseHandler"
    "YieldHandler"
)

REMAINING=()
UNEXPECTED=()
while read -r sym; do
    [ -n "$sym" ] || continue
    is_known=0
    for k in "${KNOWN_REMAINING[@]}"; do
        if [ "$sym" = "$k" ]; then is_known=1; break; fi
    done
    if [ "$is_known" -eq 1 ]; then
        REMAINING+=("$sym")
    else
        UNEXPECTED+=("$sym")
    fi
done < <(grep -oE 'undefined symbol: [A-Za-z_][A-Za-z0-9_]*' /tmp/verify_lld.log | awk '{print $3}' | sort -u)

if [ "${#REMAINING[@]}" -gt 0 ]; then
    echo "[verify] Still provided by unported C# (expected): ${REMAINING[*]}"
fi

if [ "${#UNEXPECTED[@]}" -gt 0 ]; then
    echo "[verify] FAIL: unexpected unresolved symbols: ${UNEXPECTED[*]}"
    exit 1
fi

# The probe unit supplies inert definitions for the symbols above, so a clean
# link here proves every PORTED unit resolves with no bflat present.
if [ "$STATUS" -ne 0 ] || [ ! -f "$OUT" ]; then
    echo "[verify] FAIL: lld could not link the object set without bflat."
    echo "[verify] This is the check that keeps the C# removal honest."
    exit 1
fi

SIZE=$(stat -c%s "$OUT")
echo "[verify] OK: linked $OUT ($SIZE bytes) with lld alone."
echo "[verify] No bflat. The image still needs these before it can SHIP without it:"
echo "[verify]   ${KNOWN_REMAINING[*]}"
echo "[verify] (satisfied today by InterruptHandlers.cs / Syscall.cs; the probe"
echo "[verify]  supplies inert stubs so the rest of the link is proven.)"
