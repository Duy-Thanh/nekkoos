@echo off
echo [1/4] [Windows] Cuop quyen Linker, Bypass zerolib...

:: ==========================================================
:: [BỌC THÉP 1] GIẾT QEMU NGAY TỪ ĐẦU ĐỂ NHẢ LOCK FILE hdd.img!
:: ==========================================================
taskkill /IM qemu-system-x86_64.exe /F >nul 2>nul
timeout /t 1 /nobreak >nul

del /f /s /q *.exe *.efi *.obj *.bin *.map
del /q hdd.img 2>nul

if not exist "efi\boot" mkdir "efi\boot"

echo [1.5/4] Dang build Kernel (Vi vua) ^& Apps Ring 3 truoc...

nasm -f win64 src\Hardware.asm -o Hardware.obj
nasm -f win64 src\boot\boot_io.asm -o boot_io.obj
nasm -f bin src\app.asm -o app.bin
nasm -f bin src\arch\x86_64\smp_x86.asm -o smp.bin
nasm -f win64 src\app_syscall.asm -o app_syscall.obj

:: ==========================================================
:: [BỌC THÉP 2] KHÔNG PIE, CHẠY DETERMINISTIC VÀ XUẤT MAP FILE!
:: ==========================================================
"D:\bflat\bflat" build src\kernel\Kernel.cs src\kernel\Syscall.cs src\arch\Arch.cs src\arch\x86_64\IDT.cs src\arch\x86_64\ISR.cs src\kernel\RTC.cs src\drivers\x86-legacy\PCI.cs src\kernel\Heap.cs src\kernel\Thread.cs src\kernel\IPC.cs src\drivers\x86-legacy\KeyboardDriver.cs src\kernel\LibC.cs src\arch\x86_64\VMM.cs src\arch\Arch.cs src\arch\x86_64\ContextLayout.cs src\boot\BootContract.cs src\arch\x86_64\PlatformBootstrap.cs src\kernel\Terminal.cs src\kernel\PMM.cs src\kernel\IO.cs src\arch\x86_64\PIC.cs src\arch\x86_64\PIT.cs src\arch\x86_64\InterruptHandlers.cs src\kernel\ATA.cs src\kernel\FAT16.cs src\kernel\GlobalUsings.cs src\kernel\System.Runtime.InteropServices.cs src\kernel\System.Runtime.CompilerServices.cs src\kernel\PELoader.cs src\kernel\StrandScheduler.cs src\arch\x86_64\GDT.cs src\kernel\PRNG.cs src\drivers\x86-legacy\Power.cs src\arch\x86_64\APIC.cs src\arch\x86_64\SMP.cs src\kernel\Spinlock.cs src\arch\x86_64\IOAPIC.cs src\arch\x86_64\vDSO.cs src\arch\x86_64\HardwareChecks.cs src\drivers\x86-legacy\Serial.cs src\drivers\x86-legacy\MouseDriver.cs --no-pie --deterministic --map maps\Kernel.map --os windows --arch x64 --stdlib zero -o Kernel.exe --ldflags "-export:KernelMain Hardware.obj"

"D:\bflat\bflat" build src\apps\ATA_Driver.cs src\apps\API.cs --no-pie --deterministic --map maps\ATA_Driver.map --os windows --arch x64 --stdlib zero -o ATA.exe --ldflags "-export:AppMain"
"D:\bflat\bflat" build src\apps\FAT16_Driver.cs src\apps\API.cs --no-pie --deterministic --map maps\FAT16_Driver.map --os windows --arch x64 --stdlib zero -o FAT16.exe --ldflags "-export:AppMain"
"D:\bflat\bflat" build src\apps\acpi.cs src\apps\API.cs --no-pie --deterministic --map maps\ACPI.map --os windows --arch x64 --stdlib zero -o acpi.exe --ldflags "-export:AppMain"
"D:\bflat\bflat" build src\apps\Shell.cs src\apps\API.cs --no-pie --deterministic --map maps\Shell.map --os windows --arch x64 --stdlib zero -o Shell.exe --ldflags "-export:AppMain"
"D:\bflat\bflat" build src\apps\Login.cs src\apps\API.cs --no-pie --deterministic --map maps\SysLogon.map --os windows --arch x64 --stdlib zero -o SysLogon.exe --ldflags "-export:AppMain"
"D:\bflat\bflat" build src\apps\top.cs src\apps\API.cs --no-pie --deterministic --map maps\NekkoTop.map --os windows --arch x64 --stdlib zero -o top.exe --ldflags "-export:AppMain"

