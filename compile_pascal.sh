#!/usr/bin/env bash
# Script to compile Pascal modules to object files for linking with bflat

set -e

# Đảm bảo thư mục build tồn tại
mkdir -p build

echo "[Pascal] Compiling libc.pas for Win64 target using native fpc with custom config..."

# 1. Compile LibC
fpc -Twin64 -O1 -CX -Ur -g- -Si @.fpc/fpc.cfg -FUbuild/ src/libc.pas

# 2. Compile PRNG
fpc -Twin64 -O1 -CX -Ur -g- -Si @.fpc/fpc.cfg -FUbuild/ src/prng.pas

# 3. Compile KernCrypto (SHA-256 + hex utils)
fpc -Twin64 -O1 -CX -Ur -g- -Si @.fpc/fpc.cfg -FUbuild/ src/kerncrypto.pas

echo "[Pascal] Stripping bogus type-0 (ABSOLUTE/placeholder) relocations from COFF object files..."
# NOTE: These are placeholder relocations FPC emits (e.g. tied to \$unwind\$ symbols at
# offset 0 of each .text section, or inside .pdata/.debug_frame) that carry no real value
# to patch. LLD refuses to link IMAGE_REL_AMD64_ABSOLUTE (type 0), so previously we tried
# converting them to ADDR64 - that was WRONG: it made the linker actually WRITE 8 bytes of
# an absolute address at that offset, smashing the first bytes of function prologues and
# causing #GP crashes at runtime. The correct fix is to just DELETE the relocation entries
# (not touch any code/data bytes) so the linker never even sees them.
python3 - <<'EOF'
import struct

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

patch_coff('build/libc.o')
patch_coff('build/prng.o')
patch_coff('build/kerncrypto.o')
EOF

if [ -f "build/libc.o" ] && [ -f "build/prng.o" ] && [ -f "build/kerncrypto.o" ]; then
    echo "[Pascal] ✓ build/libc.o, build/prng.o & build/kerncrypto.o compiled and patched successfully!"
    ls -lh build/libc.o build/prng.o build/kerncrypto.o
else
    echo "[Pascal] ✗ Compilation failed!"
    exit 1
fi

