#!/usr/bin/env bash
# Run the ARM64 kernel on QEMU virt; serial goes to stdio. Ctrl-A X quits.
# The disk is a virtio-blk device on the modern MMIO transport (the driver does not speak legacy).
exec qemu-system-aarch64 -machine virt -cpu cortex-a72 -m 512M -nographic \
    -global virtio-mmio.force-legacy=false \
    -drive file=build/arm64/disk.img,if=none,format=raw,id=hd0 -device virtio-blk-device,drive=hd0 \
    -kernel build/arm64/kernel.bin "$@"
