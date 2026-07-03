all: build run

build:
	@echo "[Linux] Compiling C# to bare metal UEFI..."
	@mkdir -p efi/boot
	bflat build src/Boot.cs -os:uefi -o efi/boot/bootx64.efi

run:
	@echo "[Linux] Build done! Running QEMU..."
	# On Linux, OVMF is usually installed in the /usr/share/ directory
	qemu-system-x86_64 -bios /usr/share/OVMF/OVMF_CODE.fd -drive format=raw,file=fat:rw:.