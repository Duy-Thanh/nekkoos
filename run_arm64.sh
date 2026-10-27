#!/usr/bin/env bash
# Run the ARM64 kernel on QEMU virt; serial goes to stdio. Ctrl-A X quits.
exec qemu-system-aarch64 -machine virt -cpu cortex-a72 -m 512M -nographic -kernel build/arm64/kernel.elf "$@"
