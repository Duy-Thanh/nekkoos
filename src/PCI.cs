// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel.Driver;

// ==========================================================
// MODULE: BỘ QUÉT TẦN SỐ PHẦN CỨNG (PCI BUS ENUMERATOR)
// DATE: TƯƠNG LAI CỦA NEKKO OS - KỶ LUẬT THÉP BẤT HOẠI
// ==========================================================
public static unsafe class PCI
{
    [DllImport("*", EntryPoint = "Out32")] public static extern void Out32(ushort port, uint value);
    [DllImport("*", EntryPoint = "In32")] public static extern uint In32(ushort port);

    // ==========================================================
    // [VŨ KHÍ MỚI] Ổ KHÓA GIAO TIẾP PCI (PCI BUS MUTEX)
    // Đảm bảo thao tác Ghi Địa Chỉ -> Đọc Dữ Liệu không bị Đa Lõi bóp méo!
    // ==========================================================
    public static Spinlock PciLock = new Spinlock();

    // Đọc 1 thanh ghi 32-bit từ thiết bị PCI
    public static uint ConfigRead(ushort bus, ushort slot, ushort func, byte offset)
    {
        // Kiểm tra xem bus có nằm trong phạm vi hợp lệ không
        if (bus > 255) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid PCI bus number!\n\0") Terminal.Print(err);
            return 0;
        }
        
        // Kiểm tra xem slot có nằm trong phạm vi hợp lệ không
        if (slot > 31) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid PCI slot number!\n\0") Terminal.Print(err);
            return 0;
        }
        
        // Kiểm tra xem func có nằm trong phạm vi hợp lệ không
        if (func > 7) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid PCI function number!\n\0") Terminal.Print(err);
            return 0;
        }
        
        // Kiểm tra xem offset có nằm trong phạm vi hợp lệ không
        if (offset > 0xFF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid PCI offset!\n\0") Terminal.Print(err);
            return 0;
        }

        uint lbus  = (uint)bus;
        uint lslot = (uint)slot;
        uint lfunc = (uint)func;
        
        // Công thức tính địa chỉ ép buộc của Intel (Bit 31 luôn bật)
        uint address = (uint)((lbus << 16) | (lslot << 11) | (lfunc << 8) | (offset & 0xFC) | 0x80000000);
        
        // [THIẾT QUÂN LUẬT] KHÓA MÕM TẤT CẢ CÁC LÕI KHÁC!
        bool irq = PciLock.AcquireSafe(); 
        
        Out32(0xCF8, address);
        uint data = In32(0xCFC);
        
        PciLock.ReleaseSafe(irq); // [MỞ KHÓA]
        
        return data;
    }

    public static void ScanBus()
    {
        Terminal.SetColor(0x00FF00FF); 
        fixed (char* msg = "[*] Scanning PCI Bus for attached hardware...\n\0") Terminal.Print(msg);
        Terminal.SetColor(0x00FFFFFF); 
        
        int count = 0;

        for (ushort bus = 0; bus < 256; bus++)
        {
            // Kiểm tra xem bus có hợp lệ không
            if (bus > 255) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid PCI bus number!\n\0") Terminal.Print(err);
                break;
            }

            for (ushort slot = 0; slot < 32; slot++)
            {
                // Đọc thanh ghi đầu tiên (Offset 0 chứa Vendor ID & Device ID)
                uint reg0 = ConfigRead(bus, slot, 0, 0);
                ushort vendor = (ushort)(reg0 & 0xFFFF);
                
                // Nếu Vendor ID != 0xFFFF nghĩa là có thiết bị cắm ở Slot này!
                if (vendor != 0xFFFF) 
                {
                    // Kiểm tra xem vendor có hợp lệ không
                    if (vendor == 0x0000 || vendor == 0xFFFF) {
                        Terminal.SetColor(0x00FF0000);
                        fixed (char* err = "[!] FATAL: Invalid PCI vendor ID!\n\0") Terminal.Print(err);
                        continue;
                    }

                    ushort device = (ushort)(reg0 >> 16);

                    // Kiểm tra xem device có hợp lệ không
                    if (device == 0x0000 || device == 0xFFFF) {
                        Terminal.SetColor(0x00FF0000);
                        fixed (char* err = "[!] FATAL: Invalid PCI device ID!\n\0") Terminal.Print(err);
                        continue;
                    }
                    
                    // Đọc thanh ghi số 8 (Chứa Class Code để biết nó là GPU, Network, hay Ổ cứng)
                    uint reg8 = ConfigRead(bus, slot, 0, 0x08);
                    byte classCode = (byte)(reg8 >> 24);

                    // Kiểm tra xem classCode có hợp lệ không
                    if (classCode == 0x00 || classCode > 0xFF) {
                        Terminal.SetColor(0x00FF0000);
                        fixed (char* err = "[!] FATAL: Invalid PCI class code!\n\0") Terminal.Print(err);
                        continue;
                    }
                    
                    // IN RA MÀN HÌNH THEO STYLE HACKER
                    fixed (char* m1 = "B:\0") Terminal.Print(m1);
                    Terminal.PrintHex(bus);
                    fixed (char* m2 = " S:\0") Terminal.Print(m2);
                    Terminal.PrintHex(slot);
                    
                    Terminal.SetColor(0x00FFFF00); // Vàng cho ID
                    fixed (char* m3 = " | Ven: \0") Terminal.Print(m3);
                    Terminal.PrintHex(vendor);
                    fixed (char* m4 = " Dev: \0") Terminal.Print(m4);
                    Terminal.PrintHex(device);
                    
                    Terminal.SetColor(0x0000FFFF); // Xanh lơ cho Class
                    fixed (char* m5 = " | Class: \0") Terminal.Print(m5);
                    Terminal.PrintHex(classCode);
                    
                    fixed (char* nl = "\n\0") Terminal.Print(nl);
                    Terminal.SetColor(0x00FFFFFF); // Trả lại màu trắng
                    
                    count++;
                }
            }
        }
        
        Terminal.SetColor(0x0000FF00); // Xanh lá
        fixed (char* mf = "[+] Total PCI devices found: \0") Terminal.Print(mf);
        Terminal.PrintHex((ulong)count);
        fixed (char* nlf = "\n\0") Terminal.Print(nlf);
    }
}