:: Display Server
"D:\bflat\bflat" build src\apps\dsrv.cs src\apps\API.cs --no-pie --deterministic --map maps\dsrv.map --os windows --arch x64 --stdlib zero -o dsrv.exe --ldflags "-export:AppMain"

:: Mouse
"D:\bflat\bflat" build src\apps\Mouse.cs src\apps\API.cs --no-pie --deterministic --map maps\Mouse.map --os windows --arch x64 --stdlib zero -o Mouse.exe --ldflags "-export:AppMain"

:: Explorer
"D:\bflat\bflat" build src\apps\explorer.cs src\apps\API.cs --no-pie --deterministic --map maps\explorer.map --os windows --arch x64 --stdlib zero -o explorer.exe --ldflags "-export:AppMain"

if %errorlevel% neq 0 (
    echo [!] Bien dich that bai! Kiem tra lai Code nhe Dai ca!
    pause
    exit /b
)

:: ==========================================================
:: [BỌC THÉP 3] ĐỢI WINDOWS GHI XONG FILE XUỐNG ĐĨA RỒI MỚI CHECK
:: ==========================================================
echo [*] Waiting for NTFS to flush buffers...
timeout /t 2 /nobreak >nul

:: Kiểm tra file có bị rỗng hoặc quá nhỏ không (Kernel > 10KB)
for %%I in (Kernel.exe) do if %%~zI lss 10000 (
    echo [!] Lỗi cmnr: Kernel.exe kich thuoc qua nho! Build that bai!
    pause
    exit /b
)

:: ==========================================================
:: [BỌC THÉP 4] VŨ KHÍ TỐI THƯỢNG: QUÉT CHỮ KÝ KASLR BẰNG POWERSHELL!
:: ==========================================================
echo [*] Verifying KASLR Magic Signature in App binaries...
powershell -Command "$bytes = [System.IO.File]::ReadAllBytes('Shell.exe'); $found = $false; for($i=0; $i -lt $bytes.Length - 8; $i++) { if($bytes[$i] -eq 0xAD -and $bytes[$i+1] -eq 0x8B -and $bytes[$i+2] -eq 0xFE -and $bytes[$i+3] -eq 0xCA -and $bytes[$i+4] -eq 0xEF -and $bytes[$i+5] -eq 0xBE -and $bytes[$i+6] -eq 0x37 -and $bytes[$i+7] -eq 0x13) { $found = $true; break } }; if(-not $found) { Write-Host '[!!!] KASLR Signature (0x1337BEEFCAFE8BAD) NOT FOUND! Compiler optimized it away.' -ForegroundColor Red; exit 1 } else { Write-Host '[+] KASLR Signature is VALID! Proceeding...' -ForegroundColor Green }"
if %errorlevel% neq 0 (
    echo [!] Hủy đúc đĩa! Sửa code lại đi đại ca, mất chữ ký rồi!
    pause
    exit /b
)

:: ==========================================================
:: [VŨ KHÍ TỐI THƯỢNG] ĐÚC CHÌA KHÓA RSA-2048 VÀ KÝ KERNEL
:: ==========================================================
echo [*] Generating RSA-2048 Keys and Signing Kernel...

:: 1. Nếu đéo có Private Key thì mới rèn cái mới!
if not exist private.pem (
    echo [+] Private Key not found! Forging a new RSA-2048 Keypair...
    wsl openssl genrsa -out private.pem 2048
)

:: 2. ĐÃ LÔI CỔ RA NGOÀI! LUÔN LUÔN TRÍCH XUẤT MODULUS TỪ PRIVATE KEY RA PUBKEY.BIN!
:: Đéo xài file trung gian nữa, rút thẳng Hex bằng cờ -modulus!
wsl bash -c "openssl rsa -in private.pem -modulus -noout | cut -d'=' -f2 | xxd -r -p > pubkey.bin"

:: 3. Ký file Kernel
echo [*] Signing Kernel with Private Key...
wsl openssl dgst -sha256 -sign private.pem -out Kernel.exe.mui Kernel.exe

