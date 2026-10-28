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
PAS_MODULES=(arch_interface serial terminal syscall_impl virtio_blk fdt arch_hal traps_arm64 boot_arm64)
for m in "${PAS_MODULES[@]}"; do
    echo "[arm64] Pascal $m"
    ppca64 -Paarch64 -Tlinux -XPaarch64-linux- -O1 -Ur -g- -Si -CD "@$CFG" -FU"$OUT" "src/arch/arm64/$m.pas"
done
# User programs (ELF, linked at 4 GiB, one RWX segment) are embedded in the kernel.
for u in hello crash; do
    clang --target=aarch64-none-elf -c "src/user/arm64/$u.S" -o "$OUT/user_$u.o"
    ld.lld -N -Ttext=0x100000000 -e _start -o "$OUT/$u.elf" "$OUT/user_$u.o"
done
for s in start hardware_arm64 user_images; do
    echo "[arm64] asm $s"
    clang --target=aarch64-none-elf -c "src/arch/arm64/$s.S" -o "$OUT/$s.o"
done
OBJS=("$OUT/start.o" "$OUT/hardware_arm64.o" "$OUT/user_images.o")
for m in "${PAS_MODULES[@]}" "${GENERIC_MODULES[@]}"; do OBJS+=("$OUT/$m.o"); done
ld.lld -T src/arch/arm64/link.ld -o "$OUT/kernel.elf" "${OBJS[@]}"
# QEMU only passes the device-tree pointer (x0) to a raw Image, not to an ELF.
llvm-objcopy -O binary "$OUT/kernel.elf" "$OUT/kernel.bin"
# Test disk: sector 0 carries a signature the kernel prints back.
dd if=/dev/zero of="$OUT/disk.img" bs=1M count=1 status=none
printf 'NEKKO-VIRTIO-OK\n' | dd of="$OUT/disk.img" conv=notrunc status=none
echo "[arm64] built $OUT/kernel.bin"
