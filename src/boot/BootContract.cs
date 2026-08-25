// =========================================================================
// NekkoOS - Boot Contract v1 (ABI giữa bootloader và kernel)
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: BootContract - hợp đồng bàn giao boot, ARCH-NEUTRAL.
//
// FILE NÀY LÀ ĐIỂM SONG HÀNH DUY NHẤT giữa hai phía:
//   - Bootloader: src/Boot.cs (EFI app -> efi/boot/bootx64.efi)
//   - Kernel:     src/Kernel.cs (KernelMain(NekkoBootInfo*))
// Trước đây struct bị NHÂN BẢN ở cả hai file - mỗi bên sửa một kiểu là
// ABI vỡ ngầm. Mọi thay đổi field phải làm ở đây và bump CONTRACT_VERSION.
//
// Quy ước bộ nhớ khi bàn giao: MemoryMap trỏ tới bản đồ UEFI còn nguyên,
// kernel tự scan tìm vùng free lớn nhất (xem PMM.Init); AcpiRsdp = địa
// chỉ vật lý RSDP 2.0 để ACPI daemon parse (\_S5, MADT, HPET, MCFG).
// =========================================================================

using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public unsafe struct NekkoBootInfo
{
    public ulong FrameBufferBase;
    public ulong FrameBufferSize;
    public uint HorizontalResolution;
    public uint VerticalResolution;
    public uint PixelsPerScanLine;
    public void* MemoryMap;
    public ulong MemoryMapSize;
    public ulong DescriptorSize;
    public ulong AcpiRsdp;
}