:: ==========================================================
:: BƠM PUBLIC KEY VÀO BOOTLOADER + CHỐT CHẶN KIỂM TRA ĐỘ DÀI
:: ==========================================================
echo [*] Injecting 256-byte Public Key into Boot.cs...
powershell -Command "$bytes = [System.IO.File]::ReadAllBytes('pubkey.bin'); if ($bytes.Length -lt 256) { Write-Host '[!] LOI FATAL: pubkey.bin bi thieu byte! Xoa private.pem va build lai!' -ForegroundColor Red; exit 1 }; if ($bytes.Length -gt 256) { $bytes = $bytes[-256..-1] }; $fmt = ($bytes | ForEach-Object { '0x{0:X2}' -f $_ }) -join ', '; $file = 'src\boot\Boot.cs'; $txt = [System.IO.File]::ReadAllText($file); $txt = $txt -replace 'byte\* publicKeyN = stackalloc byte\[256\].*?/\* INJECT_PUBKEY \*/', \"byte* publicKeyN = stackalloc byte[256] { $fmt }; /* INJECT_PUBKEY */\"; [System.IO.File]::WriteAllText($file, $txt);"
if %errorlevel% neq 0 (
    echo [!] Huy duc dia do loi Public Key!
    pause
    exit /b
)
echo [+] Public Key injected successfully into Bootloader Source!

:: ==========================================================
:: [BỌC THÉP 4.8] TIẾN HÀNH RÈN Ổ KHÓA (BOOTLOADER) VỚI HASH MỚI!
:: Đã dời xuống đây để bắt trọn cái Hash của Kernel!
:: ==========================================================
echo [2/4] Dang build Loader (Stub)...
"D:\bflat\bflat" build src\boot\Boot.cs -Os --map maps\bootx64.map --os uefi --stdlib zero -o "efi\boot\bootx64.efi" --ldflags "-entry:NekkoBoot boot_io.obj"

:: =========================================================================
:: [VŨ KHÍ TỐI THƯỢNG] TRIỆU HỒI WSL ĐỂ ĐÚC Ổ CỨNG TRÊN WINDOWS!
:: =========================================================================
echo [3/4] Dang che tao o cung Vat Ly Ao (hdd.img) bang WSL...

:: Gọi thẳng công cụ Linux để đúc đĩa
wsl dd if=/dev/zero of=hdd.img bs=1024 count=8208 status=none
wsl mkfs.fat -F 16 hdd.img

:: [BỌC THÉP 5] Ép WSL xả cache trước khi mcopy
wsl sync
wsl sleep 1

:: Tạo thư mục EFI và tọng các File vào bằng mtools qua WSL
wsl mmd -i hdd.img ::/EFI
wsl mmd -i hdd.img ::/EFI/BOOT
wsl mmd -i hdd.img ::/ETC
wsl mcopy -i hdd.img passwd ::/ETC/PASSWD
wsl mcopy -i hdd.img efi/boot/bootx64.efi ::/EFI/BOOT/
wsl mcopy -i hdd.img Kernel.exe ::/
wsl mcopy -i hdd.img Kernel.exe.mui ::/
wsl mcopy -i hdd.img acpi.exe ::/
wsl mcopy -i hdd.img ATA.exe ::/
wsl mcopy -i hdd.img FAT16.exe ::/
wsl mcopy -i hdd.img Shell.exe ::/
wsl mcopy -i hdd.img SysLogon.exe ::/
wsl mcopy -i hdd.img dsrv.exe ::/
wsl mcopy -i hdd.img top.exe ::/
wsl mcopy -i hdd.img Mouse.exe ::/
wsl mcopy -i hdd.img explorer.exe ::/
wsl mcopy -i hdd.img smp.bin ::/

:: ==========================================================
:: [BỌC THÉP 6] NUCLEAR SYNC - ĐẢM BẢO FILE VÀO ĐĨA 100% TRƯỚC KHI QEMU BOOT
:: ==========================================================
echo [*] Nuclear Syncing WSL to Windows...
wsl sync
wsl sleep 1
timeout /t 1 /nobreak >nul

echo [4/4] Build xong! Chay QEMU...

:: THAY ĐỔI CỰC LỚN: Ném thẳng hdd.img vào QEMU!
"C:\Program Files\qemu\qemu-system-x86_64" -m 64M -machine q35 -smp 2 -device piix3-ide,id=ide -drive file=hdd.img,format=raw,if=none,id=drv0 -device ide-hd,bus=ide.0,drive=drv0 -bios OVMF_X64.fd -net nic -net user -m 4G -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" -serial stdio -d int,cpu_reset -D qemu.log