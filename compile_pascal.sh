#!/usr/bin/env bash
# Script to compile Pascal modules to object files for linking with bflat

set -e

# Đảm bảo thư mục build tồn tại
mkdir -p build

# ==========================================================================
# [DANH SÁCH MODULE] Thêm module Pascal mới vào đây khi port thêm.
# ==========================================================================
PASCAL_MODULES=(libc prng kerncrypto pmm heap strandscheduler ipc terminal arch_interface)
ARCH_X86_64_MODULES=(interrupt_impl timer_impl mmu_impl)

for mod in "${PASCAL_MODULES[@]}"; do
    echo "[Pascal] Compiling ${mod}.pas for Win64 target using native fpc with custom config..."
    fpc -Twin64 -O1 -CX -Ur -g- -Si @.fpc/fpc.cfg -FUbuild/ "src/${mod}.pas"
done

# Compile x86_64 architecture-specific modules
for mod in "${ARCH_X86_64_MODULES[@]}"; do
    echo "[Pascal] Compiling arch/x86_64/${mod}.pas for Win64 target..."
    fpc -Twin64 -O1 -CX -Ur -g- -Si @.fpc/fpc.cfg -FUbuild/ "src/arch/x86_64/${mod}.pas"
done

echo "[Pascal] Stripping bogus type-0 (ABSOLUTE/placeholder) relocations from COFF object files..."
# NOTE: These are placeholder relocations FPC emits (e.g. tied to \$unwind\$ symbols at
# offset 0 of each .text section, or inside .pdata/.debug_frame) that carry no real value
# to patch. LLD refuses to link IMAGE_REL_AMD64_ABSOLUTE (type 0), so previously we tried
# converting them to ADDR64 - that was WRONG: it made the linker actually WRITE 8 bytes of
# an absolute address at that offset, smashing the first bytes of function prologues and
# causing #GP crashes at runtime. The correct fix is to just DELETE the relocation entries
# (not touch any code/data bytes) so the linker never even sees them.
python3 - "${PASCAL_MODULES[@]}" "${ARCH_X86_64_MODULES[@]}" <<'EOF'
import struct
import sys

def patch_coff(filename):
    with open(filename, 'rb+') as f:
        data = bytearray(f.read())

        # Parse COFF Header
        num_sections = struct.unpack_from('<H', data, 2)[0]

        # Parse Section Headers
        header_size = 20
        removed_total = 0
        for i in range(num_sections):
            sec_offset = header_size + i * 40
            reloc_offset = struct.unpack_from('<I', data, sec_offset + 24)[0]
            num_relocs = struct.unpack_from('<H', data, sec_offset + 32)[0]
            if reloc_offset > 0 and num_relocs > 0:
                kept = []
                for r in range(num_relocs):
                    ro = reloc_offset + r * 10
                    entry = bytes(data[ro:ro + 10])
                    rtype = struct.unpack_from('<H', entry, 8)[0]
                    if rtype != 0:
                        kept.append(entry)
                removed = num_relocs - len(kept)
                if removed:
                    removed_total += removed
                    # Compact remaining entries in-place; leftover trailing bytes are
                    # simply unused padding now (never referenced since NumberOfRelocations
                    # is reduced), so no other structure is affected.
                    for idx, entry in enumerate(kept):
                        data[reloc_offset + idx * 10: reloc_offset + idx * 10 + 10] = entry
                    struct.pack_into('<H', data, sec_offset + 32, len(kept))

        f.seek(0)
        f.write(data)
        f.truncate()
        print(f"[Pascal]   {filename}: removed {removed_total} placeholder relocation(s)")

for mod in sys.argv[1:]:
    patch_coff(f'build/{mod}.o')
EOF

all_ok=1
for mod in "${PASCAL_MODULES[@]}"; do
    if [ ! -f "build/${mod}.o" ]; then
        all_ok=0
    fi
done

if [ "$all_ok" -eq 1 ]; then
    echo "[Pascal] ✓ All Pascal modules compiled and patched successfully!"
    ls -lh build/*.o
else
    echo "[Pascal] ✗ Compilation failed!"
    exit 1
fi
