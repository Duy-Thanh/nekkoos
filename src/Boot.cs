using System;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;

namespace NekkoOS
{
    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_TABLE_HEADER { public ulong Signature; public uint Revision; public uint HeaderSize; public uint Crc32; public uint Reserved; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_GUID { public uint Data1; public ushort Data2; public ushort Data3; public byte D4_0; public byte D4_1; public byte D4_2; public byte D4_3; public byte D4_4; public byte D4_5; public byte D4_6; public byte D4_7; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_INPUT_KEY { public ushort ScanCode; public char UnicodeChar; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_SIMPLE_TEXT_INPUT_PROTOCOL { public delegate* unmanaged<EFI_SIMPLE_TEXT_INPUT_PROTOCOL*, bool, ulong> Reset; public delegate* unmanaged<EFI_SIMPLE_TEXT_INPUT_PROTOCOL*, EFI_INPUT_KEY*, ulong> ReadKeyStroke; public void* WaitForKey; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL { public delegate* unmanaged<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, bool, ulong> Reset; public delegate* unmanaged<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, char*, ulong> OutputString; public delegate* unmanaged<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, char*, ulong> TestString; public delegate* unmanaged<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, ulong, ulong*, ulong*, ulong> QueryMode; public delegate* unmanaged<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, ulong, ulong> SetMode; public delegate* unmanaged<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, ulong, ulong> SetAttribute; public delegate* unmanaged<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, ulong> ClearScreen; public delegate* unmanaged<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, ulong, ulong, ulong> SetCursorPosition; public delegate* unmanaged<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL*, bool, ulong> EnableCursor; public void* Mode; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_GRAPHICS_OUTPUT_MODE_INFORMATION { public uint Version; public uint HorizontalResolution; public uint VerticalResolution; public int PixelFormat; public uint RedMask; public uint GreenMask; public uint BlueMask; public uint ReservedMask; public uint PixelsPerScanLine; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE { public uint MaxMode; public uint Mode; public EFI_GRAPHICS_OUTPUT_MODE_INFORMATION* Info; public ulong SizeOfInfo; public ulong FrameBufferBase; public ulong FrameBufferSize; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_GRAPHICS_OUTPUT_PROTOCOL { public delegate* unmanaged<EFI_GRAPHICS_OUTPUT_PROTOCOL*, uint, ulong*, EFI_GRAPHICS_OUTPUT_MODE_INFORMATION**, ulong> QueryMode; public delegate* unmanaged<EFI_GRAPHICS_OUTPUT_PROTOCOL*, uint, ulong> SetMode; public delegate* unmanaged<EFI_GRAPHICS_OUTPUT_PROTOCOL*, void*, uint, ulong, ulong, ulong, ulong, ulong, ulong, ulong> Blt; public EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE* Mode; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_MEMORY_DESCRIPTOR { public uint Type; public ulong PhysicalStart; public ulong VirtualStart; public ulong NumberOfPages; public ulong Attribute; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_LOADED_IMAGE_PROTOCOL { public uint Revision; public void* ParentHandle; public void* SystemTable; public void* DeviceHandle; public void* FilePath; public void* Reserved; public uint LoadOptionsSize; public void* LoadOptions; public void* ImageBase; public ulong ImageSize; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_TIME { public ushort Year; public byte Month; public byte Day; public byte Hour; public byte Minute; public byte Second; public byte Pad1; public uint Nanosecond; public short TimeZone; public byte Daylight; public byte Pad2; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_FILE_INFO { public ulong Size; public ulong FileSize; public ulong PhysicalSize; public EFI_TIME CreateTime; public EFI_TIME LastAccessTime; public EFI_TIME ModificationTime; public ulong Attribute; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_FILE_PROTOCOL { public ulong Revision; public delegate* unmanaged<EFI_FILE_PROTOCOL*, EFI_FILE_PROTOCOL**, char*, ulong, ulong, ulong> Open; public delegate* unmanaged<EFI_FILE_PROTOCOL*, ulong> Close; public delegate* unmanaged<EFI_FILE_PROTOCOL*, ulong> Delete; public delegate* unmanaged<EFI_FILE_PROTOCOL*, ulong*, void*, ulong> Read; public delegate* unmanaged<EFI_FILE_PROTOCOL*, ulong*, void*, ulong> Write; public delegate* unmanaged<EFI_FILE_PROTOCOL*, ulong*, ulong> GetPosition; public delegate* unmanaged<EFI_FILE_PROTOCOL*, ulong, ulong> SetPosition; public delegate* unmanaged<EFI_FILE_PROTOCOL*, EFI_GUID*, ulong*, void*, ulong> GetInfo; public delegate* unmanaged<EFI_FILE_PROTOCOL*, EFI_GUID*, ulong*, void*, ulong> SetInfo; public delegate* unmanaged<EFI_FILE_PROTOCOL*, ulong> Flush; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL { public ulong Revision; public delegate* unmanaged<EFI_SIMPLE_FILE_SYSTEM_PROTOCOL*, EFI_FILE_PROTOCOL**, ulong> OpenVolume; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_RUNTIME_SERVICES { public EFI_TABLE_HEADER Hdr; public delegate* unmanaged<void*, void*, ulong> GetTime; public delegate* unmanaged<void*, ulong> SetTime; public delegate* unmanaged<ulong, void*, void*, ulong> GetWakeupTime; public delegate* unmanaged<bool, void*, ulong> SetWakeupTime; public delegate* unmanaged<ulong, ulong, ulong, ulong, ulong*, ulong> SetVirtualAddressMap; public delegate* unmanaged<ulong*, ulong> ConvertPointer; public delegate* unmanaged<char*, EFI_GUID*, uint*, ulong*, void*, ulong> GetVariable; public delegate* unmanaged<char*, EFI_GUID*, uint*, ulong*, void**, ulong> GetNextVariableName; public delegate* unmanaged<char*, EFI_GUID*, uint, ulong, void*, ulong> SetVariable; public delegate* unmanaged<uint*, uint*, uint*, ulong> GetNextHighMonotonicCount; public delegate* unmanaged<uint, ulong, ulong, void*, void> ResetSystem; public delegate* unmanaged<void*, void*, ulong*, ulong*, uint*, ulong> UpdateCapsule; public delegate* unmanaged<void**, ulong, ulong*, ulong> QueryCapsuleCapabilities; public delegate* unmanaged<ulong*, void**, ulong> QueryVariableInfo; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_CONFIGURATION_TABLE { public EFI_GUID VendorGuid; public void* VendorTable; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_BOOT_SERVICES { public EFI_TABLE_HEADER Hdr; public delegate* unmanaged<ulong, ulong> RaiseTPL; public delegate* unmanaged<ulong, void> RestoreTPL; public delegate* unmanaged<uint, uint, ulong, ulong*, ulong> AllocatePages; public delegate* unmanaged<ulong, ulong, ulong> FreePages; public delegate* unmanaged<ulong*, EFI_MEMORY_DESCRIPTOR*, ulong*, ulong*, uint*, ulong> GetMemoryMap; public delegate* unmanaged<uint, ulong, void**, ulong> AllocatePool; public delegate* unmanaged<void*, ulong> FreePool; public delegate* unmanaged<uint, ulong, delegate* unmanaged<void*, void*, void>, void*, void**, ulong> CreateEvent; public delegate* unmanaged<void*, int, ulong, ulong> SetTimer; public delegate* unmanaged<ulong, void**, ulong*, ulong> WaitForEvent; public delegate* unmanaged<void*, ulong> SignalEvent; public delegate* unmanaged<void*, ulong> CloseEvent; public delegate* unmanaged<void*, ulong> CheckEvent; public delegate* unmanaged<void**, EFI_GUID*, uint, void*, ulong> InstallProtocolInterface; public delegate* unmanaged<void*, EFI_GUID*, void*, void*, ulong> ReinstallProtocolInterface; public delegate* unmanaged<void*, EFI_GUID*, void*, ulong> UninstallProtocolInterface; public delegate* unmanaged<void*, EFI_GUID*, void**, ulong> HandleProtocol; public void* Reserved; public delegate* unmanaged<EFI_GUID*, void*, void**, ulong> RegisterProtocolNotify; public delegate* unmanaged<int, EFI_GUID*, void*, ulong*, void**, ulong> LocateHandle; public delegate* unmanaged<EFI_GUID*, void**, ulong> LocateDevicePath; public delegate* unmanaged<EFI_GUID*, void*, ulong> InstallConfigurationTable; public delegate* unmanaged<bool, void*, void*, void*, ulong, void**, ulong> LoadImage; public delegate* unmanaged<void*, ulong*, ushort**, ulong> StartImage; public delegate* unmanaged<void*, ulong, ulong, ushort*, ulong> Exit; public delegate* unmanaged<void*, ulong> UnloadImage; public delegate* unmanaged<void*, ulong, ulong> ExitBootServices; public delegate* unmanaged<ulong*, ulong> GetNextMonotonicCount; public delegate* unmanaged<ulong, ulong> Stall; public delegate* unmanaged<ulong, ulong, ulong, ushort*, ulong> SetWatchdogTimer; public delegate* unmanaged<void*, void*, void*, bool, ulong> ConnectController; public delegate* unmanaged<void*, void*, void*, ulong> DisconnectController; public delegate* unmanaged<void*, EFI_GUID*, void**, void*, void*, uint, ulong> OpenProtocol; public delegate* unmanaged<void*, EFI_GUID*, void*, void*, ulong> CloseProtocol; public delegate* unmanaged<void*, EFI_GUID*, void**, ulong*, ulong> OpenProtocolInformation; public delegate* unmanaged<void*, EFI_GUID***, ulong*, ulong> ProtocolsPerHandle; public delegate* unmanaged<int, EFI_GUID*, void**, ulong*, void***, ulong> LocateHandleBuffer; public delegate* unmanaged<EFI_GUID*, void*, void**, ulong> LocateProtocol; public delegate* unmanaged<void**, ulong> InstallMultipleProtocolInterfaces; public delegate* unmanaged<void*, ulong> UninstallMultipleProtocolInterfaces; public delegate* unmanaged<void*, ulong, uint*, ulong> CalculateCrc32; public delegate* unmanaged<void*, void*, ulong, void> CopyMem; public delegate* unmanaged<void*, ulong, byte, void> SetMem; public delegate* unmanaged<uint, ulong, delegate* unmanaged<void*, void*, void>, void*, EFI_GUID*, void**, ulong> CreateEventEx; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_SYSTEM_TABLE { public EFI_TABLE_HEADER Hdr; public char* FirmwareVendor; public uint FirmwareRevision; public void* ConsoleInHandle; public EFI_SIMPLE_TEXT_INPUT_PROTOCOL* ConIn; public void* ConsoleOutHandle; public EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL* ConOut; public void* StandardErrorHandle; public EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL* StdErr; public EFI_RUNTIME_SERVICES* RuntimeServices; public EFI_BOOT_SERVICES* BootServices; public ulong NumberOfTableEntries; public EFI_CONFIGURATION_TABLE* ConfigurationTable; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct EFI_RNG_PROTOCOL { public delegate* unmanaged<EFI_RNG_PROTOCOL*, ulong*, EFI_GUID*, ulong> GetInfo; public delegate* unmanaged<EFI_RNG_PROTOCOL*, EFI_GUID*, ulong, byte*, ulong> GetRNG; }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct NekkoBootInfo { public ulong FrameBufferBase; public ulong FrameBufferSize; public uint HorizontalResolution; public uint VerticalResolution; public uint PixelsPerScanLine; public void* MemoryMap; public ulong MemoryMapSize; public ulong DescriptorSize; public ulong AcpiRsdp; }

    // ==========================================================
    // KHỐI STRUCT GIẢI MÃ ACPI VÀ BGRT LOGO
    // ==========================================================
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public unsafe struct ACPI_HEADER {
        public uint Signature; 
        public uint Length;
        public byte Revision;
        public byte Checksum;
        public fixed byte OEMID[6];
        public fixed byte OEMTableID[8];
        public uint OEMRevision;
        public uint CreatorID;
        public uint CreatorRevision;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public unsafe struct ACPI_BGRT {
        public ACPI_HEADER Header;
        public ushort Version;
        public byte Status;
        public byte ImageType;
        public ulong ImageAddress;
        public uint ImageOffsetX;
        public uint ImageOffsetY;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public unsafe struct BMP_HEADER {
        public ushort Signature; 
        public uint FileSize;
        public uint Reserved;
        public uint DataOffset;
        public uint HeaderSize;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort Bpp;
        public uint Compression;
        public uint ImageSize;
        public int XPixelsPerM;
        public int YPixelsPerM;
        public uint ColorsUsed;
        public uint ImportantColors;
    }

    // ==========================================================
    // [VŨ KHÍ TỐI THƯỢNG] BAREMETAL SHA-256 CRYPTO ENGINE
    // Chạy hoàn toàn bằng thanh ghi và Stack, đéo cần GC!
    // ==========================================================
    // ==========================================================
    // [VŨ KHÍ TỐI THƯỢNG] BAREMETAL SHA-256 CRYPTO ENGINE (BẢN VÁ LỖI)
    // 100% Stack Allocation! Đéo đụng tới một hạt bụi của Heap!
    // ==========================================================
    public static unsafe class BaremetalSHA256
    {
        private static uint ROTR(uint x, int n) => (x >> n) | (x << (32 - n));
        private static uint CH(uint x, uint y, uint z) => (x & y) ^ (~x & z);
        private static uint MAJ(uint x, uint y, uint z) => (x & y) ^ (x & z) ^ (y & z);
        private static uint EP0(uint x) => ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22);
        private static uint EP1(uint x) => ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25);
        private static uint SIG0(uint x) => ROTR(x, 7) ^ ROTR(x, 18) ^ (x >> 3);
        private static uint SIG1(uint x) => ROTR(x, 17) ^ ROTR(x, 19) ^ (x >> 10);

        private static readonly uint[] SHA256_K = new uint[64] {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        };

        private static readonly uint[] SHA256_H0 = new uint[8] { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };

        public static void Compute(byte* data, ulong length, byte* outputHash)
        {
            // Kiểm tra các tham số đầu vào
            if (data == null || outputHash == null || length == 0)
                return;
            
            // Giới hạn kích thước đầu vào để tránh tràn bộ nhớ
            if (length > 0x10000000) // 256MB
                return;

            // Use static tables for K and initial H to reduce stack pressure
            fixed (uint* Kptr = SHA256_K)
            {
                uint* H = stackalloc uint[8];
                for (int i = 0; i < 8; i++) H[i] = SHA256_H0[i];
                uint* W = stackalloc uint[64];
            
                ulong totalBits = length * 8;
                ulong paddedLen = length + 1;
                while (paddedLen % 64 != 56) paddedLen++;
                paddedLen += 8; 

                byte* block = stackalloc byte[64];
                ulong offset = 0;

                while (offset < paddedLen)
                {
                    for (int i = 0; i < 64; i++) {
                        if (offset + (ulong)i < length) block[i] = data[offset + (ulong)i];
                        else if (offset + (ulong)i == length) block[i] = 0x80;
                        else block[i] = 0x00;
                    }
                    
                    if (offset + 64 >= paddedLen) {
                        for (int i = 0; i < 8; i++) block[63 - i] = (byte)((totalBits >> (i * 8)) & 0xFF);
                    }

                    for (int t = 0; t < 16; t++) {
                        W[t] = ((uint)block[t * 4] << 24) | ((uint)block[t * 4 + 1] << 16) | ((uint)block[t * 4 + 2] << 8) | (uint)block[t * 4 + 3];
                    }
                    for (int t = 16; t < 64; t++) {
                        W[t] = SIG1(W[t - 2]) + W[t - 7] + SIG0(W[t - 15]) + W[t - 16];
                    }

                    uint a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];

                    for (int t = 0; t < 64; t++) {
                        uint T1 = h + EP1(e) + CH(e, f, g) + Kptr[t] + W[t];
                        uint T2 = EP0(a) + MAJ(a, b, c);
                        h = g; g = f; f = e; e = d + T1;
                        d = c; c = b; b = a; a = T1 + T2;
                    }

                    H[0] += a; H[1] += b; H[2] += c; H[3] += d; H[4] += e; H[5] += f; H[6] += g; H[7] += h;
                    offset += 64;
                }

                for (int i = 0; i < 8; i++) {
                    outputHash[i * 4] = (byte)((H[i] >> 24) & 0xFF);
                    outputHash[i * 4 + 1] = (byte)((H[i] >> 16) & 0xFF);
                    outputHash[i * 4 + 2] = (byte)((H[i] >> 8) & 0xFF);
                    outputHash[i * 4 + 3] = (byte)(H[i] & 0xFF);
                }
            }
        }
    }

    // ==========================================================
    // [VŨ KHÍ TỐI THƯỢNG] BAREMETAL RSA-2048 PKCS#1 v1.5 VERIFIER
    // Xử lý số siêu lớn (BigInt 2048-bit) 100% bằng Stack! Đéo xài Heap!
    // ==========================================================
    public static unsafe class BaremetalRSA
    {
        public const int LEN = 64; // 64 uints = 2048 bits = 256 bytes

        private static int Cmp(uint* a, uint* b) {
            for (int i = LEN - 1; i >= 0; i--) {
                if (a[i] > b[i]) return 1;
                if (a[i] < b[i]) return -1;
            }
            return 0;
        }

        private static void Sub(uint* a, uint* b) {
            ulong borrow = 0;
            for (int i = 0; i < LEN; i++) {
                ulong res = (ulong)a[i] - b[i] - borrow;
                a[i] = (uint)res;
                borrow = (res >> 32) & 1;
            }
        }

        // Phép chia Modulo siêu to khổng lồ (128 uints chia cho 64 uints)
        // ==========================================================
        // [FIX CHÍ MẠNG] HÀM MODULO BỌC THÉP CHỐNG TRÀN BIT!
        // ==========================================================
        private static void Mod(uint* a, uint* n, uint* r) {
            // Kiểm tra các tham số đầu vào
            if (a == null || n == null || r == null)
                return;
            for (int i = 0; i < LEN; i++) r[i] = 0;

            // Giới hạn vòng lặp để tránh vô hạn
            const int maxIterations = 16386; // Giới hạn số lần lặp
            int iterationCount = 0;

            for (int i = 128 * 32 - 1; i >= 0; i--) {
                // Kiểm tra xem có vượt quá giới hạn không
                if (iterationCount >= maxIterations) break;
                iterationCount++;
                uint carry = 0;
                for (int j = 0; j < LEN; j++) {
                    uint next = r[j] >> 31;
                    r[j] = (r[j] << 1) | carry;
                    carry = next;
                }
                r[0] |= (a[i / 32] >> (i % 32)) & 1;
                if (carry != 0 || Cmp(r, n) >= 0) Sub(r, n);
            }
        }

        // Phép nhân Trường học (Schoolbook Multiplication)
        private static void Mul(uint* a, uint* b, uint* r) {
            for (int i = 0; i < 128; i++) r[i] = 0;
            for (int i = 0; i < LEN; i++) {
                ulong carry = 0;
                for (int j = 0; j < LEN; j++) {
                    ulong res = r[i + j] + ((ulong)a[i] * b[j]) + carry;
                    r[i + j] = (uint)res;
                    carry = res >> 32;
                }
                r[i + LEN] = (uint)carry;
            }
        }

        // Chuyển đổi Big-Endian (OpenSSL) sang Little-Endian (CPU x86_64)
        public static void BytesToUInts(byte* bytes, uint* uints) {
            for (int i = 0; i < LEN; i++) {
                int b = 252 - (i * 4);
                uints[i] = ((uint)bytes[b] << 24) | ((uint)bytes[b + 1] << 16) | ((uint)bytes[b + 2] << 8) | bytes[b + 3];
            }
        }

        public static void UIntsToBytes(uint* uints, byte* bytes) {
            for (int i = 0; i < LEN; i++) {
                int b = 252 - (i * 4);
                bytes[b] = (byte)(uints[i] >> 24);
                bytes[b + 1] = (byte)(uints[i] >> 16);
                bytes[b + 2] = (byte)(uints[i] >> 8);
                bytes[b + 3] = (byte)(uints[i]);
            }
        }

        // Tính S^65537 mod N
        public static void VerifySignature(byte* signature, byte* publicKey, byte* output, uint* S, uint* N, uint* Res, uint* tempMul, uint* baseS) {
            // Kiểm tra các tham số đầu vào
            if (signature == null || publicKey == null || output == null || 
                S == null || N == null || Res == null || tempMul == null || baseS == null)
                return;

            BytesToUInts(signature, S);
            BytesToUInts(publicKey, N);

            for (int i = 0; i < LEN; i++) { baseS[i] = S[i]; Res[i] = S[i]; }

            for (int i = 0; i < 16; i++) {
                Mul(Res, Res, tempMul);
                Mod(tempMul, N, Res);
            }
            Mul(Res, baseS, tempMul);
            Mod(tempMul, N, Res);

            UIntsToBytes(Res, output);
        }
    }

    public static unsafe class Boot
    {
        // ==========================================================
        // KHỐI I/O PORT GIAO TIẾP VỚI COM1
        // ==========================================================
        [DllImport("*", EntryPoint = "Out8")] static extern void Out8(ushort port, byte value);
        [DllImport("*", EntryPoint = "In8")] static extern byte In8(ushort port);

        const ushort COM1 = 0x3F8;

        public static void InitSerial() {
            Out8(COM1 + 1, 0x00); Out8(COM1 + 3, 0x80); Out8(COM1 + 0, 0x03);
            Out8(COM1 + 1, 0x00); Out8(COM1 + 3, 0x03); Out8(COM1 + 2, 0xC7); Out8(COM1 + 4, 0x0B);
        }

        public static void SerialWriteChar(char c) {
            if (c == '\n') {
                while ((In8(COM1 + 5) & 0x20) == 0) { }
                Out8(COM1, (byte)'\r');
            }
            while ((In8(COM1 + 5) & 0x20) == 0) { }
            Out8(COM1, (byte)c);
        }

        public static bool SerialReceived() {
            return (In8(COM1 + 5) & 1) != 0;
        }

        public static char SerialReadChar() {
            while (!SerialReceived()) { } // Đóng băng vòng lặp chờ gõ phím!
            return (char)In8(COM1);
        }

        // ==========================================================
        // [VŨ KHÍ MỚI] ĐỌC SERIAL VỚI ĐỒNG HỒ ĐẾM NGƯỢC (NON-BLOCKING TIMEOUT)
        // ==========================================================
        public static char SerialReadCharWithTimeout(EFI_BOOT_SERVICES* bs, ulong timeoutMs) {
            ulong elapsed = 0;
            while (elapsed < timeoutMs) {
                if (SerialReceived()) {
                    return (char)In8(COM1); // Kẻ xâm nhập đã gõ phím!
                }
                // Kiểm tra xem bs có null không
                if (bs == null) return '\0';
                bs->Stall(1000);
                elapsed++;
            }
            return '\0'; // Hết giờ! Đéo có ai cả!
        }

        // ==========================================================
        // [VŨ KHÍ MỚI] HÀM ĐỌC CHUỖI HEX TỪ BÀN PHÍM SERIAL!
        // Cho phép mày gõ địa chỉ RAM hoặc số Port I/O trực tiếp!
        // ==========================================================
        public static ulong SerialReadHex() {
            ulong result = 0;
            while (true) {
                char c = SerialReadChar();
                if (c == '\r' || c == '\n') { 
                    SerialWriteChar('\r'); SerialWriteChar('\n'); 
                    break; 
                }
                
                if (c >= '0' && c <= '9') { 
                    result = (result << 4) | (ulong)(c - '0'); 
                    SerialWriteChar(c); // Echo chữ ra màn hình
                }
                else if (c >= 'a' && c <= 'f') { 
                    result = (result << 4) | (ulong)(c - 'a' + 10); 
                    SerialWriteChar(c); 
                }
                else if (c >= 'A' && c <= 'F') { 
                    result = (result << 4) | (ulong)(c - 'A' + 10); 
                    SerialWriteChar(c); 
                }
                // Gõ bậy (chữ X, Y, Z) thì nó lơ đi, đéo echo!
            }
            return result;
        }

        // ==========================================================
        // [FIX LẶP TỪ] THUẬN NƯỚC ĐẨY THUYỀN!
        // Thằng UEFI OVMF đã tự động chẻ log ra COM1 rồi, 
        // đéo cần tự gọi SerialWriteChar ở đây nữa để tránh Double Echo!
        // ==========================================================
        public static void Print(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL* conOut, char* str) {
            conOut->OutputString(conOut, str); 
        }

        public static void PrintHex(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL* conOut, ulong number)
        {
            char* buffer = stackalloc char[19];
            buffer[0] = '0'; buffer[1] = 'x'; buffer[18] = '\0';
            char* hexChars = stackalloc char[16] { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F' };
            for (int i = 0; i < 16; i++) {
                int nibble = (int)((number >> ((15 - i) * 4)) & 0xF);
                buffer[2 + i] = hexChars[nibble];
            }
            Print(conOut, buffer); 
        }

        public static void PrintNumber(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL* conOut, ulong number)
        {
            if (number == 0) {
                char* zero = stackalloc char[] { '0', '\0' };
                Print(conOut, zero);
                return;
            }
            char* buffer = stackalloc char[20];
            int index = 19; buffer[index] = '\0'; index--;

            while (number > 0) {
                buffer[index] = (char)('0' + (number % 10));
                number /= 10; index--;
            }
            Print(conOut, &buffer[index + 1]); 
        }

        public static ulong Random(EFI_SYSTEM_TABLE* systemTable, ulong min, ulong max)
        {
            ulong seed = 0;
            EFI_GUID rngGuid = new EFI_GUID { Data1 = 0x3152bca5, Data2 = 0xeade, Data3 = 0x433d, D4_0 = 0x86, D4_1 = 0x2e, D4_2 = 0xc0, D4_3 = 0x1c, D4_4 = 0xdc, D4_5 = 0x29, D4_6 = 0x1f, D4_7 = 0x44 };
            void* rngInterface;
            ulong status = systemTable->BootServices->LocateProtocol(&rngGuid, null, &rngInterface);

            if (status == 0) {
                EFI_RNG_PROTOCOL* rng = (EFI_RNG_PROTOCOL*)rngInterface;
                ulong hwRandom = 0;
                status = rng->GetRNG(rng, null, 8, (byte*)&hwRandom);
                if (status == 0) seed = hwRandom; 
            }

            EFI_TIME time; systemTable->RuntimeServices->GetTime(&time, null);
            seed ^= (ulong)time.Nanosecond << 24; seed ^= ((ulong)time.Second << 32) | (ulong)time.Minute; seed ^= (ulong)time.Day << 48;
            ulong stackRnd = (ulong)(&time); seed ^= (stackRnd << 13) | (stackRnd >> 7); seed ^= (ulong)systemTable;
            ulong monotonic = 0; systemTable->BootServices->GetNextMonotonicCount(&monotonic); seed ^= (monotonic << 32) | (monotonic >> 32);
            seed |= (seed | 6364136223846793005UL) | 1442695040888963407UL | seed * seed;
            seed = (seed ^ (seed >> 30)) * 0xbf58476d1ce4e5b9UL; seed = (seed ^ (seed >> 27)) * 0x94d049bb133111ebUL;
            ulong range = max - min + 1; return min + (seed % range);
        }

        private static unsafe uint RvaToOffset(uint rva, byte* ntHeader)
        {
            ushort numSections = *(ushort*)(ntHeader + 6); ushort optHeaderSize = *(ushort*)(ntHeader + 20); byte* sectionTable = ntHeader + 24 + optHeaderSize;
            for (int i = 0; i < numSections; i++) {
                byte* sec = sectionTable + (i * 40); uint vSize = *(uint*)(sec + 8); uint vAddr = *(uint*)(sec + 12); uint rawPtr = *(uint*)(sec + 20);
                if (rva >= vAddr && rva < vAddr + vSize) return rva - vAddr + rawPtr;
            }
            return rva; 
        }

        public static unsafe void* GetKernelRealEntryPoint(void* imageBase)
        {
            byte* basePtr = (byte*)imageBase; int e_lfanew = *(int*)(basePtr + 0x3C); byte* nt = basePtr + e_lfanew;
            uint exportRVA = *(uint*)(nt + 136); if (exportRVA == 0) return null;
            byte* exportDir = basePtr + exportRVA; uint numberOfNames = *(uint*)(exportDir + 24);
            uint* addressOfFunctions = (uint*)(basePtr + *(uint*)(exportDir + 28)); uint* addressOfNames = (uint*)(basePtr + *(uint*)(exportDir + 32)); ushort* addressOfNameOrdinals = (ushort*)(basePtr + *(uint*)(exportDir + 36));

            for (uint i = 0; i < numberOfNames; i++) {
                char* name = (char*)(basePtr + addressOfNames[i]);
                if (IsKernelMain(name)) {
                    uint funcRVA = addressOfFunctions[addressOfNameOrdinals[i]]; return (void*)(basePtr + funcRVA);
                }
            }
            return null;
        }

        // ==========================================================
        // [VŨ KHÍ TỐI THƯỢNG] HÀM TRÍCH XUẤT VÀ VẼ LOGO OEM (BGRT)
        // Lục lọi ACPI -> Tìm BGRT -> Giải mã BMP -> Nã thẳng ra màn hình!
        // ==========================================================
        public static unsafe void DrawOEMLogo(ulong rsdpAddress, uint* fb, uint fbWidth, uint fbHeight, uint scanLine)
        {
            if (rsdpAddress == 0 || fb == null || fbWidth == 0 || fbHeight == 0 || scanLine == 0)
                return;

            byte* rsdp = (byte*)rsdpAddress;
            bool isAcpi2 = rsdp[15] >= 2; 
            
            ulong xsdtAddr = 0;
            if (isAcpi2) xsdtAddr = *(ulong*)(rsdp + 24);
            else xsdtAddr = *(uint*)(rsdp + 16);

            if (xsdtAddr == 0) return;

            ACPI_HEADER* xsdt = (ACPI_HEADER*)xsdtAddr;
            int entryCount = (int)(xsdt->Length - sizeof(ACPI_HEADER)) / (isAcpi2 ? 8 : 4);
            byte* entries = (byte*)xsdt + sizeof(ACPI_HEADER);

            if (xsdtAddr == 0 || xsdt->Length < sizeof(ACPI_HEADER)) return;

            // Kiểm tra xem entryCount có hợp lý không
            if (entryCount < 0 || entryCount > 100) return; // Giới hạn số lượng entry

            ACPI_BGRT* bgrt = null;

            // Truy quét toàn bộ ACPI Tables để tìm kho báu 'BGRT'
            for (int i = 0; i < entryCount; i++)
            {
                ulong entryAddr = isAcpi2 ? *(ulong*)(entries + i * 8) : *(uint*)(entries + i * 4);
                // Kiểm tra xem entryAddr có nằm trong phạm vi hợp lệ không
                if (entryAddr < 0x1000 || entryAddr > 0xFFFFFFFFFFFF) continue;
                
                ACPI_HEADER* header = (ACPI_HEADER*)entryAddr;
                
                // 0x54524742 chính là chữ "BGRT" viết ngược trong Little Endian
                if (header->Signature == 0x54524742) 
                {
                    // Kiểm tra kích thước của bảng BGRT
                    if (header->Length >= sizeof(ACPI_BGRT)) {
                        bgrt = (ACPI_BGRT*)entryAddr;
                        // Kiểm tra các trường quan trọng trong BGRT
                        if (bgrt->ImageAddress != 0) {
                            break;
                        }
                    }
                }
            }

            if (bgrt == null || bgrt->ImageAddress == 0) return;

            BMP_HEADER* bmp = (BMP_HEADER*)bgrt->ImageAddress;
            // 0x4D42 là chữ "BM" (Bitmap Signature)
            if (bmp->Signature != 0x4D42) return;

            // Kiểm tra kích thước BMP có hợp lý không
            if (bmp->Width <= 0 || bmp->Height == 0 || bmp->Width > fbWidth) return;

            byte* pixelData = (byte*)bmp + bmp->DataOffset;
            int width = bmp->Width;
            int height = bmp->Height;
            bool isBottomUp = true;
            if (height < 0) { height = -height; isBottomUp = false; }

            uint offsetX = bgrt->ImageOffsetX;
            uint offsetY = bgrt->ImageOffsetY;

            int bytesPerPixel = bmp->Bpp / 8;
            int pitch = (width * bytesPerPixel + 3) & ~3; // Padding 4 byte của chuẩn BMP

            // Kiểm tra xem pixelData có hợp lệ không
            if (pixelData == null) return;

            for (int y = 0; y < height; y++)
            {
                // Ảnh BMP thường bị lộn ngược (Bottom-up), nên phải xoay trục Y lại
                int drawY = (int)offsetY + (isBottomUp ? (height - 1 - y) : y); 
                if (drawY < 0 || drawY >= fbHeight) continue;

                for (int x = 0; x < width; x++)
                {
                    int drawX = (int)offsetX + x;
                    if (drawX < 0 || drawX >= fbWidth) continue;

                    byte* p = pixelData + (y * pitch) + (x * bytesPerPixel);
                    
                    uint color = 0;
                    if (bytesPerPixel == 3) {
                        color = (uint)(p[0] | (p[1] << 8) | (p[2] << 16) | (0xFF << 24));
                    } else if (bytesPerPixel == 4) {
                        color = (uint)(p[0] | (p[1] << 8) | (p[2] << 16) | (p[3] << 24));
                    }

                    // Không vẽ màu đen hoàn toàn (0x000000) để Logo hòa quyện vào màu nền của mình!
                    if ((color & 0x00FFFFFF) != 0) 
                    {
                        fb[drawY * scanLine + drawX] = color;
                    }
                }
            }
        }

        private static unsafe bool IsKernelMain(char* name) {
            // Kiểm tra con trữ không null
            if (name == null) return false;
            byte* n = (byte*)name;
            return n[0] == 'K' && n[1] == 'e' && n[2] == 'r' && n[3] == 'n' && n[4] == 'e' && n[5] == 'l' && n[6] == 'M' && n[7] == 'a' && n[8] == 'i' && n[9] == 'n' && n[10] == '\0';
        }

        [UnmanagedCallersOnly(EntryPoint = "memset")]
        public static unsafe void* MemSetInterop(void* ptr, int value, ulong num)
        {
            byte* p = (byte*)ptr;
            for (ulong i = 0; i < num; i++) {
                p[i] = (byte)value;
            }
            return ptr;
        }

        // ==========================================================
        // [VŨ KHÍ TỐI THƯỢNG] MEMCPY POLYFILL CHO LINKER!
        // Trị dứt điểm thói lanh chanh copy mảng .rdata của C# Compiler!
        // ==========================================================
        [UnmanagedCallersOnly(EntryPoint = "memcpy")]
        public static unsafe void* MemCpyInterop(void* dest, void* src, ulong count)
        {
            byte* d = (byte*)dest;
            byte* s = (byte*)src;
            for (ulong i = 0; i < count; i++) {
                d[i] = s[i];
            }
            return dest;
        }
        
        [UnmanagedCallersOnly(EntryPoint = "NekkoBoot")]
        public static long NekkoBoot(IntPtr imageHandle, EFI_SYSTEM_TABLE* systemTable)
        {
            InitSerial(); // MỞ MẮT TRUYỀN THÔNG!

            uint* frameBuffer = null; ulong frameBufferSize = 0; uint width = 0; uint height = 0; uint scanLine = 0;
            
            systemTable->ConOut->SetAttribute(systemTable->ConOut, 0x0A); 

            // fixed (char* msg = "NekkoOS EFI Stub\r\n") Print(systemTable->ConOut, msg);
            // fixed (char* msg1 = "Version 1.0\r\n") Print(systemTable->ConOut, msg1);
            // fixed (char* msg2 = "Architecture: x86_64\r\n") Print(systemTable->ConOut, msg2);
            // fixed (char* msg3 = "Copyright (C) 2026 - present Nekkochan. All right reserved.\r\n\r\n\n") Print(systemTable->ConOut, msg3);
            // fixed (char* buildDate = "NekkoOS EFI Stub 2026-03-03 11:42:25 AM UTC +7 nekkochan user/test-keys EFI\r\n") Print(systemTable->ConOut, buildDate);

            // ==========================================================
            // [VŨ KHÍ TỐI THƯỢNG] LẤY SỔ ĐỎ BẢO VỆ VÙNG ĐẤT THÁNH 0x8000!
            // Ép UEFI cấp phát ĐÚNG TẠI 0x8000 (Type 2 = AllocateAddress).
            // Xin hẳn 2 Pages (8KB, từ 0x8000 -> 0x9FFF). Đéo thằng nào được đụng vào!
            // ==========================================================
            ulong smpHolyLand = 0x8000;
            ulong reserveStatus = systemTable->BootServices->AllocatePages(2, 2, 2, &smpHolyLand);
            if (reserveStatus == 0) {
                fixed (char* rMsg = "[+] SMP Memory Land (0x8000-0x9FFF) Reserved Successfully!\r\n\0") Print(systemTable->ConOut, rMsg);
            } else {
                // Nếu đen lắm UEFI đang xài vùng này, thì cứ kệ mẹ nó, cầu nguyện tí nữa nó nhả ra.
                fixed (char* rErr = "[-] WARNING: 0x8000 is currently occupied by UEFI!\r\n\0") Print(systemTable->ConOut, rErr);
            }

            systemTable->ConOut->SetAttribute(systemTable->ConOut, 0x0E);

            ulong memoryMapSize = 0; EFI_MEMORY_DESCRIPTOR* memoryMap = null; ulong mapKey = 0; ulong descriptorSize = 0; uint descriptorVersion = 0;
            systemTable->BootServices->GetMemoryMap(&memoryMapSize, memoryMap, &mapKey, &descriptorSize, &descriptorVersion);
            memoryMapSize += descriptorSize * 4;
            void* buffer = null; systemTable->BootServices->AllocatePool(2, memoryMapSize, &buffer); memoryMap = (EFI_MEMORY_DESCRIPTOR *)buffer;
            systemTable->BootServices->GetMemoryMap(&memoryMapSize, memoryMap, &mapKey, &descriptorSize, &descriptorVersion);

            ulong totalPages = 0; ulong numEntries = memoryMapSize / descriptorSize; byte* mapPtr = (byte *)memoryMap;
            for (ulong i = 0; i < numEntries; i++) { EFI_MEMORY_DESCRIPTOR* desc = (EFI_MEMORY_DESCRIPTOR*)(mapPtr + (i * descriptorSize)); totalPages += desc->NumberOfPages; }

            ulong totalMB = (totalPages * 4096) / (1024 * 1024);

            fixed (char *msg4 = "Total RAM: ") Print(systemTable->ConOut, msg4);
            PrintNumber(systemTable->ConOut, totalMB);
            fixed (char *msg5 = " MB\r\nRAM detect OK!\r\n") Print(systemTable->ConOut, msg5);

            systemTable->ConOut->SetAttribute(systemTable->ConOut, 0x0F);

            EFI_GUID acpi20Guid = new EFI_GUID { Data1 = 0x8868e871, Data2 = 0xe4f1, Data3 = 0x11d3, D4_0 = 0xbc, D4_1 = 0x22, D4_2 = 0x00, D4_3 = 0x80, D4_4 = 0xc7, D4_5 = 0x3c, D4_6 = 0x88, D4_7 = 0x81 };
            EFI_GUID acpi10Guid = new EFI_GUID { Data1 = 0xeb9d2d30, Data2 = 0x2d88, Data3 = 0x11d3, D4_0 = 0x9a, D4_1 = 0x16, D4_2 = 0x00, D4_3 = 0x90, D4_4 = 0x27, D4_5 = 0x3f, D4_6 = 0xc1, D4_7 = 0x4d };
            ulong rsdpAddress = 0;

            for (ulong i = 0; i < systemTable->NumberOfTableEntries; i++) {
                EFI_GUID* guid = &systemTable->ConfigurationTable[i].VendorGuid;
                if (guid->Data1 == acpi20Guid.Data1 && guid->Data2 == acpi20Guid.Data2 && guid->Data3 == acpi20Guid.Data3 && guid->D4_0 == acpi20Guid.D4_0) {
                    rsdpAddress = (ulong)systemTable->ConfigurationTable[i].VendorTable;
                    fixed (char* m = "[+] ACPI 2.0 RSDP Found at ") Print(systemTable->ConOut, m);
                    PrintHex(systemTable->ConOut, rsdpAddress);
                    fixed (char* m_nl = "\r\n") Print(systemTable->ConOut, m_nl);
                    break;
                } else if (guid->Data1 == acpi10Guid.Data1 && guid->Data2 == acpi10Guid.Data2 && guid->Data3 == acpi10Guid.Data3 && guid->D4_0 == acpi10Guid.D4_0) {
                    rsdpAddress = (ulong)systemTable->ConfigurationTable[i].VendorTable;
                }
            }

            if (rsdpAddress == 0) {
                fixed (char* m = "[-] WARNING: ACPI RSDP NOT FOUND IN UEFI TABLES!\r\n") Print(systemTable->ConOut, m);
            }

            // ==========================================================
            // [BƯỚC 2] BẬT GOP VÀ BẮN LOGO THẲNG LÊN MÀN HÌNH NGAY!
            // Thời gian Load Kernel.exe từ lúc này sẽ được Logo che đậy!
            // ==========================================================
            EFI_GUID gopGuid = new EFI_GUID { Data1 = 0x9042a9de, Data2 = 0x23dc, Data3 = 0x4a38, D4_0 = 0x96, D4_1 = 0xfb, D4_2 = 0x7a, D4_3 = 0xde, D4_4 = 0xd0, D4_5 = 0x80, D4_6 = 0x51, D4_7 = 0x6a };
            void* gopInterface;
            ulong status = systemTable->BootServices->LocateProtocol(&gopGuid, null, &gopInterface);

            if (status == 0)
            {
                EFI_GRAPHICS_OUTPUT_PROTOCOL* gop = (EFI_GRAPHICS_OUTPUT_PROTOCOL*)gopInterface;
                width = gop->Mode->Info->HorizontalResolution;
                height = gop->Mode->Info->VerticalResolution;
                scanLine = gop->Mode->Info->PixelsPerScanLine;
                frameBuffer = (uint*)gop->Mode->FrameBufferBase;
                frameBufferSize = gop->Mode->FrameBufferSize;

                // 1. Đập nát cái nền xanh/hộp đỏ phèn ỉa cũ đi, tô nền Đen Tuyệt Đối!
                for (ulong i = 0; i < (gop->Mode->FrameBufferSize / 4); i++)
                {
                    frameBuffer[i] = 0xFF000000; 
                }

                // 2. Dùng phép triệu hồi BGRT! Vẽ Logo OEM lên nền đen!
                DrawOEMLogo(rsdpAddress, frameBuffer, width, height, scanLine);
            }

            EFI_GUID loadedImageGuid = new EFI_GUID { Data1 = 0x5B1B31A1, Data2 = 0x9562, Data3 = 0x11d2, D4_0 = 0x8E, D4_1 = 0x3F, D4_2 = 0x00, D4_3 = 0xA0, D4_4 = 0xC9, D4_5 = 0x69, D4_6 = 0x72, D4_7 = 0x3B };
            EFI_LOADED_IMAGE_PROTOCOL* loadedImage; systemTable->BootServices->HandleProtocol((void *)imageHandle, &loadedImageGuid, (void**)&loadedImage);

            EFI_GUID sfspGuid = new EFI_GUID { Data1 = 0x0964e5b22, Data2 = 0x6459, Data3 = 0x11d2, D4_0 = 0x8e, D4_1 = 0x39, D4_2 = 0x00, D4_3 = 0xa0, D4_4 = 0xc9, D4_5 = 0x69, D4_6 = 0x72, D4_7 = 0x3b };
            EFI_SIMPLE_FILE_SYSTEM_PROTOCOL* fileSystem; systemTable->BootServices->HandleProtocol(loadedImage->DeviceHandle, &sfspGuid, (void**)&fileSystem);

            EFI_FILE_PROTOCOL* rootDir; fileSystem->OpenVolume(fileSystem, &rootDir);
            EFI_FILE_PROTOCOL* kernelFile; long openStatus = 0;

            fixed (char* kernelPath = "Kernel.exe\0") { openStatus = (long)rootDir->Open(rootDir, &kernelFile, kernelPath, 1, 0); }
            if (openStatus != 0) {
                fixed (char* err = "LOI: Khong tim thay Kernel.exe tren dia!\r\n") Print(systemTable->ConOut, err);
                while(true);
            }

            EFI_GUID fileInfoGuid = new EFI_GUID { Data1 = 0x09576e92, Data2 = 0x6d3f, Data3 = 0x11d2, D4_0 = 0x8e, D4_1 = 0x39, D4_2 = 0x00, D4_3 = 0xa0, D4_4 = 0xc9, D4_5 = 0x69, D4_6 = 0x72, D4_7 = 0x3b };
            ulong infoSize = 0; kernelFile->GetInfo(kernelFile, &fileInfoGuid, &infoSize, null);
            void* infoBuffer = null; systemTable->BootServices->AllocatePool(2, infoSize, &infoBuffer);
            kernelFile->GetInfo(kernelFile, &fileInfoGuid, &infoSize, infoBuffer);

            ulong actualFileSize = ((EFI_FILE_INFO*)infoBuffer)->FileSize; systemTable->BootServices->FreePool(infoBuffer);
            void* tempBuffer = null; 
            systemTable->BootServices->AllocatePool(2, actualFileSize, &tempBuffer);
            if (tempBuffer == null) {
                fixed (char* err = "LOI: Khong du bo nho de doc Kernel.exe!\r\n") Print(systemTable->ConOut, err);
                while(true);
            }
            
            kernelFile->Read(kernelFile, &actualFileSize, tempBuffer);
            
            kernelFile->Close(kernelFile);

            // ==========================================================
            // [VERIFIED BOOT TIER 2] XÁC THỰC CHỮ KÝ SỐ RSA-2048
            // ==========================================================
            bool isVerified = true; // Mặc định là Thật, tìm thấy vết xước mới kết án!

            // 1. Đọc file Chữ ký số từ đĩa (Kernel.sig)
            EFI_FILE_PROTOCOL* sigFile = null;
            fixed (char* sigPath = "\\Kernel.exe.mui\0") {
                // [FIX LỖI 1] Ép kiểu thẳng tay thành (EFI_FILE_PROTOCOL**)
                status = rootDir->Open(rootDir, (EFI_FILE_PROTOCOL**)&sigFile, sigPath, 1, 0);
            }

            // [FIX LỖI 2] ĐÉO XÀI GOTO NỮA! Lỗi thì gán isVerified = false rồi cho chạy tuột xuống dưới!
            if (status != 0 || sigFile == null) {
                isVerified = false; 
            } 
            else 
            {
                ulong sigSize = 256; 
                byte* sigBuffer = stackalloc byte[256];
                sigFile->Read(sigFile, &sigSize, sigBuffer);
                sigFile->Close(sigFile);

                // 2. Băm SHA-256 từ file Kernel.exe thực tế
                byte* computedHash = stackalloc byte[32];
                BaremetalSHA256.Compute((byte*)tempBuffer, actualFileSize, computedHash);

                // ==========================================================
                // [FIX LỖI 3] MẢNG DUMMY CHUẨN C#!
                // Đéo dùng { } nữa. Để nguyên khai báo rỗng, PowerShell sẽ tự đắp thịt vào!
                // Mày BẮT BUỘC PHẢI GIỮ NGUYÊN dòng này, đéo được đổi 1 chữ!
                // ==========================================================
                byte* publicKeyN = stackalloc byte[256] { 0xE9, 0x23, 0x68, 0x7F, 0x0D, 0xDA, 0x2F, 0x01, 0x55, 0x1E, 0x4E, 0x46, 0x85, 0xAB, 0x31, 0xA6, 0xFE, 0x39, 0xA3, 0x76, 0xB7, 0xB8, 0x68, 0x8B, 0x5D, 0x9C, 0xD9, 0xF4, 0x27, 0xD3, 0x95, 0x0B, 0x56, 0x66, 0x9A, 0x9F, 0x7B, 0x75, 0x4D, 0xD4, 0xC5, 0x0B, 0x12, 0xE5, 0xC6, 0x98, 0x09, 0x75, 0x54, 0x69, 0x01, 0xA6, 0xEF, 0xE4, 0xE7, 0xC1, 0x37, 0xE7, 0x67, 0x22, 0x80, 0xFB, 0x8B, 0xED, 0x0F, 0x4F, 0x2B, 0xEC, 0xFD, 0xB7, 0xAE, 0x44, 0x1F, 0x5D, 0xCD, 0x58, 0xE0, 0xBA, 0x7F, 0x44, 0x1B, 0x0B, 0x92, 0xDD, 0x17, 0xB9, 0x8C, 0x6C, 0x12, 0xCE, 0x9A, 0x72, 0x73, 0xCC, 0x3F, 0x8E, 0x65, 0xC7, 0x92, 0x89, 0xAC, 0x40, 0xD2, 0xBF, 0x7B, 0x33, 0x3B, 0xCF, 0xBD, 0xA8, 0x69, 0xA0, 0x2D, 0x5D, 0x2F, 0x84, 0xBA, 0x08, 0x62, 0x44, 0xDB, 0xA2, 0xA5, 0xB1, 0xCB, 0x6F, 0xA1, 0x70, 0x45, 0xA0, 0xA5, 0x27, 0x60, 0x87, 0x70, 0x66, 0xF8, 0xEF, 0x84, 0x0C, 0x9A, 0x6F, 0x54, 0x29, 0x4D, 0x11, 0x49, 0xB5, 0x76, 0x82, 0xD7, 0x60, 0xDD, 0x36, 0x54, 0x54, 0x39, 0x2D, 0xFD, 0xC2, 0x82, 0x83, 0x18, 0x34, 0xE1, 0x23, 0xAB, 0x0C, 0x6B, 0xA6, 0x15, 0xD8, 0xDF, 0x5E, 0xC5, 0xBC, 0xBE, 0x04, 0x96, 0xFB, 0xE6, 0xCD, 0x6A, 0x5C, 0x93, 0x1B, 0x2C, 0x51, 0xF3, 0x8C, 0x8B, 0xAB, 0xDB, 0xCB, 0xB8, 0x26, 0x3B, 0x65, 0x22, 0x73, 0x9F, 0xC0, 0xFD, 0x8B, 0x2E, 0x1D, 0x12, 0x68, 0x79, 0xEB, 0x9A, 0xEC, 0x81, 0x80, 0x5B, 0xCE, 0x52, 0x43, 0xC2, 0x7A, 0xC5, 0x18, 0xB8, 0xFE, 0x7E, 0x6C, 0x51, 0xD6, 0xCC, 0xB5, 0xFD, 0x12, 0x69, 0xD5, 0x31, 0xBD, 0x88, 0x97, 0x8B, 0x4C, 0x89, 0x10, 0xC1, 0x4C, 0x18, 0xB6, 0xB4, 0x44, 0xCF, 0x72, 0x23, 0x27, 0xCB, 0xFC, 0x84, 0x81 }; /* INJECT_PUBKEY */

                // 4. Giải mã Chữ ký (Mở khóa RSA)
                // fixed (char* m_rsa = "[BOOT] Decrypting RSA-2048 Signature...\r\n\0") Print(systemTable->ConOut, m_rsa);
                
                // ==========================================================
                // [FIX CHÍ MẠNG] ĐẨY RSA LÊN HEAP (POOL) ĐỂ TRÁNH TRÀN STACK!
                // Cần: S(256) + N(256) + Res(256) + tempMul(512) + baseS(256) = 1536 Bytes.
                // Xin luôn 2048 Bytes (2KB) cho nó rộng rãi!
                // ==========================================================
                void* rsaBuffer = null;
                systemTable->BootServices->AllocatePool(2, 2048, &rsaBuffer);
                
                uint* S_buf = (uint*)rsaBuffer;
                uint* N_buf = S_buf + 64;       // Dịch đi 64 uint (256 bytes)
                uint* Res_buf = N_buf + 64;     // Dịch đi 256 bytes
                uint* tempMul_buf = Res_buf + 64; // Dịch đi 256 bytes
                uint* baseS_buf = tempMul_buf + 128; // Dịch đi 512 bytes
                
                byte* decryptedSig = stackalloc byte[256]; // Thằng output này nhỏ, để Stack cũng đc.
                
                BaremetalRSA.VerifySignature(sigBuffer, publicKeyN, decryptedSig, S_buf, N_buf, Res_buf, tempMul_buf, baseS_buf);
                
                // Dùng xong RSA thì dọn rác trả lại RAM cho UEFI!
                systemTable->BootServices->FreePool(rsaBuffer);

                // 5. Kiểm duyệt chuỗi đệm PKCS#1 v1.5 siêu gắt gao!
                if (decryptedSig[0] != 0x00 || decryptedSig[1] != 0x01) isVerified = false;
                for (int i = 2; i < 204; i++) { if (decryptedSig[i] != 0xFF) isVerified = false; }
                if (decryptedSig[204] != 0x00) isVerified = false;

                // Kiểm tra mã ASN.1 (Định danh thuật toán SHA-256)
                byte* asn1Magic = stackalloc byte[19] { 0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };
                for (int i = 0; i < 19; i++) {
                    if (decryptedSig[205 + i] != asn1Magic[i]) isVerified = false;
                }

                // KIỂM TRA CHỐT HẠ: Hash băm được CÓ KHỚP VỚI Hash trong chữ ký đập ra không?
                for (int i = 0; i < 32; i++) {
                    if (decryptedSig[224 + i] != computedHash[i]) isVerified = false;
                }
            }

            if (!isVerified)
            {
                // ==========================================================
                // [TỬ HÌNH MỸ THUẬT] PHONG CÁCH ANDROID VERIFIED BOOT
                // Nền đen tuyền, Icon tròn cảnh báo, chữ căn giữa lạnh lùng!
                // ==========================================================
                systemTable->ConOut->EnableCursor(systemTable->ConOut, false);
                systemTable->ConOut->SetAttribute(systemTable->ConOut, 0x0F); 
                systemTable->ConOut->ClearScreen(systemTable->ConOut); 

                int cx = (int)(width / 2);
                int cy = (int)(height / 3);
                int r = 40;

                if (frameBuffer != null) 
                {
                    for (ulong i = 0; i < (frameBufferSize / 4); i++) frameBuffer[i] = 0xFF000000;

                    for (int y = -r; y <= r; y++) {
                        for (int x = -r; x <= r; x++) {
                            if (x * x + y * y <= r * r) {
                                uint color = 0xFFDD0000; 
                                if (x >= -5 && x <= 5 && y >= -20 && y <= 5) color = 0xFF000000;
                                if (x >= -5 && x <= 5 && y >= 15 && y <= 25) color = 0xFF000000;
                                uint offset = (uint)((cy + y) * scanLine + (cx + x));
                                frameBuffer[offset] = color;
                            }
                        }
                    }
                }

                // ==========================================================
                // [FIX CHÍ MẠNG] CĂN TRỤC Y (DỌC) TỰ ĐỘNG BẰNG TOÁN HỌC!
                // Tính xem đáy của cái Icon cách đỉnh màn hình bao nhiêu Pixel.
                // Chiều cao 1 dòng Text UEFI chuẩn là khoảng 16 Pixel.
                // ==========================================================
                int cols = (int)(width / 8); 
                int targetRow = (cy + r + 1) / 16; // Cộng thêm 60 pixel lề (Margin) cho thoáng!

                fixed (char* nl = "\r\n\0") {
                    for(int i = 0; i < targetRow; i++) Print(systemTable->ConOut, nl);
                }

                // ==========================================================
                // CĂN TRỤC X (NGANG) TỰ ĐỘNG NHƯ VÒNG TRƯỚC
                // ==========================================================
                fixed (char* space = " \0") 
                {
                    int pad1 = (cols - 22) / 2;
                    for (int i = 0; i < pad1; i++) Print(systemTable->ConOut, space);
                    systemTable->ConOut->SetAttribute(systemTable->ConOut, 0x0C); 
                    fixed (char* err1 = "YOUR DEVICE IS CORRUPT\r\n\r\n\0") Print(systemTable->ConOut, err1);
                    
                    int pad2 = (cols - 39) / 2;
                    for (int i = 0; i < pad2; i++) Print(systemTable->ConOut, space);
                    systemTable->ConOut->SetAttribute(systemTable->ConOut, 0x0F); 
                    fixed (char* err2 = "It cannot be trusted and will not boot.\r\n\0") Print(systemTable->ConOut, err2);
                    
                    int pad3 = (cols - 38) / 2;
                    for (int i = 0; i < pad3; i++) Print(systemTable->ConOut, space);
                    fixed (char* err3 = "Please re-flash genuine NekkoOS image.\r\n\0") Print(systemTable->ConOut, err3);
                    
                    fixed (char* nl2 = "\r\n\0") Print(systemTable->ConOut, nl2);
                    int pad4 = (cols - 8) / 2;
                    for (int i = 0; i < pad4; i++) Print(systemTable->ConOut, space);
                    systemTable->ConOut->SetAttribute(systemTable->ConOut, 0x08); 
                    fixed (char* err4 = "g.co/ABH\r\n\0") Print(systemTable->ConOut, err4);
                }

                while (true) { } 
            }

            // fixed (char* m_pass = "[+] Kernel Integrity Verified (Secure Boot Green)!\r\n\0") Print(systemTable->ConOut, m_pass);

            byte* raw = (byte*)tempBuffer; int e_lfanew = *(int*)(raw + 0x3C); byte* nt = raw + e_lfanew;
            uint sizeOfImage = *(uint*)(nt + 80); uint sizeOfHeaders = *(uint*)(nt + 84);
            ulong pages = (sizeOfImage + 4095) / 4096; ulong kernelBase = 0; 
            ulong maxAddress = 0;
            for (ulong i = 0; i < numEntries; i++) {
                EFI_MEMORY_DESCRIPTOR* desc = (EFI_MEMORY_DESCRIPTOR*)(mapPtr + (i * descriptorSize));
                if (desc->Type == 7) { ulong endAddr = desc->PhysicalStart + (desc->NumberOfPages * 4096); if (endAddr > maxAddress) maxAddress = endAddr; }
            }

            // 1. GIỚI HẠN KASLR DƯỚI 1GB (0x40000000) ĐỂ CỨU CON TRỎ 32-BIT!
            if (maxAddress > 0x40000000) maxAddress = 0x40000000; 
            if (maxAddress < 0x02000000) maxAddress = 0x40000000; 
            
            ulong minAddress = 0x02000000; maxAddress -= (sizeOfImage + 0x100000);

            // Tung xúc xắc KASLR...
            bool kaslrSuccess = false;
            for (int attempts = 1; attempts < 1000; attempts++) {
                kernelBase = Random(systemTable, minAddress, maxAddress) & ~0xFFFUL; 
                ulong allocStatus = systemTable->BootServices->AllocatePages(2, 2, pages, &kernelBase);
                if (allocStatus == 0) { kaslrSuccess = true; break; }
            }

            if (!kaslrSuccess) {
                fixed (char* err = "Failed to find RAM space!\r\n") Print(systemTable->ConOut, err);
                while(true);
            }

            byte* kBase = (byte*)kernelBase;
            for (ulong i = 0; i < sizeOfImage; i++) kBase[i] = 0;
            for (uint i = 0; i < sizeOfHeaders; i++) kBase[i] = raw[i];

            ushort numSections = *(ushort*)(nt + 6); ushort optHeaderSize = *(ushort*)(nt + 20); byte* sectionTable = nt + 24 + optHeaderSize;
            for (int i = 0; i < numSections; i++) {
                byte* sec = sectionTable + (i * 40); uint vAddr = *(uint*)(sec + 12); uint rawSize = *(uint*)(sec + 16); uint rawPtr = *(uint*)(sec + 20);
                if (rawSize > 0) { for (uint j = 0; j < rawSize; j++) { kBase[vAddr + j] = raw[rawPtr + j]; } }
            }

            ulong originalImageBase = *(ulong*)(nt + 24 + 24); long delta = (long)kernelBase - (long)originalImageBase; 

            if (delta != 0) {
                uint relocRVA = *(uint*)(nt + 176); uint relocSize = *(uint*)(nt + 180);
                if (relocRVA != 0) {
                    byte* relocDir = kBase + relocRVA; uint bytesParsed = 0;
                    while (bytesParsed < relocSize) {
                        uint pageRva = *(uint*)(relocDir + bytesParsed); uint blockSize = *(uint*)(relocDir + bytesParsed + 4); 
                        if (blockSize == 0) break; 
                        uint relocEntriesCount = (blockSize - 8) / 2; ushort* entries = (ushort*)(relocDir + bytesParsed + 8);

                        // Giới hạn số lượng relocation entry
                        if (relocEntriesCount > 10000) break;
                        
                        for (uint i = 0; i < relocEntriesCount; i++) {
                            ushort entry = entries[i]; int type = entry >> 12; int offset = entry & 0xFFF;  
                            
                            // ==========================================================
                            // [ĐỘNG CƠ RELOCATION KÉP] Vá cả 64-bit và 32-bit!
                            // ==========================================================
                            if (type == 10) { 
                                ulong targetAddr = (ulong)(kBase + pageRva + offset);
                                // Kiểm tra xem targetAddr có nằm trong phạm vi của kernel image không
                                if (targetAddr >= (ulong)kBase && targetAddr < (ulong)kBase + sizeOfImage) {
                                    ulong* targetPtr = (ulong*)targetAddr; 
                                    *targetPtr = (ulong)((long)*targetPtr + delta); 
                                }
                            }
                            else if (type == 3) {
                                ulong targetAddr = (ulong)(kBase + pageRva + offset);
                                // Kiểm tra xem targetAddr có nằm trong phạm vi của kernel image không
                                if (targetAddr >= (ulong)kBase && targetAddr < (ulong)kBase + sizeOfImage) {
                                    uint* targetPtr = (uint*)targetAddr; 
                                    *targetPtr = (uint)((long)*targetPtr + delta); 
                                }
                            }
                        }
                        bytesParsed += blockSize;
                    }
                }
            }

            systemTable->BootServices->FreePool(tempBuffer);
            void* realEntry = GetKernelRealEntryPoint((void*)kernelBase); 
            if (realEntry == null) {
                fixed (char* err = "ERROR: KernelMain not found!\r\n") Print(systemTable->ConOut, err);
                while(true);
            }

            NekkoBootInfo* bootInfo = null; systemTable->BootServices->AllocatePool(6, (ulong)sizeof(NekkoBootInfo), (void**)&bootInfo);

            ulong finalMemoryMapSize = 0; EFI_MEMORY_DESCRIPTOR* finalMemoryMap = null; ulong finalMapKey = 0; ulong finalDescriptorSize = 0; uint finalDescriptorVersion = 0;
            systemTable->BootServices->GetMemoryMap(&finalMemoryMapSize, null, &finalMapKey, &finalDescriptorSize, &finalDescriptorVersion);
            ulong allocatedMapCapacity = finalMemoryMapSize + (finalDescriptorSize * 8);
            
            void* finalBuffer = null; systemTable->BootServices->AllocatePool(6, allocatedMapCapacity, &finalBuffer); 
            finalMemoryMap = (EFI_MEMORY_DESCRIPTOR*)finalBuffer;

            finalMemoryMapSize = allocatedMapCapacity;
            systemTable->BootServices->GetMemoryMap(&finalMemoryMapSize, finalMemoryMap, &finalMapKey, &finalDescriptorSize, &finalDescriptorVersion);

            bootInfo->FrameBufferBase = (ulong)frameBuffer; bootInfo->FrameBufferSize = frameBufferSize; bootInfo->HorizontalResolution = width; bootInfo->VerticalResolution = height; bootInfo->PixelsPerScanLine = scanLine;
            bootInfo->MemoryMap = (void*)finalMemoryMap; bootInfo->MemoryMapSize = finalMemoryMapSize; bootInfo->DescriptorSize = finalDescriptorSize; bootInfo->AcpiRsdp = rsdpAddress;

            // ==========================================================
            // [VŨ KHÍ TỐI THƯỢNG] GIAO THỨC BẮT TAY DEBUGGER (HANDSHAKE PROTOCOL)
            // ==========================================================
            // fixed (char* waitMsg = "\r\nNekkoOS EFI Stub (Version 2026.03.26) is loading...\r\n\0") Print(systemTable->ConOut, waitMsg);
            
            // Mở cửa sổ sinh tử 2000ms (2 giây)
            char magicKey = SerialReadCharWithTimeout(systemTable->BootServices, 2000); 

            if (magicKey == 'D' || magicKey == 'd') {
                // ==========================================================
                // [VŨ KHÍ TỐI THƯỢNG] NEKKO BOOTLOADER MINI SHELL!
                // ==========================================================
                fixed (char* ack = "\r\n[DEBUG] DEBUGGER ATTACHED!\r\n\0") Print(systemTable->ConOut, ack);
                fixed (char* help = "Type 'H' for Help.\r\n\0") Print(systemTable->ConOut, help);
                
                bool debugging = true;
                while (debugging) {
                    fixed (char* prompt = "NekkoBoot> \0") Print(systemTable->ConOut, prompt);
                    
                    char cmd = SerialReadChar(); // Chờ mày gõ lệnh
                    SerialWriteChar(cmd);        // Echo chữ mày vừa gõ
                    fixed (char* nl = "\r\n\0") Print(systemTable->ConOut, nl);

                    switch (cmd) {
                        case 'C': case 'c':
                            fixed (char* msgC = "[DEBUG] Resuming boot sequence...\r\n\0") Print(systemTable->ConOut, msgC);
                            debugging = false; 
                            break;
                            
                        case 'R': case 'r':
                            fixed (char* msgR = "[DEBUG] Cold Rebooting System...\r\n\0") Print(systemTable->ConOut, msgR);
                            systemTable->RuntimeServices->ResetSystem(0, 0, 0, null);
                            while(true); 
                            break;
                            
                        case 'M': case 'm':
                            fixed (char* msgM1 = "[DEBUG] Kernel Base Address : \0") Print(systemTable->ConOut, msgM1);
                            PrintHex(systemTable->ConOut, kernelBase);
                            fixed (char* msgM2 = "\r\n[DEBUG] ACPI RSDP Address   : \0") Print(systemTable->ConOut, msgM2);
                            PrintHex(systemTable->ConOut, rsdpAddress);
                            fixed (char* nlM = "\r\n\0") Print(systemTable->ConOut, nlM);
                            break;

                        // ==========================================================
                        // [VŨ KHÍ 1] DUMP PHYSICAL MEMORY (SOI RAM TRỰC TIẾP)
                        // Ví dụ: Gõ D -> gõ 8000 -> Nó sẽ in ra dữ liệu Trampoline của mày!
                        // ==========================================================
                        case 'D': case 'd':
                            fixed (char* msgD = "Enter Physical Address (Hex): 0x\0") Print(systemTable->ConOut, msgD);
                            ulong dumpAddr = SerialReadHex();
                            
                            ulong* ptr64 = (ulong*)dumpAddr; // Đọc 1 lần 8 bytes (64-bit)
                            
                            fixed (char* msgD2 = "[DEBUG] Dump 16-bytes at \0") Print(systemTable->ConOut, msgD2);
                            PrintHex(systemTable->ConOut, dumpAddr);
                            fixed (char* msgD3 = " => \0") Print(systemTable->ConOut, msgD3);
                            
                            // In ra 16 bytes (2 block 64-bit)
                            PrintHex(systemTable->ConOut, ptr64[0]);
                            fixed (char* space = "  \0") Print(systemTable->ConOut, space);
                            PrintHex(systemTable->ConOut, ptr64[1]);
                            fixed (char* nlD = "\r\n\0") Print(systemTable->ConOut, nlD);
                            break;

                        // ==========================================================
                        // [VŨ KHÍ 2] I/O PORT READER (ĐỌC CỔNG PHẦN CỨNG)
                        // Ví dụ: Gõ I -> gõ 21 -> Nó đọc PIC Mask Mask Register
                        // ==========================================================
                        case 'I': case 'i':
                            fixed (char* msgI = "Enter I/O Port (Hex): 0x\0") Print(systemTable->ConOut, msgI);
                            ushort port = (ushort)SerialReadHex();
                            byte val = In8(port);
                            
                            fixed (char* msgI2 = "[DEBUG] Port 0x\0") Print(systemTable->ConOut, msgI2);
                            PrintHex(systemTable->ConOut, (ulong)port);
                            fixed (char* msgI3 = " = 0x\0") Print(systemTable->ConOut, msgI3);
                            PrintHex(systemTable->ConOut, (ulong)val); // PrintHex in 64-bit, nhưng kệ, nó sẽ hiện 0x00...00XX
                            fixed (char* nlI = "\r\n\0") Print(systemTable->ConOut, nlI);
                            break;

                        // ==========================================================
                        // [VŨ KHÍ 3] ĐỌC ĐỒNG HỒ CMOS RTC (KHÔNG XÀI NGẮT)
                        // Chứng minh I/O Port hoạt động hoàn hảo!
                        // ==========================================================
                        case 'T': case 't':
                            Out8(0x70, 0x04); byte hrs = In8(0x71);
                            Out8(0x70, 0x02); byte mins = In8(0x71);
                            Out8(0x70, 0x00); byte secs = In8(0x71);
                            
                            fixed (char* msgT = "[DEBUG] Raw RTC Time (BCD): \0") Print(systemTable->ConOut, msgT);
                            fixed (char* space = "  \0")
                            {
                                PrintHex(systemTable->ConOut, (ulong)hrs); 
                                Print(systemTable->ConOut, space);
                            }
                            fixed (char* space = "  \0")
                            {
                                PrintHex(systemTable->ConOut, (ulong)mins); 
                                Print(systemTable->ConOut, space);
                            }
                            PrintHex(systemTable->ConOut, (ulong)secs); 
                            fixed (char* nlT = "\r\n\0") Print(systemTable->ConOut, nlT);
                            break;

                        // ==========================================================
                        // [VŨ KHÍ 4] KIỂM TRA TRẠNG THÁI FRAMEBUFFER GOP
                        // ==========================================================
                        case 'G': case 'g':
                            fixed (char* msgG1 = "[DEBUG] FrameBuffer Base : \0") Print(systemTable->ConOut, msgG1);
                            PrintHex(systemTable->ConOut, bootInfo->FrameBufferBase);
                            fixed (char* msgG2 = "\r\n[DEBUG] Resolution       : \0") Print(systemTable->ConOut, msgG2);
                            PrintNumber(systemTable->ConOut, bootInfo->HorizontalResolution);
                            fixed (char* msgX = " x \0") Print(systemTable->ConOut, msgX);
                            PrintNumber(systemTable->ConOut, bootInfo->VerticalResolution);
                            fixed (char* nlG = "\r\n\0") Print(systemTable->ConOut, nlG);
                            break;

                        case 'H': case 'h':
                            fixed (char* msgH = "Commands:\r\n [C]ontinue Boot\r\n [R]eboot\r\n [M]emory Base\r\n [D]ump RAM (Hex)\r\n [I]N Port (Hex)\r\n [T]ime RTC\r\n [G]OP Video Info\r\n [H]elp\r\n\0") Print(systemTable->ConOut, msgH);
                            break;

                        default:
                            fixed (char* msgErr = "Unknown command. Press 'H'.\r\n\0") Print(systemTable->ConOut, msgErr);
                            break;
                    }
                }
            } else {
                // ĐÉO CÓ TÍN HIỆU HOẶC GÕ SAI MÃ -> CHẠY THẲNG VÀO PRODUCTION MODE!
                fixed (char* skip = "[BOOT] No Debugger detected. Booting Production Mode...\r\n\0") Print(systemTable->ConOut, skip);
            }

            ulong exitStatus = systemTable->BootServices->ExitBootServices((void*)imageHandle, finalMapKey);
            if (exitStatus != 0) {
                finalMemoryMapSize = allocatedMapCapacity; 
                systemTable->BootServices->GetMemoryMap(&finalMemoryMapSize, finalMemoryMap, &finalMapKey, &finalDescriptorSize, &finalDescriptorVersion);
                bootInfo->MemoryMapSize = finalMemoryMapSize; 
                exitStatus = systemTable->BootServices->ExitBootServices((void*)imageHandle, finalMapKey);
                if (exitStatus != 0) while (true); 
            }

            delegate* unmanaged<NekkoBootInfo*, void> kernelMain = (delegate* unmanaged<NekkoBootInfo*, void>)realEntry;
            kernelMain(bootInfo); 

            while (true) ;
            return 0; 
        }

        [UnmanagedCallersOnly(EntryPoint = "__managed__Main")]
        public static int DummyMain(int argc, char** argv) { return 0; }
    }
}

namespace System.Runtime.CompilerServices { public class IsExternalInit {} }