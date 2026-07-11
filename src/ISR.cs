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

    // ==========================================================
    // [FIX CRITICAL] Wrapper cho exceptions KHÔNG CÓ error code
    // CPU không push error code → phải push dummy 0 để stack alignment!
    // ==========================================================
    public static void* CreateWrapperWithoutErrorCode(void* csharpHandler)
    {
        byte* stub = (byte*)PMM.AllocatePage();
        if (stub == null) return null;

        ulong stubPhys = (ulong)stub;
        VMM.MapPage(stubPhys, stubPhys, 0x03);

        int i = 0;

        // 0. PUSH DUMMY ERROR CODE = 0 (để stack giống exceptions có error code!)
        stub[i++] = 0x6A; stub[i++] = 0x00; // push 0

        // 1. Lưu các thanh ghi của Caller (Scratch Registers)
        stub[i++] = 0x50; // push rax
        stub[i++] = 0x51; // push rcx
        stub[i++] = 0x52; // push rdx
        stub[i++] = 0x53; // push rbx
        stub[i++] = 0x41; stub[i++] = 0x50; // push r8
        stub[i++] = 0x41; stub[i++] = 0x51; // push r9
        stub[i++] = 0x41; stub[i++] = 0x52; // push r10
        stub[i++] = 0x41; stub[i++] = 0x53; // push r11

        // 2. Lưu giữ RSP gốc
        stub[i++] = 0x55; // push rbp
        stub[i++] = 0x48; stub[i++] = 0x89; stub[i++] = 0xE5; // mov rbp, rsp

        // 3. Căn chỉnh stack 16-byte
        stub[i++] = 0x48; stub[i++] = 0x83; stub[i++] = 0xE4; stub[i++] = 0xF0; // and rsp, -16

        // 4. Shadow space
        stub[i++] = 0x48; stub[i++] = 0x83; stub[i++] = 0xEC; stub[i++] = 0x20; // sub rsp, 0x20

        stub[i++] = 0xFC; // cld

        // 5. Pass RSP (pointer to RegisterContext) as RCX (1st arg)
        stub[i++] = 0x48; stub[i++] = 0x89; stub[i++] = 0xE9; // mov rcx, rbp

        // 6. Gọi hàm C#
        stub[i++] = 0x48; stub[i++] = 0xB8; // mov rax, csharpHandler
        ulong addr = (ulong)csharpHandler;
        stub[i++] = (byte)(addr & 0xFF); stub[i++] = (byte)((addr >> 8) & 0xFF);
        stub[i++] = (byte)((addr >> 16) & 0xFF); stub[i++] = (byte)((addr >> 24) & 0xFF);
        stub[i++] = (byte)((addr >> 32) & 0xFF); stub[i++] = (byte)((addr >> 40) & 0xFF);
        stub[i++] = (byte)((addr >> 48) & 0xFF); stub[i++] = (byte)((addr >> 56) & 0xFF);
        stub[i++] = 0xFF; stub[i++] = 0xD0; // call rax

        // 7. Khôi phục stack
        stub[i++] = 0x48; stub[i++] = 0x89; stub[i++] = 0xEC; // mov rsp, rbp
        stub[i++] = 0x5D; // pop rbp

        // 8. Pop registers
        stub[i++] = 0x41; stub[i++] = 0x5B; // pop r11
        stub[i++] = 0x41; stub[i++] = 0x5A; // pop r10
        stub[i++] = 0x41; stub[i++] = 0x59; // pop r9
        stub[i++] = 0x41; stub[i++] = 0x58; // pop r8
        stub[i++] = 0x5B; // pop rbx
        stub[i++] = 0x5A; // pop rdx
        stub[i++] = 0x59; // pop rcx
        stub[i++] = 0x58; // pop rax

        // 9. Pop dummy error code
        stub[i++] = 0x48; stub[i++] = 0x83; stub[i++] = 0xC4; stub[i++] = 0x08; // add rsp, 8

        // 10. IRETQ
        stub[i++] = 0x48; stub[i++] = 0xCF; // iretq

        StoreFence();
        return stub;
    }

    // ==========================================================
    // Wrapper cho exceptions CÓ error code (CPU đã push)
    // ==========================================================
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
        stub[i++] = 0x53; // push rbx
        stub[i++] = 0x41; stub[i++] = 0x50; // push r8
        stub[i++] = 0x41; stub[i++] = 0x51; // push r9
        stub[i++] = 0x41; stub[i++] = 0x52; // push r10
        stub[i++] = 0x41; stub[i++] = 0x53; // push r11

        // 2. Lưu giữ RSP gốc
        stub[i++] = 0x55; // push rbp
        stub[i++] = 0x48; stub[i++] = 0x89; stub[i++] = 0xE5; // mov rbp, rsp

        // 3. Căn chỉnh stack 16-byte
        stub[i++] = 0x48; stub[i++] = 0x83; stub[i++] = 0xE4; stub[i++] = 0xF0; // and rsp, -16

        // 4. Shadow space
        stub[i++] = 0x48; stub[i++] = 0x83; stub[i++] = 0xEC; stub[i++] = 0x20; // sub rsp, 0x20

        stub[i++] = 0xFC; // cld

        // 5. Pass RSP (pointer to RegisterContext) as RCX (1st arg)
        stub[i++] = 0x48; stub[i++] = 0x89; stub[i++] = 0xE9; // mov rcx, rbp

        // 6. Gọi hàm C#
        stub[i++] = 0x48; stub[i++] = 0xB8; // mov rax, csharpHandler
        ulong addr = (ulong)csharpHandler;
        stub[i++] = (byte)(addr & 0xFF); stub[i++] = (byte)((addr >> 8) & 0xFF);
        stub[i++] = (byte)((addr >> 16) & 0xFF); stub[i++] = (byte)((addr >> 24) & 0xFF);
        stub[i++] = (byte)((addr >> 32) & 0xFF); stub[i++] = (byte)((addr >> 40) & 0xFF);
        stub[i++] = (byte)((addr >> 48) & 0xFF); stub[i++] = (byte)((addr >> 56) & 0xFF);
        stub[i++] = 0xFF; stub[i++] = 0xD0; // call rax

        // 7. Khôi phục stack
        stub[i++] = 0x48; stub[i++] = 0x89; stub[i++] = 0xEC; // mov rsp, rbp
        stub[i++] = 0x5D; // pop rbp

        // 8. Pop registers
        stub[i++] = 0x41; stub[i++] = 0x5B; // pop r11
        stub[i++] = 0x41; stub[i++] = 0x5A; // pop r10
        stub[i++] = 0x41; stub[i++] = 0x59; // pop r9
        stub[i++] = 0x41; stub[i++] = 0x58; // pop r8
        stub[i++] = 0x5B; // pop rbx
        stub[i++] = 0x5A; // pop rdx
        stub[i++] = 0x59; // pop rcx
        stub[i++] = 0x58; // pop rax

        // 9. IRETQ (CPU sẽ tự pop error code từ stack)
        stub[i++] = 0x48; stub[i++] = 0xCF; // iretq

        StoreFence();
        return stub;
    }
}