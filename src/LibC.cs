using System.Runtime.InteropServices;
namespace NekkoOS.Kernel.Lib;

// ==========================================================
// MODULE: THƯ VIỆN CHUẨN LÕI (LIBC ZERO - BẢN BỌC THÉP TỐI CAO)
// ==========================================================
public static unsafe class LibC
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN TRÌNH BIÊN DỊCH
    // ==========================================================
    [DllImport("*", EntryPoint = "CompilerFence")] public static extern void CompilerFence();

    public static ulong HardwareTscOffset = 0;
    public static ulong RtcInterruptHandler_Ptr = 0;

    public static void MemCpy(void* dest, void* src, uint count)
    {
        // Kiểm tra xem dest và src có null không
        if (dest == null || src == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in MemCpy!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem count có hợp lệ không
        if (count == 0) return;
        if (count > 0x10000000) { // Giới hạn 256MB
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: MemCpy size too large!\n\0") Terminal.Print(err);
            return;
        }
        byte* d = (byte*)dest;
        byte* s = (byte*)src;
        ulong* d64 = (ulong*)dest;
        ulong* s64 = (ulong*)src;
        uint count64 = count / 8;
        for (uint i = 0; i < count64; i++) { d64[i] = s64[i]; }
        uint remainder = count % 8;
        for (uint i = count - remainder; i < count; i++) { d[i] = s[i]; }
    }

    public static void MemSet(byte* ptr, byte value, uint count)
    {
        // Kiểm tra xem ptr có null không
        if (ptr == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in MemSet!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem count có hợp lệ không
        if (count == 0) return;
        if (count > 0x10000000) { // Giới hạn 256MB
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: MemSet size too large!\n\0") Terminal.Print(err);
            return;
        }

        for (uint i = 0; i < count; i++) ptr[i] = value;
    }

    private static char ToLowerCase(char c)
    {
        if (c >= 'A' && c <= 'Z') return (char)(c + 32);
        return c;
    }

    public static bool StrCmp(char* str1, char* str2)
    {
        // Kiểm tra xem str1 và str2 có null không
        if (str1 == null || str2 == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in StrCmp!\n\0") Terminal.Print(err);
            return false;
        }
        
        int i = 0;
        while (str1[i] != '\0' && str2[i] != '\0') {
            if (ToLowerCase(str1[i]) != ToLowerCase(str2[i])) return false;
            i++;
        }
        return str1[i] == '\0' && str2[i] == '\0';
    }

    public static bool StrStartsWith(char* str, char* prefix)
    {
        // Kiểm tra xem str và prefix có null không
        if (str == null || prefix == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in StrStartsWith!\n\0") Terminal.Print(err);
            return false;
        }

        int i = 0;
        while (prefix[i] != '\0') {
            if (str[i] == '\0') return false; 
            if (ToLowerCase(str[i]) != ToLowerCase(prefix[i])) return false;
            i++;
        }
        return true;
    }

    public static void FormatFATName(char* input, byte* output)
    {
        // Kiểm tra xem input và output có null không
        if (input == null || output == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in FormatFATName!\n\0") Terminal.Print(err);
            return;
        }

        for (int i = 0; i < 11; i++) output[i] = (byte)' ';
        int inPos = 0, outPos = 0;
        while (input[inPos] != '\0' && input[inPos] != '.' && outPos < 8) {
            char c = input[inPos++];
            if (c >= 'a' && c <= 'z') c = (char)(c - 32); 
            output[outPos++] = (byte)c;
        }
        while (input[inPos] != '\0' && input[inPos] != '.') inPos++;
        if (input[inPos] == '.') {
            inPos++; outPos = 8;
            while (input[inPos] != '\0' && outPos < 11) {
                char c = input[inPos++];
                if (c >= 'a' && c <= 'z') c = (char)(c - 32);
                output[outPos++] = (byte)c;
            }
        }
    }

    private static ushort GetFwCfgSelector(char* name, int nameLen)
    {
        // Kiểm tra xem name có null không
        if (name == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in GetFwCfgSelector!\n\0") Terminal.Print(err);
            return 0;
        }
        
        // Kiểm tra xem nameLen có hợp lệ không
        if (nameLen < 0 || nameLen > 56) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid name length in GetFwCfgSelector!\n\0") Terminal.Print(err);
            return 0;
        }

        IO.Out16(0x510, 0x19); 
        uint count = ((uint)IO.In8(0x511) << 24) | ((uint)IO.In8(0x511) << 16) | ((uint)IO.In8(0x511) << 8) | IO.In8(0x511);
        
        // Kiểm tra xem count có hợp lệ không
        if (count > 1000) { // Giới hạn số lượng entry
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Too many entries in GetFwCfgSelector!\n\0") Terminal.Print(err);
            return 0;
        }
        
        for (uint i = 0; i < count; i++)
        {
            uint size = ((uint)IO.In8(0x511) << 24) | ((uint)IO.In8(0x511) << 16) | ((uint)IO.In8(0x511) << 8) | IO.In8(0x511);
            ushort select = (ushort)(((ushort)IO.In8(0x511) << 8) | IO.In8(0x511));
            ushort reserved = (ushort)(((ushort)IO.In8(0x511) << 8) | IO.In8(0x511));

            bool nameMatch = true;
            for (int j = 0; j < 56; j++) {
                byte b = IO.In8(0x511);
                char expected = (j < nameLen) ? name[j] : '\0';
                if (b != expected) nameMatch = false; 
            }
            if (nameMatch) return select; 
        }
        return 0; 
    }

    public static void CheckHardwareError()
    {
        HardwareTscOffset = 0;
        bool isGenuine = false;

        byte* encKey = stackalloc byte[21] {
            0xEE, 0xFF, 0xF3, 0xF5, 0xFE, 0xE2, 0xEB, 0xE4, 0xE2, 0xF5, 
            0xE3, 0xF9, 0xF5, 0xFE, 0xE2, 0xEF, 0xF5, 0xE1, 0xE3, 0xE4, 0xED
        };
        int keyLen = 21;

        char* secretKey = stackalloc char[22];
        for (int i = 0; i < keyLen; i++) { secretKey[i] = (char)(encKey[i] ^ 0xAA); }
        secretKey[keyLen] = '\0'; 

        byte* encFwName = stackalloc byte[13] {
            0xC5, 0xDA, 0xDE, 0x85, 0xC4, 0xCF, 0xC1, 0xC1, 0xC5, 0xF5, 0xC1, 0xCF, 0xD3
        };
        
        char* fwName = stackalloc char[14];
        for (int i = 0; i < 13; i++) { fwName[i] = (char)(encFwName[i] ^ 0xAA); }
        fwName[13] = '\0'; 

        ushort keySelector = GetFwCfgSelector(fwName, 13);

        if (keySelector != 0) 
        {
            IO.Out16(0x510, keySelector); 
            bool match = true;
            for (int i = 0; i < keyLen; i++) {
                byte b = IO.In8(0x511); 
                if (b != (byte)secretKey[i]) { match = false; break; }
            }
            if (match) isGenuine = true;
        }

        if (!isGenuine)
        {
            if (APIC.IsAwake) {
                APIC.Write(0x300, 0x000C4400); 
            }

            NekkoOS.Kernel.Scheduler.Ready = false;
            IO.Cli(); 

            Terminal.Clear(0x00000000); 

            byte* m1 = stackalloc byte[10] { 0x0D, 0x1E, 0x2B, 0x24, 0x31, 0x42, 0x5F, 0x68, 0x65, 0x76 };
            Terminal.PrintObfuscated(m1, 10);

            Terminal.SetColor(0x00FFFFFF);
            byte* m2 = stackalloc byte[55] { 0x27, 0x34, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xC4, 0xD1, 0xDE, 0x2B, 0x38, 0x05, 0x12, 0x77, 0x0D, 0x0B, 0x22, 0x24, 0xC1, 0xDF, 0xDF, 0x87, 0xF9, 0x8E, 0x8A, 0x92, 0xAE, 0xBC, 0x41, 0x4E, 0x48, 0x60, 0x79, 0x0D, 0x70, 0x19, 0x2F, 0x23, 0xC1, 0xD2, 0xCA, 0xEE, 0xFC, 0xCF };
            Terminal.PrintObfuscated(m2, 55);
            byte* m3 = stackalloc byte[55] { 0x27, 0x34, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xC4, 0xD1, 0xDE, 0x2B, 0x38, 0x05, 0x12, 0x1F, 0x61, 0x74, 0x4B, 0x5E, 0xAD, 0xA0, 0xB7, 0x8A, 0x99, 0xEC, 0xE3, 0xF6, 0xC5, 0xD8, 0x2F, 0x22, 0x31, 0x04, 0x1B, 0x6E, 0x7D, 0x70, 0x47, 0x5A, 0xA9, 0xBC, 0xB3, 0x86, 0xB2, 0xCF };
            Terminal.PrintObfuscated(m3, 55);

            byte* m4 = stackalloc byte[62] { 0x27, 0x34, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xC4, 0xB8, 0xAA, 0x2B, 0x51, 0x76, 0x12, 0x7E, 0x6C, 0x1F, 0x23, 0x37, 0xC5, 0xDF, 0xDB, 0xEB, 0x94, 0x82, 0x9C, 0x92, 0xA5, 0xB0, 0x22, 0x5B, 0x53, 0x09, 0x75, 0x0C, 0x00, 0x04, 0x4A, 0x23, 0xCC, 0xD8, 0xCD, 0x8B, 0xEB, 0x8A, 0x94, 0x8B, 0xBB, 0xB8, 0x54, 0x56, 0x2A };
            Terminal.PrintObfuscated(m4, 62);
            byte* m5 = stackalloc byte[64] { 0x27, 0x34, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xB0, 0xB9, 0xBB, 0x2B, 0x4B, 0x7C, 0x61, 0x6B, 0x09, 0x14, 0x46, 0x3B, 0xC1, 0xDE, 0xBA, 0xE3, 0xF1, 0x95, 0x8B, 0x98, 0xBC, 0xB0, 0x46, 0x2F, 0x49, 0x67, 0x77, 0x16, 0x04, 0x15, 0x25, 0x25, 0xCD, 0xCB, 0xDB, 0xEF, 0x98, 0x8D, 0x93, 0x8D, 0xA8, 0xAE, 0x47, 0x41, 0x65, 0x27, 0x30 };
            Terminal.PrintObfuscated(m5, 64);

            byte* m6 = stackalloc byte[48] { 0x27, 0x34, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xC4, 0xD1, 0xDE, 0x44, 0x4A, 0x6C, 0x75, 0x76, 0x02, 0x18, 0x2A, 0x53, 0xC1, 0xD8, 0xCE, 0xEF, 0xFB, 0x93, 0xEE, 0xE1, 0xC8, 0xB1, 0x57, 0x56, 0x3C, 0x7D, 0x7E, 0x02, 0x1E, 0x15, 0x60 };
            Terminal.PrintObfuscated(m6, 48);
            byte* m7 = stackalloc byte[53] { 0x27, 0x34, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xC4, 0xD1, 0xDE, 0x47, 0x51, 0x66, 0x77, 0x71, 0x1F, 0x1C, 0x46, 0x20, 0xD4, 0xCC, 0xCE, 0xF2, 0xE7, 0xE1, 0xEE, 0xE1, 0xC8, 0xA0, 0x4C, 0x4E, 0x49, 0x7D, 0x7E, 0x0C, 0x02, 0x14, 0x30, 0x32, 0xC0, 0x9B, 0x94, 0xA1 };
            Terminal.PrintObfuscated(m7, 53);

            Terminal.SetColor(0x00FF0000);
            byte* m8 = stackalloc byte[63] { 0x27, 0x34, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xB4, 0xBD, 0xBB, 0x4A, 0x4B, 0x60, 0x12, 0x6B, 0x19, 0x0B, 0x28, 0x53, 0xCF, 0xCB, 0xDC, 0x87, 0xE4, 0x8E, 0x99, 0x9E, 0xBA, 0xD5, 0x4B, 0x42, 0x51, 0x6C, 0x72, 0x0A, 0x11, 0x09, 0x2F, 0x3B, 0xDD, 0xB1, 0xDF, 0xE5, 0xFC, 0xE5, 0x91, 0x90, 0xA2, 0xAD, 0x47, 0x50, 0x74, 0x27 };
            Terminal.PrintObfuscated(m8, 63);
            byte* m9 = stackalloc byte[52] { 0x27, 0x34, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xC4, 0xD1, 0xDE, 0x2B, 0x38, 0x05, 0x12, 0x1F, 0x6C, 0x79, 0x46, 0x53, 0xD4, 0xC5, 0xDF, 0x87, 0xF5, 0x94, 0x9A, 0x93, 0xA7, 0xA7, 0x22, 0x49, 0x53, 0x7B, 0x16, 0x02, 0x13, 0x1E, 0x2F, 0x24, 0xD7, 0x9B, 0x94 };
            Terminal.PrintObfuscated(m9, 52);

            Terminal.SetColor(0x00FFFFFF);
            byte* m12 = stackalloc byte[36] { 0x27, 0x34, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xDA, 0xD1, 0xBB, 0x45, 0x4C, 0x60, 0x60, 0x1F, 0x01, 0x16, 0x22, 0x36, 0xCC, 0xAD, 0xD1, 0xE2, 0xED, 0xFB, 0xEE };
            Terminal.PrintObfuscated(m12, 36);

            char* inputBuffer = stackalloc char[64];
            int inputLen = 0;

            while (true)
            {
                byte scanCode = 0;
                
                // ==========================================================
                // [BỌC THÉP TRỊ -Ot] KHÓA MÕM LLVM TRONG VÒNG LẶP DRIVER BÀN PHÍM!
                // Ép LLVM đọc lại giá trị cổng 0x64 mỗi lần lặp!
                // Nếu đéo có, bàn phím cứng ngắc, DRM khóa vĩnh viễn!
                // ==========================================================
                while ((IO.In8(0x64) & 1) == 0) { CompilerFence(); }
                
                scanCode = IO.In8(0x60);

                char c = Driver.KeyboardDriver.ProcessScanCode(scanCode);
                
                if (c != '\0') 
                {
                    if (c == '\n' || c == '\r') 
                    {
                        inputBuffer[inputLen] = '\0'; 
                        
                        bool isCorrect = true;
                        if (inputLen != keyLen) isCorrect = false;
                        else {
                            for(int k = 0; k < keyLen; k++) {
                                if (inputBuffer[k] != secretKey[k]) { isCorrect = false; break; }
                            }
                        }

                        if (isCorrect)
                        {
                            Terminal.SetColor(0x0000FF00); 
                            byte* mok = stackalloc byte[46] { 0x0D, 0x1E, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xC4, 0xD1, 0xDE, 0x2B, 0x38, 0x05, 0x12, 0x1F, 0x6C, 0x79, 0x46, 0x53, 0xA0, 0xAD, 0xBA, 0x87, 0x94, 0xE1, 0xEE, 0x9A, 0xAB, 0xB6, 0x47, 0x5F, 0x48, 0x6C, 0x72, 0x62, 0x5A };
                            Terminal.PrintObfuscated(mok, 46);
                            
                            // [BỌC THÉP NỐT VÒNG LẶP DELAY]
                            for(int delay = 0; delay < 1000000; delay++) { CompilerFence(); IO.In8(0x80); }

                            Terminal.Clear(0x00111111); 
                            Terminal.SetColor(0x00FFFFFF);

                            NekkoOS.Kernel.Scheduler.Ready = true;
                            
                            IO.Sti(); 
                            
                            if (APIC.IsAwake) {
                                APIC.Write(0x300, 0x000C4500); 
                            }
                            return; 
                        }
                        else
                        {
                            Terminal.SetColor(0x00FF0000); 
                            byte* m_enc = stackalloc byte[57] { 0x0D, 0x1E, 0x01, 0x0E, 0x1B, 0x68, 0x75, 0x42, 0x4F, 0x5C, 0xA9, 0xB6, 0x83, 0x90, 0x9D, 0xEA, 0xF7, 0xC4, 0xD1, 0xDE, 0x2B, 0x38, 0x05, 0x12, 0x1F, 0x6C, 0x79, 0x27, 0x30, 0xC3, 0xC8, 0xC9, 0xF4, 0x94, 0x85, 0x8B, 0x95, 0xA1, 0xB0, 0x46, 0x2E, 0x3C, 0x7A, 0x6F, 0x10, 0x04, 0x18, 0x27, 0x57, 0xCC, 0xD0, 0xD2, 0xFF, 0xFD, 0x81, 0xFC, 0xD5 };
                            Terminal.PrintObfuscated(m_enc, 57);
                            IO.Cli();
                            while (true) IO.Hlt(); 
                        }
                    }
                    else if (c == '\b' && inputLen > 0) 
                    {
                        inputLen--;
                        fixed(char* bs = "\b \b\0") Terminal.Print(bs);
                    }
                    else if (c >= 32 && c <= 126 && inputLen < 63)
                    {
                        inputBuffer[inputLen++] = c;
                        char* star = stackalloc char[2];
                        star[0] = '*'; star[1] = '\0';
                        Terminal.Print(star);
                    }
                }
            }
        }
    }
}