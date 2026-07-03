echo [4/4] Build xong! Chay QEMU...

:: THAY ĐỔI CỰC LỚN: Ném thẳng hdd.img vào QEMU!
"C:\Program Files\qemu\qemu-system-x86_64" -m 64M -machine q35 -smp 2 -device piix3-ide,id=ide -drive file=hdd.img,format=raw,if=none,id=drv0 -device ide-hd,bus=ide.0,drive=drv0 -bios OVMF_X64.fd -net nic -net user -m 4G -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" -serial stdio -d int,cpu_reset -D qemu.log