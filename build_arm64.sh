#!/usr/bin/env bash
# Build the ARM64 kernel image (bring-up). Needs the cross toolchain, see docs/ARM64.md.
set -euo pipefail
FPC_A64="${FPC_A64:-$HOME/.local/share/fpc-aarch64}"
export PATH="$FPC_A64/bin:$PATH"
OUT=build/arm64
rm -rf "$OUT"; mkdir -p "$OUT"

# src/arch/arm64 is listed last on purpose: later -Fu entries win, so its
# arch_interface/arch_hal shadow the x86_64 ones in src/arch.
CFG="$OUT/fpc.cfg"
cat > "$CFG" <<EOF
-Fu$FPC_A64/units
-Fusrc/kernel/pas
-Fusrc/arch
-Fusrc/arch/hal
-Fusrc/drivers
-Fusrc/arch/arm64
EOF

# Generic kernel units the ARM64 image already uses, then the arch units.
GENERIC_MODULES=(fpc_runtime spinlock libc kstring pmm kstate prng console ipc ipc_kernel scheduler_dispatch scheduler heap io strandscheduler kernel_core elf_loader syscall_security syscall_core syscall_dispatch ata_kernel fat16_kernel ata_hw fat16fs internal_shell sudo_dispatch pe_loader power pci kerncrypto passwd_parser memmap_scan input_drv fat16)
for m in "${GENERIC_MODULES[@]}"; do
    echo "[arm64] Pascal (generic) $m"
    ppca64 -Paarch64 -Tlinux -XPaarch64-linux- -O1 -Ur -g- -Si -CD "@$CFG" -FU"$OUT" "$(ls src/kernel/pas/$m.pas src/drivers/$m.pas 2>/dev/null | head -1)" >/dev/null
done
PAS_MODULES=(arch_interface serial terminal syscall_impl fdt arch_hal traps_arm64 boot_arm64)
for m in "${PAS_MODULES[@]}"; do
    echo "[arm64] Pascal $m"
    ppca64 -Paarch64 -Tlinux -XPaarch64-linux- -O1 -Ur -g- -Si -CD "@$CFG" -FU"$OUT" "src/arch/arm64/$m.pas"
done
# User programs (ELF, linked at 4 GiB, one RWX segment) are embedded in the kernel.
for u in hello crash mmio snoop diskapp; do
    clang --target=aarch64-none-elf -c "src/user/arm64/$u.S" -o "$OUT/user_$u.o"
    ld.lld -N -Ttext=0x100000000 -e _start -o "$OUT/$u.elf" "$OUT/user_$u.o"
done
# Pascal user programs: crt0 + uapi (+ kstring), linked at 4 GiB like the asm ones.
UOUT="$OUT/user"; mkdir -p "$UOUT"
UCFG="$UOUT/fpc.cfg"
cat > "$UCFG" <<EOF
-Fu$FPC_A64/units
-Fusrc/kernel/pas
-Fusrc/user/arm64
EOF
clang --target=aarch64-none-elf -c src/user/arm64/crt0.S -o "$UOUT/crt0.o"
upas() {          # upas <source.pas>: compile one user unit into $UOUT
    ppca64 -Paarch64 -Tlinux -XPaarch64-linux- -O1 -Ur -g- -Si -CD "@$UCFG" -FU"$UOUT" "$1" >/dev/null
}
# The ARM64 app_api twin is compiled first: -Ur keeps FPC from rebuilding it
# from src/apps/app_api.pas (x86) when an app in src/apps is compiled.
upas src/user/arm64/app_api.pas
upas src/user/arm64/vblk_daemon.pas
ld.lld -N -Ttext=0x100000000 -e _start -o "$OUT/vblk.elf" \
    "$UOUT/crt0.o" "$UOUT/vblk_daemon.o" "$UOUT/uapi.o" "$UOUT/kstring.o"
# FAT16.EXE: the x86 app source, unchanged, on the ARM64 app_api.
upas src/apps/fat16_app.pas
ld.lld -N -Ttext=0x100000000 -e _start -o "$OUT/fat16.elf" \
    "$UOUT/crt0.o" "$UOUT/fat16_app.o" "$UOUT/app_api.o" "$UOUT/libc.o" "$UOUT/fat16.o" "$UOUT/kstring.o"

for s in start hardware_arm64 user_images; do
    echo "[arm64] asm $s"
    clang --target=aarch64-none-elf -c "src/arch/arm64/$s.S" -o "$OUT/$s.o"
done
OBJS=("$OUT/start.o" "$OUT/hardware_arm64.o" "$OUT/user_images.o")
for m in "${PAS_MODULES[@]}" "${GENERIC_MODULES[@]}"; do OBJS+=("$OUT/$m.o"); done
ld.lld -T src/arch/arm64/link.ld -o "$OUT/kernel.elf" "${OBJS[@]}"
# QEMU only passes the device-tree pointer (x0) to a raw Image, not to an ELF.
llvm-objcopy -O binary "$OUT/kernel.elf" "$OUT/kernel.bin"
# Test disk: a FAT16 volume (superfloppy, like hdd.img) with a text file and a
# user program that exists nowhere else.
rm -f "$OUT/disk.img"
mkfs.fat -F 16 -C "$OUT/disk.img" 16384 >/dev/null
printf 'Hello from the FAT16 volume on virtio-blk' > "$OUT/hello.txt"
mcopy -i "$OUT/disk.img" "$OUT/hello.txt" ::/HELLO.TXT
mcopy -i "$OUT/disk.img" "$OUT/diskapp.elf" ::/DISKAPP.ELF
# 64 KiB of (offset mod 251), for the read-throughput check.
python3 -c "import sys; sys.stdout.buffer.write(bytes(i % 251 for i in range(65536)))" > "$OUT/big.bin"
mcopy -i "$OUT/disk.img" "$OUT/big.bin" ::/BIG.BIN
echo "[arm64] built $OUT/kernel.bin"
