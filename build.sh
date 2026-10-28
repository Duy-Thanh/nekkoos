#!/bin/bash
set -e

# Kill qemu if running to release hdd.img lock
pkill -f qemu-system-x86_64 || true
sleep 1

# Clean up. Deleting the runnable set outright used to mean that a Pascal
# compile failure left no hdd.img and no app binaries behind at all: the
# smoke run then reported "disk image not found", which reads nothing like a
# build error and sends you looking in the QEMU config. The previous artifacts
# are now held aside and put back if this build does not finish, so a failure
# leaves the machine in the state it was in rather than empty.
BUILD_BAK=/tmp/nekkoos-build-backup
rm -rf "$BUILD_BAK"
mkdir -p "$BUILD_BAK"

shopt -s nullglob
STAGED=""
for f in *.exe *.efi *.obj *.bin *.map hdd.img Kernel.exe.mui pubkey.bin; do
    [ -e "$f" ] || continue
    mv "$f" "$BUILD_BAK/" && STAGED="$STAGED $f"
done
if [ -d efi/boot ]; then
    mv efi/boot "$BUILD_BAK/efi_boot" && STAGED="$STAGED efi/boot"
fi
shopt -u nullglob

restore_previous_artifacts() {
    shopt -s nullglob
    for f in "$BUILD_BAK"/*; do
        [ -e "$f" ] || continue
        case "$f" in
            */efi_boot) mv "$f" efi/boot ;;
            *)          mv "$f" . ;;
        esac
    done
    shopt -u nullglob
    rm -rf "$BUILD_BAK"
    echo "[!] Build failed - previous artifacts restored."
}
trap restore_previous_artifacts ERR

rm -rf efi/boot *.pdb *.lib
mkdir -p efi/boot

# =========================================================================
# [NO C#] The tree is Pascal + NASM only. A stray .cs file means someone has
# reintroduced the toolchain this project removed; fail early and say so.
# =========================================================================
STRAY_CS=$(find src -name '*.cs' -print 2>/dev/null || true)
if [ -n "$STRAY_CS" ]; then
    echo "[NO C#] Source files in C# are not allowed (AGENTS.md section 2):"
    echo "$STRAY_CS"
    exit 1
fi

# One linker for every image: lld in link (MSVC-compatible) mode.
LLD="${LLD:-lld-link}"
command -v "$LLD" >/dev/null || { echo "[!] $LLD not found (install the lld package)"; exit 1; }

echo "[1.2/4] Dang build Pascal modules..."
./compile_pascal.sh

echo "[1.5/4] Dang build Kernel (Vi vua) & Apps Ring 3 truoc..."

nasm -f win64 src/arch/x86_64/Hardware.asm -o Hardware.obj
nasm -f win64 src/boot/boot_io.asm -o boot_io.obj
# nasm -f bin src/app.asm -o app.bin
nasm -f bin src/arch/x86_64/smp_x86.asm -o smp.bin
# nasm -f win64 src/app_syscall.asm -o app_syscall.obj

# Build Kernel + apps (no-pie, deterministic, map files)
# Kernel.exe is pure Pascal + NASM, linked by lld alone. The bootloader loads it as
# a PE (a DLL exporting KernelMain), applies its base relocations when it
# moves the image for KASLR, and calls the export.
#   /dll /noentry     no DllMain: KernelMain is the only way in
#   /dynamicbase ...  ASLR-capable, NX (what the bootloader expects of a relocatable image)
#   /export:KernelMain   the symbol boot.pas searches the export table for
KERNEL_OBJS="build/libc.o build/prng.o build/kerncrypto.o build/pmm.o build/heap.o build/fat16_kernel.o build/strandscheduler.o build/ipc.o build/terminal.o build/arch_interface.o build/interrupt_impl.o build/timer_impl.o build/mmu_impl.o build/platform_impl.o build/rtc.o build/fat16.o build/fpc_runtime.o build/pe_loader.o build/elf_loader.o build/program_loader.o build/syscall_security.o build/memmap_scan.o build/scheduler_dispatch.o build/passwd_parser.o build/internal_shell.o build/spinlock.o build/sudo_dispatch.o build/syscall_core.o build/syscall_dispatch.o build/kernel_main.o build/kernel_core.o build/scheduler.o build/ipc_kernel.o build/ata_kernel.o build/power.o build/console.o build/input_drv.o build/pci.o build/kstring.o build/kstate.o build/io.o build/serial.o build/gdt.o build/idt.o build/context.o build/vdso.o build/vmm.o build/pic.o build/isr.o build/pit.o build/apic.o build/ioapic.o build/ata_hw.o build/fat16fs.o build/platform_bootstrap.o build/interrupt_handlers.o build/smp.o build/arch_hal.o build/syscall_impl.o build/hardware_checks.o"
"$LLD" /dll /noentry /subsystem:console /out:Kernel.exe /Brepro \
    /incremental:no /opt:ref /dynamicbase /highentropyva /nxcompat /largeaddressaware \
    /export:KernelMain Hardware.obj $KERNEL_OBJS

