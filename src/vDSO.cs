// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

public static unsafe class vDSO
{
    public static ulong PhysPage;
    public static ulong* Table;
    public static byte* Code;
    public static int FuncIndex;
    
    // mov rax, <raxID>
    // int 0x80
    // ret
    public static void AddSyscall(uint raxId) {
        Table[FuncIndex++] = 512 + (ulong)(Code - (PhysPage + 512)); // Offset from begin CODE region
        Code[0] = 0x48; Code[1] = 0xC7; Code[2] = 0xC0; *((uint*)(Code+3)) = raxId; 
        Code[7] = 0xCD; Code[8] = 0x80; Code[9] = 0xC3; 
        Code += 10;
    }

    public static void AddSyscallRbx(uint raxId) {
        Table[FuncIndex++] = 512 + (ulong)(Code - (PhysPage + 512)); // Offset from begin CODE region
        Code[0] = 0x53; Code[1] = 0x48; Code[2] = 0xC7; Code[3] = 0xC0; *((uint*)(Code+4)) = raxId;
        Code[8] = 0x48; Code[9] = 0x89; Code[10] = 0xCB; Code[11] = 0xCD; Code[12] = 0x80;
        Code[13] = 0x5B; Code[14] = 0xC3; 
        Code += 15;
    }

    public static void AddSyscallWithRbxReturn(uint raxId) {
        Table[FuncIndex++] = 512 + (ulong)(Code - (PhysPage + 512));
        // RCX = Target PID, RDX = Num Pages, R8 = Con trỏ lưu Target_VAddr
        
        // ==========================================================
        // [FIX CHÍ MẠNG] XÀI STACKALLOC ĐỂ TRÁNH GỌI GC TRONG BAREMETAL!
        // Mảng này gồm chính xác 17 bytes Assembly!
        // ==========================================================
        byte* asm = stackalloc byte[17] {
            0x41, 0x54, // push r12
            0x48, 0xC7, 0xC0, (byte)(raxId & 0xFF), (byte)((raxId >> 8) & 0xFF), 0x00, 0x00, // mov rax, 101
            0xCD, 0x80, // int 0x80 
            0x49, 0x89, 0x18, // mov [r8], rbx
            0x41, 0x5C, // pop r12
            0xC3 // ret
        };
        
        for (int i = 0; i < 17; i++) {
            Code[i] = asm[i];
        }
        Code += 17;
    }

    public static void Init()
    {
        PhysPage = (ulong)PMM.AllocatePage();
        LibC.MemSet((byte*)PhysPage, 0, 4096); // [FIX] ZERO-FILL CHỐNG RÁC REBOOT!
        Table = (ulong*)PhysPage;              // Split to two section: Section 1: Table
        Code = (byte*)(PhysPage + 512);        // Section 2: Code
        FuncIndex = 0;
        
        AddSyscall(1); // 1
        AddSyscall(0); // 2
        AddSyscall(5); // 3
        AddSyscall(6); // 4
        AddSyscall(7); // 5
        AddSyscall(8); // 6
        AddSyscall(99); // 7
        AddSyscall(4); // 8
        AddSyscall(88); // 9
        AddSyscallRbx(90); // 10
        AddSyscallRbx(91); // 11
        AddSyscall(89); // 12
        AddSyscall(98); // 13
        AddSyscall(100); // 14
        AddSyscallRbx(92); // 15
        AddSyscallRbx(93); // 16
        AddSyscall(10); // 17
        AddSyscall(3); // 18
        AddSyscall(97); // 19
        AddSyscall(96); // 20
        AddSyscall(11); // 21
        AddSyscall(12); // 22
        AddSyscall(13); // 23
        AddSyscall(14); // 24
        AddSyscall(399); // 25

        // index = number - 1
        
        // ==========================================================
        // [VŨ KHÍ MỚI] NẠP ĐẠN SYSCALL 50 & 51 VÀO VDSO!
        // Lưu ý: Cần kiểm tra xem 25 cái ở trên nó chiếm đến index số mấy rồi!
        // ==========================================================
        AddSyscall(50); // Slot 25
        AddSyscall(51); // Slot 26
        
        AddSyscallWithRbxReturn(101); // Slot 27

        AddSyscall(52); // [VŨ KHÍ MỚI] Slot 28: CỔNG BẺ LÁI TERMINAL!

        // Table doesn't contains Syscall ID, but contains offset point to that Syscall ID
        Table[FuncIndex++] = 512 + (ulong)(Code - (PhysPage + 512));

        // Stub 1 (AppInByte):
        // 66 8B D1:        mov dx, cx
        // 48 31 C0:        xor rax, rax
        // EC:              in al, dx
        // C3:              ret
        Code[0]=0x66;
        Code[1]=0x8B;
        Code[2]=0xD1;
        Code[3]=0x48;
        Code[4]=0x31;
        Code[5]=0xC0;
        Code[6]=0xEC;
        Code[7]=0xC3;
        Code += 8;

        // Stub 2:
        // 88 D0:       mov al, dl
        // 66 8B D1:    mov dx, cx
        // EE:          out dx, al
        // C3:          ret
        Table[FuncIndex++] = 512 + (ulong)(Code - (PhysPage + 512));
        Code[0]=0x88;
        Code[1]=0xD0;
        Code[2]=0x66;
        Code[3]=0x8B;
        Code[4]=0xD1;
        Code[5]=0xEE;
        Code[6]=0xC3;
        Code += 7;

        Table[FuncIndex++] = 512 + (ulong)(Code - (PhysPage + 512));
        Code[0]=0x66; Code[1]=0x8B; Code[2]=0xD1; Code[3]=0x48; Code[4]=0x31; Code[5]=0xC0; Code[6]=0x66; Code[7]=0xED; Code[8]=0xC3; Code += 9;

        Table[FuncIndex++] = 512 + (ulong)(Code - (PhysPage + 512));
        Code[0]=0x66; Code[1]=0x8B; Code[2]=0xC2; Code[3]=0x66; Code[4]=0x8B; Code[5]=0xD1; Code[6]=0x66; Code[7]=0xEF; Code[8]=0xC3; Code += 9;

        Table[FuncIndex++] = 512 + (ulong)(Code - (PhysPage + 512));
        Code[0]=0x89; Code[1]=0xD0; Code[2]=0x66; Code[3]=0x8B; Code[4]=0xD1; Code[5]=0xEF; Code[6]=0xC3; Code += 7;

        // ==========================================================
        // [FIX RACE CONDITION ATA/SMP] Slot 34 & 35: KHÓA PHẦN CỨNG ATA DÙNG CHUNG!
        // Cho phép ATA.EXE (Ring 3) và Kernel (Ring 0) loại trừ lẫn nhau khi
        // đụng vào chung cổng IDE 0x1F0-0x1F7, chặn đứng data race gây GPF ngẫu nhiên.
        // ==========================================================
        AddSyscall(60); // Slot 34: SyscallAcquireAtaHw
        AddSyscall(61); // Slot 35: SyscallReleaseAtaHw

        // [SUDO] Slot 36: SyscallSudoRun (case 94) - RCX/RDX truyền thẳng qua,
        // không cần stub đặc biệt (giống AddSyscall(88)).
        AddSyscall(94); // Slot 36: SyscallSudoRun

        Terminal.SetColor(0x00FF00FF);
        fixed(char* m = "[+] vDSO Gateway forged in RAM! Absolute KASLR Ready.\n\0") Terminal.Print(m);
    }
}