set -e

# Kill qemu if running to release hdd.img lock
pkill -f qemu-system-x86_64 || true
sleep 1

# Clean up
rm -f *.exe *.efi *.obj *.bin *.map hdd.img Kernel.exe.mui pubkey.bin
rm -rf efi/boot *.pdb *.lib
mkdir -p efi/boot

echo "[1.5/4] Dang build Kernel (Vi vua) & Apps Ring 3 truoc..."

nasm -f win64 src/Hardware.asm -o Hardware.obj
nasm -f win64 src/boot_io.asm -o boot_io.obj
nasm -f win64 src/stresstest_asm.asm -o stresstest_asm.obj
# nasm -f bin src/app.asm -o app.bin
nasm -f bin src/smp_x86.asm -o smp.bin
# nasm -f win64 src/app_syscall.asm -o app_syscall.obj

BF="bflat"

# Build Kernel + apps (no-pie, deterministic, map files)
$BF build src/Kernel.cs src/Syscall.cs src/IDT.cs src/ISR.cs src/RTC.cs src/PCI.cs src/Heap.cs src/Thread.cs src/IPC.cs src/KeyboardDriver.cs src/LibC.cs src/VMM.cs src/Terminal.cs src/PMM.cs src/IO.cs src/PIC.cs src/PIT.cs src/InterruptHandlers.cs src/ATA.cs src/FAT16.cs src/GlobalUsings.cs src/System.Runtime.InteropServices.cs src/System.Runtime.CompilerServices.cs src/PELoader.cs src/StrandScheduler.cs src/GDT.cs src/PRNG.cs src/Power.cs src/APIC.cs src/SMP.cs src/Spinlock.cs src/IOAPIC.cs src/vDSO.cs src/Serial.cs src/MouseDriver.cs src/NekkoInt.cs src/KernCrypto.cs -Ot --no-pie --deterministic --map maps/Kernel.map --os windows --arch x64 --stdlib zero -o Kernel.exe --ldflags "-export:KernelMain Hardware.obj"

$BF build src/ATA_Driver.cs src/API.cs -Ot --no-pie --deterministic --map maps/ATA_Driver.map --os windows --arch x64 --stdlib zero -o ATA.exe --ldflags "-export:AppMain"
$BF build src/FAT16_Driver.cs src/API.cs -Ot --no-pie --deterministic --map maps/FAT16_Driver.map --os windows --arch x64 --stdlib zero -o FAT16.exe --ldflags "-export:AppMain"
$BF build src/acpi.cs src/API.cs -Ot --no-pie --deterministic --map maps/ACPI.map --os windows --arch x64 --stdlib zero -o acpi.exe --ldflags "-export:AppMain"
$BF build src/Shell.cs src/API.cs -Ot --no-pie --deterministic --map maps/Shell.map --os windows --arch x64 --stdlib zero -o Shell.exe --ldflags "-export:AppMain"
$BF build src/Login.cs src/Crypto.cs src/API.cs -Ot --no-pie --deterministic --map maps/SysLogon.map --os windows --arch x64 --stdlib zero -o SysLogon.exe --ldflags "-export:AppMain"
$BF build src/top.cs src/API.cs -Ot --no-pie --deterministic --map maps/NekkoTop.map --os windows --arch x64 --stdlib zero -o top.exe --ldflags "-export:AppMain"
$BF build src/stresstest.cs src/API.cs src/ThrowHelpers.cs -Ot --no-pie --deterministic --map maps/NekkoStressTest.map --os windows --arch x64 --stdlib zero -o stresstest.exe --ldflags "-export:AppMain stresstest_asm.obj"

# Additional userland apps from build.bat
$BF build src/dsrv.cs src/API.cs -Ot --no-pie --deterministic --map maps/dsrv.map --os windows --arch x64 --stdlib zero -o dsrv.exe --ldflags "-export:AppMain"
$BF build src/Mouse.cs src/API.cs -Ot --no-pie --deterministic --map maps/Mouse.map --os windows --arch x64 --stdlib zero -o Mouse.exe --ldflags "-export:AppMain"
$BF build src/explorer.cs src/API.cs -Ot --no-pie --deterministic --map maps/explorer.map --os windows --arch x64 --stdlib zero -o explorer.exe --ldflags "-export:AppMain"

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

# Inject 256-byte public key into src/Boot.cs (must contain marker /* INJECT_PUBKEY */)
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
fmt = ', '.join('0x{:02X}'.format(x) for x in b)
new = f"byte* publicKeyN = stackalloc byte[256] {{ {fmt} }}; /* INJECT_PUBKEY */"
s = open('src/Boot.cs','r',encoding='utf-8').read()

# Use a more flexible regex to match existing declaration + marker (handles whitespace / large initializer)
pattern = r'byte\*\s*publicKeyN\s*=\s*stackalloc\s*byte\s*\[\s*256\s*\][\s\S]*?/\*\s*INJECT_PUBKEY\s*\*/'
s2, n = re.subn(pattern, new, s, flags=re.S)
if n == 0:
    print("Failed to inject public key: pattern not found in src/Boot.cs", file=sys.stderr); sys.exit(1)
open('src/Boot.cs','w',encoding='utf-8').write(s2)
print("[+] Public Key injected successfully into Bootloader Source!")
PY

# Build Bootloader (stub)
echo "[2/4] Dang build Loader (Stub)..."
$BF build src/Boot.cs -Os --map maps/bootx64.map --os uefi --stdlib zero -o "efi/boot/bootx64.efi" --ldflags "-entry:NekkoBoot boot_io.obj"

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
mcopy -i hdd.img explorer.exe ::/
mcopy -i hdd.img smp.bin ::/

echo "[!] Disk Image created successfully! Syncing I/O..."
sync
sleep 1

rm -rf hdd_img && mkdir -p hdd_img
cp hdd.img ./hdd_img
# qemu-system-x86_64 -machine q35 -smp 2 -device piix3-ide,id=ide -drive file=hdd.img,format=raw,if=none,id=drv0 -device ide-hd,bus=ide.0,drive=drv0 -bios OVMF_X64.fd -net nic -net user -m 4G -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" -serial stdio