# ATA_Driver is Pascal - see LINK_APP below.
# FAT16_Driver is Pascal - see LINK_APP below.
# acpi.exe is Pascal - see the LINK_APP block below.
# Shell.exe is Pascal - see the LINK_APP block below.
# SysLogon.exe is Pascal - see the LINK_APP block below.
# top is Pascal - see LINK_APP below.
# stresstest is Pascal - see LINK_APP below.

# Additional userland apps from build.bat
# dsrv is Pascal - see LINK_APP below.
# Mouse.exe is already Pascal - see the LINK_APP block below.
# explorer is Pascal - see LINK_APP below.

# =========================================================================
# [PURE PASCALL APPS] Liên kết app Ring-3 bằng lld, KHÔNG qua bflat.
#
# Đây là bước đầu tiên trong việc loại bỏ hoàn toàn bflat: userland không
# cần bất kỳ thứ gì từ runtime C#, chỉ cần bảng stub vDSO. App Pascal liên
# kết thành PE bình thường với entry 'AppMain', đúng như bflat làm.
#
# PELoader quét ảnh theo byte tìm magic 0x1337BEEFCAFE8BAD rồi patch nó
# bằng địa chỉ vDSO thật - nên không phụ thuộc compiler, chỉ phụ thuộc hằng
# số đó còn nằm trong .data của app.
#
# PELoader tìm entry point bằng cách tra tên 'AppMain' trong PE EXPORT
# DIRECTORY (FindAppMainExport_Pas) - nó KHÔNG đọc AddressOfEntryPoint trong
# optional header. Nên -export:AppMain là bắt buộc; chỉ có -entry thì image
# vẫn chạy được ngoài đời nhưng loader sẽ báo "Entry point not found".
#
# -subsystem:console: kernel nạp app như một PE bình thường, không phải UEFI
# image, nên subsystem phải khác efi_application.
# =========================================================================
echo "[*] Linking Pascal apps with lld..."
link_app() {
    local out="$1"; shift
    "$LLD" \
        -subsystem:console \
        -entry:AppMain \
        -export:AppMain \
        -out:"$out" \
        "$@"
}
link_app Mouse.exe   build/mouse_app.o   build/app_api.o
link_app Shell.exe   build/shell_app.o   build/app_api.o build/libc.o build/kstring.o
# kerncrypto replaces Login.cs's SHA256 shim: login_app calls
# SHA256_Compute_Pas / HexToBytes / BytesToHex / ConstantTimeEq directly.
link_app SysLogon.exe build/login_app.o   build/app_api.o build/libc.o build/kstring.o build/kerncrypto.o
# The storage daemons. kstring.o is required throughout for the W() UTF-16
# literal helper; fat16_app additionally needs the kernel-side fat16 unit.
link_app ATA.exe   build/ata_app.o   build/app_api.o build/kstring.o
link_app FAT16.exe build/fat16_app.o build/app_api.o build/libc.o build/fat16.o build/kstring.o
# GUI and utility apps. stresstest needs no asm obj: the loop is ordinary
# Pascal and the only inline asm left is the deliberate fault injection.
link_app top.exe       build/top_app.o       build/app_api.o build/libc.o
link_app dsrv.exe      build/dsrv_app.o      build/app_api.o build/libc.o
link_app explorer.exe  build/explorer_app.o  build/app_api.o build/libc.o
link_app memtest.exe   build/memtest_app.o   build/app_api.o build/kstring.o
link_app stresstest.exe build/stress_app.o  build/app_api.o build/libc.o
link_app acpi.exe       build/acpi_app.o      build/app_api.o build/kstring.o build/acpi_parse.o build/fpc_runtime.o

echo "[*] Waiting for FS to flush..."
sync
sleep 2

# Check Kernel.exe size (>10KB)
if [ ! -f Kernel.exe ] || [ $(stat -c%s Kernel.exe) -lt 10000 ]; then
  echo "[!] Lỗi: Kernel.exe kích thước quá nhỏ hoặc không tồn tại!"
  exit 1
fi

# Verify KASLR signature in Shell.exe (0xAD 0x8B 0xFE 0xCA 0xEF 0xBE 0x37 0x13)
# To temporarily disable KASLR for debugging runs, set DISABLE_KASLR=1 in the environment.
if [ "${DISABLE_KASLR:-0}" = "1" ]; then
  echo "[!] DISABLE_KASLR=1 - skipping KASLR signature check (temporary debugging mode)"
else
  if [ -f Shell.exe ]; then
    hex=$(xxd -p Shell.exe | tr -d '\n')
    if ! echo "$hex" | grep -q "ad8bfecaefbe3713"; then
      echo "[!!!] KASLR Signature (0x1337BEEFCAFE8BAD) NOT FOUND! Compiler optimized it away."
      exit 1
    else
      echo "[+] KASLR Signature is VALID! Proceeding..."
    fi
  else
    echo "[!] Shell.exe not found to verify KASLR signature!"
    exit 1
  fi
fi

