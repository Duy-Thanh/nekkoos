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
`link.ld` (load at 0x40080000), `boot_arm64.pas`, `traps_arm64.pas` (IRQ/svc entry), `fdt.pas`, and ARM64 twins of `serial` (PL011) and `terminal` (UART only, headless).

User programs: `src/user/arm64/*.S`, linked at 4 GiB (`-N -Ttext=0x100000000`) and embedded in the kernel via `user_images.S` until a filesystem exists. Hal_SyncCode cleans the data cache and invalidates the instruction cache after code is copied in.

Alignment: ARM64 exclusive accesses fault on misaligned addresses, but the scheduler's packed thread records have QWord fields at odd offsets. `Arch_AtomicAdd64` takes a slow lock-protected path for those.

Interrupt state: generic code must ask `Arch_InterruptsEnabled`, never test RFLAGS bit 9 (on ARM64 that bit of DAIF is the debug mask, so a `flags and $200` test silently reports "interrupts off").

Vector slots are 128 bytes: they only `b` to handlers placed elsewhere (a full frame save+restore overflows a slot and silently corrupts the next vector).

Differences worth knowing: AArch64 integer divide by zero does not trap, so FPC
emits `FPC_DIVBYZERO` (provided in `hardware_arm64.S`, stops the machine);
x86-only `Arch_*` symbols are stubs that halt, so `arch_interface.o` links.

## Status

- [x] Toolchain, link, boot to Pascal on QEMU virt, PL011 output, generic counter
- [x] Exception vectors, GICv2, 250 Hz timer tick interrupt (fatal faults print ESR/ELR/FAR)
- [x] Device tree (`fdt.pas`) -> RAM size -> generic `pmm`; MMU on (identity map, 1 GiB blocks)
- [x] `Hal_MapPageIn` / `Hal_CreateUserAddressSpace` / `Hal_DestroyAddressSpace` (4 KiB pages; user VAs must stay outside the kernel's 1 GiB slots)
- [x] Generic scheduler running on it: timer IRQ -> `Sched_SwitchTask` -> resume another thread's trap frame (two kernel threads alternate)
- [x] Shared boot services via `kernel_core` (heap, IPC, PRNG, strand engine, scheduler, idle loop) used by both x86 `kernel_main` and `boot_arm64`
- [x] virtio-blk (modern MMIO transport, polled): read/write sectors, bounds-checked; `run_arm64.sh` attaches `build/arm64/disk.img`
- [ ] A filesystem on that disk (FAT16 code is generic but sits behind the x86 ATA daemon), then loading user programs from it
- [ ] Daemons / `SpawnDaemon` on ARM64 (PE x86 apps; need ELF builds of ATA/FAT16/ACPI/MOUSE or ARM64 replacements)
- [x] EL0 user mode: `svc` syscalls (number in x8, "arg 1" in x1, result in x0; exit/print/uptime/yield), generic `elf_loader`, user-pointer vetting via `Hal_IsUserPageMapped`; a user program that touches kernel memory is reported and terminated, the system keeps running
- [x] The generic `syscall_dispatch` serves EL0 (arm64 `syscall_impl` reports hardware-only calls as unavailable); `Hal_IsUserPageMapped` replaced the x86 pointer walker in dispatch/shell/sudo; PSCI `HAL_Reboot`/`HAL_Shutdown` (shutdown verified)
- [ ] Hardware syscalls for real: keyboard, framebuffer, MapPhys
- [ ] Secondary cores via PSCI
