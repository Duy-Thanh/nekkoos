#!/usr/bin/env bash
# =========================================================================
#  verify_bootloader_link.sh
#
#  The EFI bootloader is its own image: build/boot.o plus boot_io.obj,
#  linked with -subsystem:efi_application and the bare NekkoBoot entry.
#  It is deliberately separate from verify_pascal_link.sh, which proves the
#  kernel image links without bflat - the two share no objects beyond
#  libc-like helpers, and Hardware.asm and boot_io.asm both define Out8/In8,
#  so they can never appear in the same link.
# =========================================================================
set -e
cd "$(dirname "$0")"

export PATH="$HOME/bflat:/usr/sbin:$PATH"
LLD="$HOME/bflat/bin/lld"
OUT="/tmp/nekko_boot_probe.efi"

echo "[verify-boot] Assembling boot_io.asm..."
nasm -f win64 src/boot/boot_io.asm -o /tmp/verify_boot_io.obj

if [ ! -f build/boot.o ]; then
    echo "[verify-boot] FAIL: build/boot.o missing. Run ./compile_pascal.sh first."
    exit 1
fi

if objdump -t build/boot.o 2>/dev/null | grep -qi rtti; then
    echo "[verify-boot] FAIL: RTTI symbols in build/boot.o"
    objdump -t build/boot.o 2>/dev/null | grep -i rtti | head -5
    exit 1
fi

echo "[verify-boot] Linking EFI bootloader PE with lld (no bflat)..."
set +e
"$LLD" -flavor link \
  -subsystem:efi_application \
  -entry:NekkoBoot \
  -out:"$OUT" \
  /tmp/verify_boot_io.obj \
  build/boot.o 2>&1 | tee /tmp/verify_boot_lld.log
STATUS=${PIPESTATUS[0]}
set -e

# Known gap: boot.pas uses AnsiString, so FPC emits references to the RTL's
# string refcount helpers and the generic exception dispatcher. bflat supplied
# those by accident (it links the FPC runtime); plain lld does not.
#
# The fix is to remove the dependency, not to reimplement the RTL: rewrite the
# AnsiString uses in boot.pas against PChar/PByte, which suits a freestanding
# bootloader anyway. If a real implementation is ever needed instead, these
# three are the full list:
KNOWN_RTL_GAP=(
    "fpc_ansistr_incr_ref"
    "fpc_ansistr_decr_ref"
    "__FPC_specific_handler"
)

UNEXPECTED=()
while read -r sym; do
    [ -n "$sym" ] || continue
    is_known=0
    for k in "${KNOWN_RTL_GAP[@]}"; do
        if [ "$sym" = "$k" ]; then is_known=1; break; fi
    done
    [ "$is_known" -eq 1 ] || UNEXPECTED+=("$sym")
done < <(grep -oE 'undefined symbol: [A-Za-z_][A-Za-z0-9_]*' /tmp/verify_boot_lld.log | awk '{print $3}' | sort -u)

if [ "${#UNEXPECTED[@]}" -gt 0 ]; then
    echo "[verify-boot] FAIL: unexpected unresolved symbols: ${UNEXPECTED[*]}"
    exit 1
fi

if [ "$STATUS" -ne 0 ]; then
    echo "[verify-boot] KNOWN GAP: bootloader still needs the FPC RTL because"
    echo "[verify-boot]   boot.pas uses AnsiString -> ${KNOWN_RTL_GAP[*]}"
    echo "[verify-boot] Everything else resolves. Fix: port those AnsiString uses"
    echo "[verify-boot]   to PChar/PByte so the image is freestanding."
    echo "[verify-boot] (The shipped bootloader is still C#, so this is not yet"
    echo "[verify-boot]  blocking; the C# path links fine today.)"
    exit 2
fi

SIZE=$(stat -c%s "$OUT")
echo "[verify-boot] OK: linked $OUT ($SIZE bytes) with lld alone."
echo "[verify-boot] Replace the bflat step in build.sh with these lld arguments."
