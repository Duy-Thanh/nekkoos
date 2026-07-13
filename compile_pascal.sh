#!/usr/bin/env bash
# Script to compile Pascal modules to object files for linking with bflat

set -e

# Đảm bảo thư mục build tồn tại
mkdir -p build

echo "[Pascal] Compiling libc.pas for Win64 target using native fpc with custom config..."

# 1. Compile LibC
fpc -Twin64 -O2 -XXs -CX -Ur -Si @.fpc/fpc.cfg -FUbuild/ src/libc.pas

# 2. Compile PRNG
fpc -Twin64 -O2 -XXs -CX -Ur -Si @.fpc/fpc.cfg -FUbuild/ src/prng.pas

if [ -f "build/libc.o" ] && [ -f "build/prng.o" ]; then
    echo "[Pascal] ✓ build/libc.o & build/prng.o compiled and stripped successfully!"
    ls -lh build/libc.o build/prng.o
else
    echo "[Pascal] ✗ Compilation failed!"
    exit 1
fi
