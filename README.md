# NekkoOS

NekkoOS - An Hobby Operating System written in C# and Assembly

Developed by Nguyen Duy Thanh (Nekkochan)

Copyright &copy; 2026 Nguyen Duy Thanh (Nekkochan). All right reserved

The NekkoOS project was developed starting in January 2026 by developer Nguyen Duy Thanh and is a project for his graduation thesis

Currently, the project has implemented the use of bflat (the project's compiler) with zerolib to compile an operating system running on x86_64

Key features:

- 64-bit Microkernel
- UEFI bootloader
- Compatibility with UEFI CSM/non-CSM devices
- User-space drivers
- Inter-process communication (IPC)
- Multitasking
- Asymmetric multi-core processing (SMP)
- Support for running user applications

# Report and Slides

The report and slides are currently being prepared. They will be available in two languages: Vietnamese and English

# Project Development Status and Future Prospects

The project is still under continuous development and improvement. The author is committed to continuing to develop and refine this project in the future, even after the graduation thesis has been successfully defended!

# Building from Source

NekkoOS is built with [bflat](https://github.com/bflattened/bflat) (C#, `--stdlib zero`) plus Free Pascal modules cross-compiled to Win64 COFF objects. The instructions below target openSUSE Tumbleweed; adapt the package names for other distributions.

## Prerequisites

```bash
sudo zypper install nasm fpc fpc-src mingw64-cross-binutils \
     dosfstools mtools openssl python3 wget qemu-system-x86
```

| Tool | Purpose |
|------|---------|
| bflat | C# kernel/bootloader/apps compiler |
| nasm | x86-64 assembly (boot I/O, SMP trampoline) |
| fpc + Win64 RTL | Pascal modules compiled as COFF objects (`-Twin64`) |
| mingw64-cross-binutils | Win64 assembler/linker for FPC cross-compilation |
| dosfstools, mtools | FAT16 disk image creation and population |
| openssl | RSA-2048 key generation and kernel signing |
| python3 | Build-time patching (COFF relocations, pubkey injection) |
| qemu-system-x86_64 | Emulation (UEFI boot via bundled OVMF firmware) |

## Setup

Run once per clone:

```bash
./prepare_repo.sh       # installs the git commit-msg hook (Gerrit Change-Id)
./setup_bflat.sh        # downloads bflat v10.0.0-rc.1 to ~/bflat and adds it to PATH
./setup_fpc_win64.sh    # builds the FPC x86_64-win64 RTL and generates .fpc/fpc.cfg
```

`setup_bflat.sh` detects your login shell (bash/zsh/fish) when adding `~/bflat` to PATH — run `source ~/.zshrc` (or the rc file it prints) to use it immediately.

## Build and Run

```bash
./build.sh              # compiles everything and produces hdd.img
./run.sh                # boots hdd.img in QEMU (KVM, UEFI via OVMF_X64.fd)
./clean.sh              # removes build artifacts
```

The first `build.sh` run generates `private.pem`/`pubkey.bin`, signs `Kernel.exe` into `Kernel.exe.mui`, injects the public key into the bootloader source, and assembles an 8 MB FAT16 image containing the bootloader, kernel, system daemons and Ring 3 applications.

> **Note:** the login database files `passwd` and `sudoers` are intentionally gitignored (they contain password hashes). Generate them before building — format: `user:salt-hex:sha256(salt+password)-hex:UID:GID:/HOME/user`.