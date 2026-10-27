# NekkoOS on ARM64

Target: QEMU `virt` (AArch64), later real boards. Status is tracked at the bottom.

## Toolchain (one-time)

FPC 3.2.2 has no packaged AArch64 cross-compiler and the machine has no ARM64
binutils, so both are provided locally under `~/.local/share/fpc-aarch64`
(override with `FPC_A64`):

1. Fetch FPC `release_3_2_2` source and build the cross compiler (host x86_64,
   target aarch64):  `make -C compiler PP=/usr/bin/ppcx64 PPC_TARGET=aarch64 all`
   -> `compiler/ppca64`.
2. Build the RTL: `make -C rtl PP=<ppca64> CPU_TARGET=aarch64 OS_TARGET=linux all`
   -> `rtl/units/aarch64-linux`, copied to `$FPC_A64/units`.
3. FPC calls `aarch64-linux-as/ar/ld`; `$FPC_A64/bin` holds wrappers that
   forward to `clang --target=aarch64-linux-gnu -c -x assembler`, `llvm-ar`
   and `ld.lld`.

Also needs `qemu-system-aarch64` (`zypper in qemu-arm`).

## Build / run / test

    ./build_arm64.sh    # build/arm64/kernel.bin (arm64 Image; QEMU passes the DTB only to an Image, not to an ELF)
    ./run_arm64.sh      # QEMU virt, serial on stdio, Ctrl-A X quits
    python3 test/automation/arm64_boot_test.py

## Layout

`src/arch/arm64/`: `arch_interface.pas` and `arch_hal.pas` (same interface as
the x86_64 ones, they shadow them because this directory is searched last),
`start.S` (entry, stack, bss), `hardware_arm64.S` (Arch_* primitives),
`link.ld` (load at 0x40080000), `boot_arm64.pas` (first Pascal code).

Differences worth knowing: AArch64 integer divide by zero does not trap, so FPC
emits `FPC_DIVBYZERO` (provided in `hardware_arm64.S`, stops the machine);
x86-only `Arch_*` symbols are stubs that halt, so `arch_interface.o` links.

## Status

- [x] Toolchain, link, boot to Pascal on QEMU virt, PL011 output, generic counter
- [x] Exception vectors, GICv2, 250 Hz timer tick interrupt (fatal faults print ESR/ELR/FAR)
- [x] Device tree (`fdt.pas`) -> RAM size -> generic `pmm`; MMU on (identity map, 1 GiB blocks)
- [x] `Hal_MapPageIn` / `Hal_CreateUserAddressSpace` / `Hal_DestroyAddressSpace` (4 KiB pages; user VAs must stay outside the kernel's 1 GiB slots)
- [ ] Generic kernel (`kernel_main`, scheduler) running on it
- [ ] EL0 user mode, syscalls (`svc`), PE-less app loader (ELF)
- [ ] Secondary cores via PSCI
