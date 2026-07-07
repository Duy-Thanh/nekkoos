echo [4/4] Build xong! Chay QEMU...

# THAY ĐỔI CỰC LỚN: Ném thẳng hdd.img vào QEMU!
#qemu-system-x86_64 -machine q35 -smp 2 -device piix3-ide,id=ide -drive file=hdd.img,format=raw,if=none,id=drv0 -device ide-hd,bus=ide.0,drive=drv0 -bios OVMF_X64.fd -net nic -net user -m 4G -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" -serial stdio -d cpu_reset,int,guest_errors -D qemu_airtight.log -no-reboot -no-shutdown -s -S

# Turn on SMM
qemu-system-x86_64 -accel kvm -machine q35,smm=on -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1 -smp 2 -device piix3-ide,id=ide -drive file=hdd.img,format=raw,if=none,id=drv0 -device ide-hd,bus=ide.0,drive=drv0 -bios OVMF_X64.fd -net nic -net user -m 4G -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" -serial stdio