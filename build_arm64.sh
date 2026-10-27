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

PAS_MODULES=(arch_interface arch_hal boot_arm64)
for m in "${PAS_MODULES[@]}"; do
    echo "[arm64] Pascal $m"
    ppca64 -Paarch64 -Tlinux -XPaarch64-linux- -O1 -Ur -g- -Si -CD "@$CFG" -FU"$OUT" "src/arch/arm64/$m.pas"
done
for s in start hardware_arm64; do
    echo "[arm64] asm $s"
    clang --target=aarch64-none-elf -c "src/arch/arm64/$s.S" -o "$OUT/$s.o"
done
ld.lld -T src/arch/arm64/link.ld -o "$OUT/kernel.elf" \
    "$OUT/start.o" "$OUT/hardware_arm64.o" "$OUT/boot_arm64.o" "$OUT/arch_hal.o" "$OUT/arch_interface.o"
echo "[arm64] built $OUT/kernel.elf"
