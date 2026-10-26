#!/usr/bin/env python3
"""Delete the IMAGE_REL_AMD64_ABSOLUTE (type 0) placeholder relocations FPC puts in
COFF objects. lld refuses them. Only relocation ENTRIES are removed; code and data
bytes are never touched (rewriting them once smashed function prologues).

Usage: strip_coff_relocs.py file.o [file2.o ...]
Same logic as the inline step in compile_pascal.sh, for images built outside it
(the EFI bootloader).
"""
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


if __name__ == "__main__":
    for path in sys.argv[1:]:
        patch_coff(path)
