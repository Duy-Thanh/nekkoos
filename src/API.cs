using System.Runtime.InteropServices;

namespace NekkoApp; 

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct ProcessInfo
{
    public uint ID;
    public uint UID;
    public uint GID;
    public byte Active;
    public byte IsJailed;
    public byte IsPhantomDead;
    public ulong HeapMemory;
    public fixed byte Name[16]; 
    public ulong CpuTicks;
    public uint PhysPages;
    public uint VirtPages;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct Message { 
    public uint Type; 
    public uint Sender; 
    public uint Receiver; 
    public uint Padding; 
    public ulong Payload; 
}

public unsafe class API
{
    // Chữ ký ma thuật để Kernel vả KASLR vào!
    public static ulong KASLR_vDSO = 0x1337BEEFCAFE8BAD; 

    // Các con trỏ hàm với tên Y HỆT DllImport ngày xưa!
    public static delegate* unmanaged<char*, void> SyscallPrint;
    public static delegate* unmanaged<void> SyscallExit;
    public static delegate* unmanaged<uint, uint, ulong, void> SyscallSendIPC;
    public static delegate* unmanaged<ulong, ulong> SyscallAllocMem;
    public static delegate* unmanaged<ushort, void> SyscallGrantPort;
    public static delegate* unmanaged<Message*, int> SyscallReceiveIPC;
    public static delegate* unmanaged<ulong> SyscallGetSharedMem;
    public static delegate* unmanaged<byte> SyscallGetChar;
    public static delegate* unmanaged<char*, ulong, void> SyscallRunCmd;
    public static delegate* unmanaged<uint, uint> SyscallGetThreadUID;
    public static delegate* unmanaged<uint, int> SyscallSetUID;
    public static delegate* unmanaged<uint> SyscallGetUID;
    public static delegate* unmanaged<void> SyscallYieldApp; 
    public static delegate* unmanaged<void> SyscallYield; 
    public static delegate* unmanaged<void> SyscallWaitIPC;
    public static delegate* unmanaged<uint, uint> SyscallGetThreadGID;
    public static delegate* unmanaged<uint, int> SyscallSetGID;
    public static delegate* unmanaged<uint, ProcessInfo*, int> SyscallGetProcessInfo;
    public static delegate* unmanaged<uint, void> SyscallClear;
    public static delegate* unmanaged<ulong, void> SyscallSleep;
    public static delegate* unmanaged<ulong> SyscallGetUptime;
    public static delegate* unmanaged<ulong> SyscallGetRsdp;
    public static delegate* unmanaged<ulong, ulong, ulong> SyscallMapPhys;
    public static delegate* unmanaged<uint, ulong, ulong> SyscallReportHardware;
    public static delegate* unmanaged<char*, int> SyscallGetPIDByName;
    public static delegate* unmanaged<void> SyscallResetCursor;
    public static delegate* unmanaged<uint, ulong, ulong*, ulong> SyscallCreateSharedBuffer;
    public static delegate* unmanaged<ulong, uint, uint, uint, void> SyscallRedirectTerminal;

    public static delegate* unmanaged<ushort, byte> AppInByte;
    public static delegate* unmanaged<ushort, byte, void> AppOutByte;
    public static delegate* unmanaged<ushort, ushort> AppInWord;
    public static delegate* unmanaged<ushort, ushort, void> AppOutWord;
    public static delegate* unmanaged<ushort, uint, void> AppOutDword;

    // ==========================================================
    // [FIX RACE CONDITION ATA/SMP] KHÓA PHẦN CỨNG ATA DÙNG CHUNG!
    // ATA.EXE (Ring 3) PHẢI gọi cặp này bao quanh MỌI thao tác IN/OUT thô
    // trên cổng 0x1F0-0x1F7, để loại trừ lẫn nhau với đường raw driver
    // của Kernel (Ring 0) đang chạy song song trên lõi CPU khác (SMP).
    // ==========================================================
    public static delegate* unmanaged<void> SyscallAcquireAtaHw;
    public static delegate* unmanaged<void> SyscallReleaseAtaHw;

    // ==========================================================
    // [VŨ KHÍ MỚI] CHÌA KHÓA MỞ CỔNG HOÀNG CUNG CHO DISPLAY SERVER!
    // ==========================================================
    public static delegate* unmanaged<ulong> SyscallRequestFramebuffer;
    public static delegate* unmanaged<ulong*, ulong*, ulong*, int> SyscallGetScreenInfo;

    // HÀM NÀY PHẢI GỌI ĐẦU TIÊN TRONG MỌI APP ĐỂ NẠP ĐẠN KASLR!
    public static void InitAPI() {
        
        // ==========================================================
        // [FIX CHÍ MẠNG VŨ TRỤ] ÉP BUỘC ĐỌC BỘ NHỚ THÔ (MEMORY READ)
        // Cấm Compiler tối ưu hóa in-line con số 0x1337BEEFCAFE8BAD!
        // Đảm bảo chữ ký luôn nằm ở vùng .data chẵn 8-byte cho Kernel quét!
        // ==========================================================
        ulong actualKaslr = 0;
        fixed (ulong* ptr = &KASLR_vDSO) {
            actualKaslr = *ptr;
        }

        // Treat actualKaslr (base address of vDSO) as a ulong* table
        ulong* table = (ulong*)actualKaslr;
        
        // Setup function pointer to point to correct elements in vDSO table
        // funciton pointer = baseAddress + offset
        // After InitAPI(), Syscall tables POINT TO real address of Assembly's Stub!
        SyscallPrint = (delegate* unmanaged<char*, void>)(actualKaslr + table[0]);
        SyscallExit = (delegate* unmanaged<void>)(actualKaslr + table[1]);
        SyscallSendIPC = (delegate* unmanaged<uint, uint, ulong, void>)(actualKaslr + table[2]);
        SyscallAllocMem = (delegate* unmanaged<ulong, ulong>)(actualKaslr + table[3]);
        SyscallGrantPort = (delegate* unmanaged<ushort, void>)(actualKaslr + table[4]);
        SyscallReceiveIPC = (delegate* unmanaged<Message*, int>)(actualKaslr + table[5]);
        SyscallGetSharedMem = (delegate* unmanaged<ulong>)(actualKaslr + table[6]);
        SyscallGetChar = (delegate* unmanaged<byte>)(actualKaslr + table[7]);
        SyscallRunCmd = (delegate* unmanaged<char*, ulong, void>)(actualKaslr + table[8]);
        SyscallGetThreadUID = (delegate* unmanaged<uint, uint>)(actualKaslr + table[9]);
        SyscallSetUID = (delegate* unmanaged<uint, int>)(actualKaslr + table[10]);
        SyscallGetUID = (delegate* unmanaged<uint>)(actualKaslr + table[11]);
        
        var yieldPtr = (delegate* unmanaged<void>)(actualKaslr + table[12]);
        SyscallYieldApp = yieldPtr; SyscallYield = yieldPtr;
        
        SyscallWaitIPC = (delegate* unmanaged<void>)(actualKaslr + table[13]);
        SyscallGetThreadGID = (delegate* unmanaged<uint, uint>)(actualKaslr + table[14]);
        SyscallSetGID = (delegate* unmanaged<uint, int>)(actualKaslr + table[15]);
        SyscallGetProcessInfo = (delegate* unmanaged<uint, ProcessInfo*, int>)(actualKaslr + table[16]);
        SyscallClear = (delegate* unmanaged<uint, void>)(actualKaslr + table[17]);
        SyscallSleep = (delegate* unmanaged<ulong, void>)(actualKaslr + table[18]);
        SyscallGetUptime = (delegate* unmanaged<ulong>)(actualKaslr + table[19]);
        SyscallGetRsdp = (delegate* unmanaged<ulong>)(actualKaslr + table[20]);
        SyscallMapPhys = (delegate* unmanaged<ulong, ulong, ulong>)(actualKaslr + table[21]);
        SyscallReportHardware = (delegate* unmanaged<uint, ulong, ulong>)(actualKaslr + table[22]);
        SyscallGetPIDByName = (delegate* unmanaged<char*, int>)(actualKaslr + table[23]);
        SyscallResetCursor = (delegate* unmanaged<void>)(actualKaslr + table[24]);
        
        // ==========================================================
        // [ĐỒNG BỘ INDEX] VÀO ĐÚNG SLOT 25 VÀ 26 NHƯ BÊN KERNEL!
        // ==========================================================
        SyscallRequestFramebuffer = (delegate* unmanaged<ulong>)(actualKaslr + table[25]);
        SyscallGetScreenInfo = (delegate* unmanaged<ulong*, ulong*, ulong*, int>)(actualKaslr + table[26]);
        SyscallCreateSharedBuffer = (delegate* unmanaged<uint, ulong, ulong*, ulong>)(actualKaslr + table[27]);
        SyscallRedirectTerminal = (delegate* unmanaged<ulong, uint, uint, uint, void>)(actualKaslr + table[28]);

        AppInByte = (delegate* unmanaged<ushort, byte>)(actualKaslr + table[29]);
        AppOutByte = (delegate* unmanaged<ushort, byte, void>)(actualKaslr + table[30]);
        AppInWord = (delegate* unmanaged<ushort, ushort>)(actualKaslr + table[31]);
        AppOutWord = (delegate* unmanaged<ushort, ushort, void>)(actualKaslr + table[32]);
        AppOutDword = (delegate* unmanaged<ushort, uint, void>)(actualKaslr + table[33]);

        // [FIX RACE CONDITION ATA/SMP] Slot 34 & 35
        SyscallAcquireAtaHw = (delegate* unmanaged<void>)(actualKaslr + table[34]);
        SyscallReleaseAtaHw = (delegate* unmanaged<void>)(actualKaslr + table[35]);
    }
}