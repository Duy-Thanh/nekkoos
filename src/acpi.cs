using System.Runtime.InteropServices;
namespace NekkoApp;

using static NekkoApp.API;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct RSDPDescriptor { 
    public fixed byte Signature[8]; 
    public byte Checksum; 
    public fixed byte OEMID[6]; 
    public byte Revision; 
    public uint RsdtAddress; 
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct RSDPDescriptor20 { 
    public RSDPDescriptor FirstPart;
    public uint Length;
    public ulong XsdtAddress;
    public byte ExtendedChecksum;
    public fixed byte Reserved[3];
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct ACPISDTHeader {
    public fixed byte Signature[4];
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
public unsafe struct MADT {
    public ACPISDTHeader Header;
    public uint LocalApicAddress;
    public uint Flags;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct FADT {
    public ACPISDTHeader Header;
    public uint FirmwareCtrl;
    public uint Dsdt;
    public byte Reserved;
    public byte PreferredPowerManagementProfile;
    public ushort SCI_Interrupt;
    public uint SMI_CommandPort;
    public byte AcpiEnable;
    public byte AcpiDisable;
    public byte S4BIOS_REQ;
    public byte PSTATE_Control;
    public uint PM1aEventBlock;
    public uint PM1bEventBlock;
    public uint PM1aControlBlock;
    public uint PM1bControlBlock;
    public uint PM2ControlBlock;
    public uint PMTimerBlock;
    public uint GPE0Block;
    public uint GPE1Block;
    public byte PM1EventLength;
    public byte PM1ControlLength;
    public byte PM2ControlLength;
    public byte PMTimerLength;
    public byte GPE0Length;
    public byte GPE1Length;
    public byte GPE1Base;
    public byte CStateControl;
    public ushort WorstC2Latency;
    public ushort WorstC3Latency;
    public ushort FlushSize;
    public ushort FlushStride;
    public byte DutyOffset;
    public byte DutyWidth;
    public byte DayAlarm;
    public byte MonthAlarm;
    public byte Century;
    public ushort BootArchitectureFlags;
    public byte Reserved2;
    public uint Flags; 
    public byte ResetRegAddressSpace;
    public byte ResetRegBitWidth;
    public byte ResetRegBitOffset;
    public byte ResetRegAccessSize;
    public ulong ResetRegAddress;
    public byte ResetValue; 
    
    // ==========================================================
    // [FIX CHÍ MẠNG] BỔ SUNG TRƯỜNG EXTENDED ACPI 2.0 (UEFI OVMF)!
    // Phải có X_Dsdt (64-bit) thì mới húp được RAM trên 4GB!
    // ==========================================================
    public fixed byte Reserved3[3];
    public ulong X_FirmwareCtrl;
    public ulong X_Dsdt; 
}

public unsafe class Program
{
    public static void PrintHex(ulong number) {
        char* buffer = stackalloc char[19]; 
        buffer[0] = '0'; 
        buffer[1] = 'x';
        buffer[18] = '\0';
        char* hexChars = stackalloc char[16] { '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F' };
        for (int i = 0; i < 16; i++) { 
            int nibble = (int)((number >> ((15 - i) * 4)) & 0xF); 
            buffer[2 + i] = hexChars[nibble]; 
        }
        SyscallPrint(buffer);
    }
    public static void PrintNewline() { 
        fixed(char* nl = "\n\0")
        SyscallPrint(nl);
    }

    public static void PrintDec(uint num) {
        if (num == 0) {
            char* z = stackalloc char[2];
            z[0]='0';
            z[1]='\0';
            SyscallPrint(z);
            return;
        }

        char* rev = stackalloc char[16];
        int c = 0;
        while(num > 0) {
            rev[c++] = (char)('0' + (num % 10));
            num /= 10;
        }
        char* prt = stackalloc char[16]; int idx = 0;
        while(c > 0) {
            prt[idx++] = rev[--c];
        }
        prt[idx] = '\0';
        SyscallPrint(prt);
    }

    public static uint PM1a_Control_Port = 0;
    public static uint SMI_Command_Port = 0;
    public static byte ACPI_Enable_Cmd = 0;

    public static uint AcpiFlags = 0;
    public static byte ResetSpace = 0;
    public static ulong ResetAddress = 0;
    public static byte ResetValueData = 0;

    public static ushort SLP_TYPa = 0;
    public static ushort SLP_TYPb = 0;

    // ==========================================================
    // [VŨ KHÍ TỐI THƯỢNG] HÀM MAP RAM VẬT LÝ BẤT BẠI!
    // Bù đắp phần bị lệch lề (Offset) để trỏ chính xác tuyệt đối 100%!
    // Chống cạn kiệt PMM, chống đọc rác gây GPF!
    // ==========================================================
    public static ulong MapACPI(ulong physAddr, uint sizeBytes)
    {
        ulong offset = physAddr & 0xFFFUL;
        ulong basePhys = physAddr & ~0xFFFUL;
        ulong numPages = (sizeBytes + offset + 4095) / 4096;
        ulong virtBase = SyscallMapPhys(basePhys, numPages);
        if (virtBase == 0) return 0;
        return virtBase + offset;
    }

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();

        fixed(char* m = "\n[*] ACPI Daemon (Ring 3): Booting up Power Management Protocol...\n\0") SyscallPrint(m);

        ulong rsdpPhys = SyscallGetRsdp();
        if (rsdpPhys == 0) SyscallExit();

        // Lấy RSDP với hàm bọc thép!
        ulong rsdpVirt = MapACPI(rsdpPhys, (uint)sizeof(RSDPDescriptor20));
        RSDPDescriptor20* rsdp = (RSDPDescriptor20*)rsdpVirt;

        bool useXsdt = (rsdp->FirstPart.Revision >= 2) && (rsdp->XsdtAddress != 0);
        ulong sdtPhys = useXsdt ? rsdp->XsdtAddress : rsdp->FirstPart.RsdtAddress;

        // Đọc Header trước để lấy chiều dài thật của Bảng!
        ulong sdtVirtTemp = MapACPI(sdtPhys, (uint)sizeof(ACPISDTHeader));
        uint sdtRealLength = ((ACPISDTHeader*)sdtVirtTemp)->Length;
        
        // Map lại với chiều dài đúng 100%!
        ulong sdtVirt = MapACPI(sdtPhys, sdtRealLength);
        ACPISDTHeader* sdtHeader = (ACPISDTHeader*)sdtVirt;

        // CỰC KỲ AN TOÀN!
        int entriesCount = (int)((sdtRealLength - sizeof(ACPISDTHeader)) / (useXsdt ? 8 : 4));
        
        // [FIX CHÍ MẠNG] BẢO VỆ PMM KHỎI RÁC!
        if (entriesCount > 500) {
            fixed(char* e = "[!] ACPI FATAL: XSDT Length seems corrupted! Aborting.\n\0") SyscallPrint(e);
            SyscallExit();
        }

        byte* entriesPtr = (byte*)sdtVirt + sizeof(ACPISDTHeader);

        for (int i = 0; i < entriesCount; i++)
        {
            ulong entryPhys = useXsdt ? *(ulong*)(entriesPtr + (i * 8)) : *(uint*)(entriesPtr + (i * 4));
            if (entryPhys == 0) continue;

            // Đọc Header để lấy Length
            ulong tempEntryVirt = MapACPI(entryPhys, (uint)sizeof(ACPISDTHeader));
            uint entryLen = ((ACPISDTHeader*)tempEntryVirt)->Length;
            
            ulong entryVirt = MapACPI(entryPhys, entryLen);
            ACPISDTHeader* header = (ACPISDTHeader*)entryVirt;

            if (header->Signature[0] == 'A' && header->Signature[1] == 'P' && header->Signature[2] == 'I' && header->Signature[3] == 'C')
            {
                MADT* madt = (MADT*)entryVirt;
                SyscallReportHardware(1, madt->LocalApicAddress);

                fixed(char* pMadt = "[+] MADT Parsed! Local APIC Base: \0") SyscallPrint(pMadt);
                PrintHex(madt->LocalApicAddress);
                PrintNewline();

                byte* ptr = (byte*)madt + sizeof(MADT);
                byte* end = (byte*)madt + madt->Header.Length;
                
                uint cpuCores = 0;
                uint ioApicCount = 0;

                while (ptr < end) {
                    byte type = ptr[0];
                    byte length = ptr[1];
                    
                    // ==========================================================
                    // [FIX CHÍ MẠNG] CHỐNG LẶP VÔ TẠN KHI GẶP RÁC!
                    // ==========================================================
                    if (length == 0) break; 
                    
                    if (type == 0) { 
                        uint flags = *(uint*)(ptr + 4);
                        if ((flags & 1) != 0) cpuCores++; 
                    }
                    else if (type == 1) { 
                        uint ioApicAddr = *(uint*)(ptr + 4);
                        SyscallReportHardware(3, ioApicAddr);
                        ioApicCount++;
                    }
                    ptr += length;
                }

                SyscallReportHardware(2, cpuCores);
            }

            if (header->Signature[0] == 'F' && header->Signature[1] == 'A' && header->Signature[2] == 'C' && header->Signature[3] == 'P')
            {
                FADT* fadt = (FADT*)entryVirt;
                PM1a_Control_Port = fadt->PM1aControlBlock;
                SMI_Command_Port = fadt->SMI_CommandPort;
                ACPI_Enable_Cmd = fadt->AcpiEnable;

                if (header->Length >= 129) {
                    AcpiFlags = fadt->Flags;
                    ResetSpace = fadt->ResetRegAddressSpace;
                    ResetAddress = fadt->ResetRegAddress;
                    ResetValueData = fadt->ResetValue;
                }

                if (PM1a_Control_Port != 0) {
                    SyscallGrantPort((ushort)PM1a_Control_Port);
                    SyscallGrantPort((ushort)(PM1a_Control_Port + 1));
                }
                if (SMI_Command_Port != 0) {
                    SyscallGrantPort((ushort)SMI_Command_Port);
                    SyscallGrantPort((ushort)(SMI_Command_Port + 1));
                }

                fixed(char* m1 = "[+] FADT Parsed! PM1a Port: \0") {
                    SyscallPrint(m1);
                    PrintHex(PM1a_Control_Port);
                    PrintNewline();
                }

                // ==========================================================
                // LẤY DSDT BẰNG 64-BIT X_DSDT CHO UEFI OVMF!
                // ==========================================================
                ulong actualDsdtPhys = (header->Length >= 148 && fadt->X_Dsdt != 0) ? fadt->X_Dsdt : fadt->Dsdt;
                
                if (actualDsdtPhys != 0)
                {
                    ulong dsdtHdrVirt = MapACPI(actualDsdtPhys, (uint)sizeof(ACPISDTHeader));
                    uint dsdtLen = ((ACPISDTHeader*)dsdtHdrVirt)->Length;

                    ulong dsdtVirt = MapACPI(actualDsdtPhys, dsdtLen); 
                    ACPISDTHeader* dsdt = (ACPISDTHeader*)dsdtVirt;

                    if (dsdt->Signature[0] == 'D' && dsdt->Signature[1] == 'S' && dsdt->Signature[2] == 'D' && dsdt->Signature[3] == 'T')
                    {
                        byte* S5Addr = (byte*)dsdtVirt + sizeof(ACPISDTHeader);
                        int dsdtLength = (int)dsdt->Length - sizeof(ACPISDTHeader);
                        
                        while (0 < dsdtLength--)
                        {
                            if (S5Addr[0] == '_' && S5Addr[1] == 'S' && S5Addr[2] == '5' && S5Addr[3] == '_') break;
                            S5Addr++;
                        }
                        
                        if (dsdtLength > 0)
                        {
                            if ((S5Addr[-1] == 0x08 || (S5Addr[-2] == 0x08 && S5Addr[-1] == '\\')) && S5Addr[4] == 0x12)
                            {
                                S5Addr += 5;
                                S5Addr += ((S5Addr[0] & 0xC0) >> 6) + 2; 
                                
                                if (S5Addr[0] == 0x0A) S5Addr++; 
                                SLP_TYPa = (ushort)(S5Addr[0] << 10); 
                                S5Addr++;
                                
                                if (S5Addr[0] == 0x0A) S5Addr++; 
                                SLP_TYPb = (ushort)(S5Addr[0] << 10); 
                                
                                fixed(char* s5msg = "[+] AML Hack: Found DSDT \\_S5_. Dynamic Shutdown Armed!\n\0") SyscallPrint(s5msg);
                            }
                        }
                    }
                }
            }

            if (header->Signature[0] == 'H' && header->Signature[1] == 'P' && header->Signature[2] == 'E' && header->Signature[3] == 'T') {
                fixed(char* p = "[+] HPET (High Precision Event Timer) Detected!\n\0") SyscallPrint(p);
            }
            if (header->Signature[0] == 'M' && header->Signature[1] == 'C' && header->Signature[2] == 'F' && header->Signature[3] == 'G') {
                fixed(char* p = "[+] MCFG (PCI Express Config Space) Detected!\n\0") SyscallPrint(p);
            }
        }

        fixed(char* done = "[+] ACPI Daemon Armed & Listening for IPC Commands...\n\0") SyscallPrint(done);

        while (true)
        {
            Message msg = default;
            if (SyscallReceiveIPC(&msg) == 1)
            {
                if (msg.Type == 0xDEAD) 
                {
                    fixed(char* pOff = "\n[!] ACPI Daemon: SHUTDOWN SEQUENCE INITIATED!\n\0") SyscallPrint(pOff);
                    
                    if (SMI_Command_Port != 0 && ACPI_Enable_Cmd != 0) { 
                        AppOutByte((ushort)SMI_Command_Port, ACPI_Enable_Cmd); 
                        int timeout = 5000;
                        while ((AppInWord((ushort)PM1a_Control_Port) & 1) == 0 && timeout > 0) { SyscallYieldApp(); timeout--; }
                    }

                    if (PM1a_Control_Port != 0) { 
                        if (SLP_TYPa == 0) {
                            fixed(char* warn = "    -> [!] SLP_TYPa is 0! Overriding with QEMU/VBox S5 Standard (0x1400)...\n\0") SyscallPrint(warn);
                            SLP_TYPa = (5 << 10); 
                        }

                        ushort pm1a = AppInWord((ushort)PM1a_Control_Port);
                        pm1a = (ushort)(pm1a & 0x00FF); 
                        
                        AppOutWord((ushort)PM1a_Control_Port, (ushort)(pm1a | SLP_TYPa | 0x2000)); 
                    }

                    fixed(char* pFail = "[!!!] ACPI DAEMON SHUTDOWN FAILED! HALTING.\n\0") SyscallPrint(pFail);
                    while(true) SyscallWaitIPC();
                }
                else if (msg.Type == 0xBEEF)
                {
                    fixed(char* pReboot = "\n[!] ACPI Daemon: REBOOT SEQUENCE INITIATED!\n\0") SyscallPrint(pReboot);
                    
                    if ((AcpiFlags & (1 << 10)) != 0 && ResetAddress != 0) 
                    {
                        if (ResetSpace == 1) 
                        {
                            fixed(char* r1 = "    -> Routing via System I/O Bus...\n\0") SyscallPrint(r1);
                            SyscallGrantPort((ushort)ResetAddress);
                            AppOutByte((ushort)ResetAddress, ResetValueData);
                        }
                        else if (ResetSpace == 0) 
                        {
                            fixed(char* r2 = "    -> Routing via Memory-Mapped IO...\n\0") SyscallPrint(r2);
                            ulong resetVirt = MapACPI(ResetAddress, 1);
                            byte* resetPtr = (byte*)resetVirt;
                            *resetPtr = ResetValueData;
                        }
                        else if (ResetSpace == 2) 
                        {
                            fixed(char* r3 = "    -> Routing via PCI Configuration Space...\n\0") SyscallPrint(r3);
                            uint bus = 0;
                            uint slot = (uint)((ResetAddress >> 32) & 0xFFFF);
                            uint func = (uint)((ResetAddress >> 16) & 0xFFFF);
                            uint offset = (uint)(ResetAddress & 0xFFFF);

                            uint pciAddr = (uint)((1 << 31) | (bus << 16) | (slot << 11) | (func << 8) | (offset & 0xFC));
                            
                            SyscallGrantPort(0xCF8); SyscallGrantPort(0xCF9); SyscallGrantPort(0xCFA); SyscallGrantPort(0xCFB);
                            SyscallGrantPort(0xCFC); SyscallGrantPort(0xCFD); SyscallGrantPort(0xCFE); SyscallGrantPort(0xCFF);
                            
                            AppOutDword(0xCF8, pciAddr);
                            AppOutByte((ushort)(0xCFC + (offset & 3)), ResetValueData);
                        }
                    }
                    else 
                    {
                        fixed(char* noSup = "    -> [!] FADT lacks Reset Register! Engaging Legacy PCI Reset...\n\0") SyscallPrint(noSup);
                        
                        SyscallGrantPort(0xCF9);
                        AppOutByte(0xCF9, 0x02); 
                        for(int delay = 0; delay < 100000; delay++) {} 
                        AppOutByte(0xCF9, 0x06); 
                        
                        fixed(char* ps2Sup = "    -> [!] PCI Reset failed! Engaging PS/2 Keyboard Controller Hard-Reset...\n\0") SyscallPrint(ps2Sup);
                        
                        SyscallGrantPort(0x64);
                        while ((AppInByte(0x64) & 0x02) != 0) { SyscallYieldApp(); } 
                        AppOutByte(0x64, 0xFE); 
                    }
                    
                    fixed(char* fReboot = "[!!!] ALL REBOOT METHODS FAILED! HALTING.\n\0") SyscallPrint(fReboot);
                    while(true) SyscallYieldApp(); 
                }
            }
            else { SyscallWaitIPC(); }
        }
    }

    public static void Main() { }
}