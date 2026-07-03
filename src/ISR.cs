using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// ==========================================================
// MODULE: LÒ RÈN VỎ BỌC NGẮT - BẢN THÁNH CHỈ
// ==========================================================
public static unsafe class ISRBuilder
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN PHẦN CỨNG 
    // Dùng để chốt sổ mã máy vừa đúc xong!
    // ==========================================================
    [DllImport("*", EntryPoint = "StoreFence")] public static extern void StoreFence();

    public static void* CreateWrapper(void* csharpHandler)
    {
        byte* stub = (byte*)PMM.AllocatePage();
        if (stub == null) return null;

        ulong stubPhys = (ulong)stub;
        VMM.MapPage(stubPhys, stubPhys, 0x03);

        int i = 0;

        // 1. Lưu các thanh ghi của Caller (Scratch Registers)
        stub[i++] = 0x50; // push rax
        stub[i++] = 0x51; // push rcx
        stub[i++] = 0x52; // push rdx
        stub[i++] = 0x41; stub[i++] = 0x50; // push r8
        stub[i++] = 0x41; stub[i++] = 0x51; // push r9
        stub[i++] = 0x41; stub[i++] = 0x52; // push r10
        stub[i++] = 0x41; stub[i++] = 0x53; // push r11

        // 2. Lưu giữ RSP gốc để khôi phục, tránh phụ thuộc rbp hên xui
        stub[i++] = 0x55; // push rbp
        stub[i++] = 0x48; stub[i++] = 0x89; stub[i++] = 0xE5; // mov rbp, rsp

        // 3. CĂN CHỈNH STACK CHUẨN X64 MICROSOFT ABI (16-BYTE ALIGNMENT)
        stub[i++] = 0x48; stub[i++] = 0x83; stub[i++] = 0xE4; stub[i++] = 0xF0; // and rsp, -16
        
        // 4. CẤP PHÁT SHADOW SPACE CHUẨN (32 BYTES = 0x20)
        stub[i++] = 0x48; stub[i++] = 0x83; stub[i++] = 0xEC; stub[i++] = 0x20; // sub rsp, 0x20 

        stub[i++] = 0xFC; // cld

        // 5. Gọi hàm C#
        stub[i++] = 0x48; stub[i++] = 0xB8; // mov rax, csharpHandler
        ulong addr = (ulong)csharpHandler;
        stub[i++] = (byte)(addr & 0xFF); stub[i++] = (byte)((addr >> 8) & 0xFF);
        stub[i++] = (byte)((addr >> 16) & 0xFF); stub[i++] = (byte)((addr >> 24) & 0xFF);
        stub[i++] = (byte)((addr >> 32) & 0xFF); stub[i++] = (byte)((addr >> 40) & 0xFF);
        stub[i++] = (byte)((addr >> 48) & 0xFF); stub[i++] = (byte)((addr >> 56) & 0xFF);
        stub[i++] = 0xFF; stub[i++] = 0xD0; // call rax

        // 6. KHÔI PHỤC STACK TUYỆT ĐỐI KHÔNG LỆCH 1 BIT
        stub[i++] = 0x48; stub[i++] = 0x89; stub[i++] = 0xEC; // mov rsp, rbp
        stub[i++] = 0x5D; // pop rbp

        // 7. Pop các thanh ghi ngược lại chuẩn quy trình
        stub[i++] = 0x41; stub[i++] = 0x5B; // pop r11
        stub[i++] = 0x41; stub[i++] = 0x5A; // pop r10
        stub[i++] = 0x41; stub[i++] = 0x59; // pop r9
        stub[i++] = 0x41; stub[i++] = 0x58; // pop r8
        stub[i++] = 0x5A; // pop rdx
        stub[i++] = 0x59; // pop rcx
        stub[i++] = 0x58; // pop rax

        // 8. Trở về thế giới thực
        stub[i++] = 0x48; stub[i++] = 0xCF; // iretq

        StoreFence();
        return stub;
    }
}