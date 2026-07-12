echo [4/4] Build xong! Chay QEMU...

# THAY ĐỔI CỰC LỚN: Ném thẳng hdd.img vào QEMU!
#qemu-system-x86_64 -machine q35 -smp 2 -device piix3-ide,id=ide -drive file=hdd.img,format=raw,if=none,id=drv0 -device ide-hd,bus=ide.0,drive=drv0 -bios OVMF_X64.fd -net nic -net user -m 4G -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" -serial stdio -d cpu_reset,int,guest_errors -D qemu_airtight.log -no-reboot -no-shutdown -s -S

# Turn on SMM
# qemu-system-x86_64 -accel kvm -machine q35,smm=on -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1 -smp 2 -device piix3-ide,id=ide -drive file=hdd.img,format=raw,if=none,id=drv0 -device ide-hd,bus=ide.0,drive=drv0 -bios OVMF_X64.fd -net nic -net user -m 4G -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" -serial stdio
# qemu-system-x86_64 -accel tcg -machine q35,smm=on -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1 -smp 64 -device piix3-ide,id=ide -drive file=hdd.img,format=raw,if=none,id=drv0 -device ide-hd,bus=ide.0,drive=drv0 -bios OVMF_X64.fd -net nic -net user -m 4G -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" -serial stdio

qemu-system-x86_64 \
  -accel kvm \
  -machine q35,smm=on,nvdimm=on,acpi=on,kernel-irqchip=split,default-bus-bypass-iommu=on \
  -cpu host,migratable=off,+invtsc,+x2apic,+vmx \
  -smp 4,maxcpus=8,cores=4,threads=1,sockets=2 \
  -m 6G,slots=8,maxmem=32G \
  -object memory-backend-ram,id=mem0,size=3G \
  -object memory-backend-ram,id=mem1,size=3G \
  -numa node,nodeid=0,cpus=0-3,memdev=mem0 \
  -numa node,nodeid=1,cpus=4-7,memdev=mem1 \
  -object memory-backend-ram,id=nvmem0,size=1G \
  -device nvdimm,id=nv0,memdev=nvmem0,node=1 \
  -bios OVMF_X64.fd \
  -global ICH9-LPC.disable_s3=1 \
  -global ICH9-LPC.disable_s4=1 \
  -global hpet.timers=8 \
  -device pxb-pcie,id=pcie.1,bus_nr=32,numa_node=1 \
  -device intel-iommu,intremap=on,caching-mode=on,eim=on \
  -acpitable sig=TPM2,oem_id=NEKKO1,oem_table_id=FAKETPM1,data=acpi_dummy.bin \
  -device piix3-ide,id=ide,bus=pcie.0 \
  -drive file=hdd.img,format=raw,if=none,id=drv0 \
  -device ide-hd,bus=ide.0,drive=drv0 \
  -device i6300esb,id=watchdog0,bus=pcie.0 \
  -watchdog-action reset \
  -device e1000,netdev=net0,mac=52:54:00:12:34:56,bus=pcie.0 \
  -netdev user,id=net0 \
  -device AC97,bus=pcie.0 \
  -drive if=floppy,file=empty_floppy.img,format=raw,id=flop0,media=disk \
  -object memory-backend-ram,id=ivshmem_mmio,size=256M \
  -device ivshmem-plain,memdev=ivshmem_mmio,bus=pcie.0 \
  -fw_cfg name=opt/nekko_key,string="DUY_THANH_IS_THE_KING" \
  -serial stdio \
  -parallel file:parallel.log \
  -vga std \
  -d guest_errors,unimp \
  -trace "pci_*" \
  -rtc base=localtime,clock=vm,driftfix=none