# Generate RSA-2048 keys and sign Kernel
echo "[*] Generating RSA-2048 Keys and Signing Kernel..."
if [ ! -f private.pem ]; then
  echo "[+] Private Key not found. Generating..."
  openssl genrsa -out private.pem 2048
fi

# Extract modulus -> pubkey.bin (raw big-endian)
openssl rsa -in private.pem -modulus -noout | cut -d'=' -f2 | xxd -r -p > pubkey.bin

# Sign Kernel
openssl dgst -sha256 -sign private.pem -out Kernel.exe.mui Kernel.exe

# Inject the 256-byte public key into src/boot/boot.pas (the declaration must keep
# its trailing { INJECT_PUBKEY } marker; Pascal hex literals use $, not 0x).
python3 - <<'PY'
import sys, re
try:
    b = open('pubkey.bin','rb').read()
except FileNotFoundError:
    print("pubkey.bin not found", file=sys.stderr); sys.exit(1)
if len(b) < 256:
    print("[!] LOI FATAL: pubkey.bin bi thieu byte! Xoa private.pem va build lai!", file=sys.stderr)
    sys.exit(1)
b = b[-256:]
fmt = ', '.join('${:02X}'.format(x) for x in b)
new = f"Boot_PublicKeyN: array[0..255] of Byte = ( {fmt} ); {{ INJECT_PUBKEY }}"
s = open('src/boot/boot.pas','r',encoding='utf-8').read()

pattern = r'Boot_PublicKeyN\s*:\s*array\s*\[\s*0\s*\.\.\s*255\s*\]\s*of\s*Byte\s*=\s*\([\s\S]*?\)\s*;\s*\{\s*INJECT_PUBKEY\s*\}'
s2, n = re.subn(pattern, lambda m: new, s, flags=re.S)
if n == 0:
    print("Failed to inject public key: pattern not found in src/boot/boot.pas", file=sys.stderr); sys.exit(1)
open('src/boot/boot.pas','w',encoding='utf-8').write(s2)
print("[+] Public Key injected successfully into Bootloader Source!")
PY

# Build Bootloader: Pascal + NASM, linked by lld as a UEFI application.
echo "[2/4] Dang build Loader (Stub)..."
./compile_boot.sh
mkdir -p efi/boot
"$LLD" -subsystem:efi_application -entry:NekkoBoot \
    -out:"efi/boot/bootx64.efi" boot_io.obj build/boot.o

# =========================================================================
# [AUTH DB] Sinh PASSWD + SUDOERS truoc khi dong dia.
# Hai file nay chua password hash nen duoc .gitignore -> clone sach khong co.
# build.sh ben duoi se mcopy chung vao ::/ETC, thieu la build fail (set -e).
# File da ton tai thi GIU NGUYEN de khong lam doi mat khau dang chay.
# =========================================================================
echo "[2.5/4] Generating login database (passwd, sudoers)..."
python3 scripts/gen_auth.py

# Create disk image and populate (as in build.bat)
echo "[3/4] Dang che tao o cung Vat Ly Ao (hdd.img) ..."
rm -f hdd.img
dd if=/dev/zero of=hdd.img bs=1024 count=8208 status=none # Lowest common size for UEFI boot (8MB)
mkfs.fat -F 16 hdd.img

mmd -i hdd.img ::/EFI
mmd -i hdd.img ::/EFI/BOOT
mmd -i hdd.img ::/ETC
mmd -i hdd.img ::/HOME

mcopy -i hdd.img passwd ::/ETC/PASSWD
mcopy -i hdd.img sudoers ::/ETC/SUDOERS
mcopy -i hdd.img efi/boot/bootx64.efi ::/EFI/BOOT/
mcopy -i hdd.img Kernel.exe ::/
mcopy -i hdd.img Kernel.exe.mui ::/
mcopy -i hdd.img acpi.exe ::/
mcopy -i hdd.img ATA.exe ::/
mcopy -i hdd.img FAT16.exe ::/
mcopy -i hdd.img Shell.exe ::/
mcopy -i hdd.img SysLogon.exe ::/
mcopy -i hdd.img dsrv.exe ::/
mcopy -i hdd.img top.exe ::/
mcopy -i hdd.img stresstest.exe ::/
mcopy -i hdd.img Mouse.exe ::/
mcopy -i hdd.img memtest.exe ::/
mcopy -i hdd.img explorer.exe ::/
mcopy -i hdd.img smp.bin ::/

echo "[!] Disk Image created successfully! Syncing I/O..."
sync
sleep 1

# The build got this far, so the staged artifacts can go for good.
trap - ERR
rm -rf "$BUILD_BAK"

rm -rf hdd_img && mkdir -p hdd_img
cp hdd.img ./hdd_img
# qemu-system-x86_64 -machine q35 -smp 2 -device piix3-ide,id=ide -drive file=hdd.img,format=raw,if=none,id=drv0 -device ide-hd,bus=ide.0,drive=drv0 -bios OVMF_X64.fd -net nic -net user -m 4G -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" -serial stdio