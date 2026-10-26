#!/usr/bin/env bash
# Compile the EFI bootloader unit (src/boot/boot.pas) to build/boot.o.
# Run AFTER the public key has been injected into boot.pas (build.sh does that
# between signing the kernel and calling this).
set -e
cd "$(dirname "$0")"
mkdir -p build
echo "[Pascal] Compiling boot/boot.pas for Win64 target..."
fpc -Twin64 -O1 -CX -Ur -g- -Si -CD @.fpc/fpc.cfg -FUbuild/ src/boot/boot.pas
python3 scripts/strip_coff_relocs.py build/boot.o
if objdump -t build/boot.o | grep -qF 'RTTI_$'; then
    echo "[!] RTTI symbols in build/boot.o (AGENTS.md 6.3)"; exit 1
fi
