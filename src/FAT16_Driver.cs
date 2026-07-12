// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoApp;

using static NekkoApp.API;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct SharedMemoryBlock {
    public fixed byte ShellCommandBuffer[4096];    
    public fixed byte FatRequestName[4096];        
    public fixed byte FatResponseData[8192];      
    public fixed byte AtaRawBuffer[4096];         
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct FATWorkspaceBlock {
    public fixed byte SectorBuf[512];       
    public fixed byte FatBuf[512];          
    public fixed byte FormattedName[16];    
    public fixed short PrivateName[256];    
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct FAT_DirectoryEntry { 
    public fixed byte Name[11];         
    public byte Attributes;             
    public ushort OwnerGID;             
    public ushort CreationTime;         
    public ushort CreationDate;         
    public ushort Permissions;          
    public ushort OwnerUID;             
    public ushort WriteTime;            
    public ushort WriteDate;            
    public ushort FirstClusterLow;      
    public uint FileSize;               
} 

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct FAT_BPB { public fixed byte JumpBoot[3]; public fixed byte OEMName[8]; public ushort BytesPerSector; public byte SectorsPerCluster; public ushort ReservedSectorCount; public byte NumFATs; public ushort RootEntryCount; public ushort TotalSectors16; public byte Media; public ushort FATSize16; public ushort SectorsPerTrack; public ushort NumberOfHeads; public uint HiddenSectors; public uint TotalSectors32; }

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct MBR_Partition { public byte Status; public fixed byte ChsFirst[3]; public byte Type; public fixed byte ChsLast[3]; public uint LbaStart; public uint SectorCount; }

public unsafe class Program
{
    public static uint ATA_PID = 0;

    public static Message* PendingQueue;
    public static int PendingHead = 0;
    public static int PendingTail = 0;
    public static int PENDING_MAX = 2048;

    public static byte* RecursePool;
    public static int NukeDepth = 0;

    public static void SyscallYieldApp() { SyscallYield(); }

    public const int R_OK = 4;
    public const int W_OK = 2;
    public const int X_OK = 1;

    public static SharedMemoryBlock* SharedMem = null;
    public static FAT_BPB CachedBPB;
    public static uint FatStartLba;
    public static uint RootDirLba;
    public static uint FirstDataSector;
    public static uint RootDirSectors;
    public static ushort CurrentDirCluster = 0;

    // [FIX BẢO MẬT] Kho mật khẩu (/ETC/PASSWD) chứa salt+hash - dù cũng là file mcopy
    // "không chủ" (OwnerUID=OwnerGID=0) như các binary hệ thống khác, nó KHÔNG được
    // hưởng quyền Đọc công khai giống SHELL.EXE/FAT16.EXE... - chỉ root mới đọc được,
    // giống quy ước /etc/shadow trên Unix (khác /etc/passwd thường world-readable vì
    // không chứa hash). Tên PASSWD ở đây đã cố định do build.sh luôn mcopy đúng 1 vị
    // trí, không phải nhận input động từ người dùng nên so khớp tên là an toàn.
    private static bool IsSecretName(byte* formattedName) {
        byte* target = stackalloc byte[11] { (byte)'P',(byte)'A',(byte)'S',(byte)'S',(byte)'W',(byte)'D',(byte)' ',(byte)' ',(byte)' ',(byte)' ',(byte)' ' };
        for (int i = 0; i < 11; i++) if (formattedName[i] != target[i]) return false;
        return true;
    }

    public static bool CheckAccess(uint cUID, uint cGID, ushort fUID, ushort fGID, ushort perms, int requestedMode)
    {
        // Kiểm tra xem các tham số có hợp lệ không
        if (cUID > 0xFFFFFFFF || cGID > 0xFFFFFFFF || fUID > 0xFFFF || fGID > 0xFFFF || perms > 0xFFFF || requestedMode < 0) {
            fixed(char* err = "[!] FATAL: Invalid parameters in CheckAccess!\n\0") SyscallPrint(err);
            return false;
        }

        if (cUID == 0) return true;

        // [FIX BẢO MẬT] File được `mcopy` thẳng lên đĩa lúc build (binary hệ thống:
        // SHELL.EXE, FAT16.EXE, TOP.EXE...) không đi qua WRITE handler của driver nên
        // KHÔNG hề có OwnerUID/OwnerGID/Permissions thật - các trường này thực chất là
        // byte ngày/giờ chuẩn của FAT bị tái sử dụng (mtools ghi ngày/giờ copy thật vào
        // đó), nên giá trị đọc được là rác chứ không phản ánh quyền hạn có chủ đích.
        //
        // [FIX BUG] Chỉ dựa vào OwnerUID (đè lên FstClusHI - LUÔN LUÔN = 0 trên FAT16,
        // vì không ổ FAT16 nào cần bit cao của số cluster) để nhận diện "file hệ thống
        // chưa có chủ", KHÔNG dựa thêm vào OwnerGID (đè lên NTRes + CrtTimeTenth - phần
        // trăm giây lúc tạo file, giá trị này ngẫu nhiên tuỳ thời điểm mcopy chạy, dễ
        // khác 0). Bản vá cũ đòi hỏi CẢ HAI đều bằng 0 nên chỉ những file may mắn có
        // CrtTimeTenth == 0 mới được coi là "chưa có chủ" - các file khác (như top.exe)
        // bị chặn Đọc/Thực thi hoàn toàn oan, dù bản thân file rõ ràng chưa từng được
        // driver gán chủ sở hữu qua WRITE handler. Với nhóm file này (OwnerUID==0), coi
        // như file hệ thống dùng chung: cho Đọc/Thực thi công khai, nhưng KHÔNG cho Ghi
        // (chỉ root mới sửa/xoá được).
        if (fUID == 0 && (requestedMode & W_OK) == 0) return true;

        if (perms > 511) perms = 493;

        int targetBits = 0;
        if (cUID == fUID) targetBits = (perms >> 6) & 0x07; 
        else if (cGID == fGID) targetBits = (perms >> 3) & 0x07; 
        else targetBits = perms & 0x07; 

        return (targetBits & requestedMode) == requestedMode;
    }

    public static void ReadSectorIPC(uint lba, byte* buffer)
    {
        if (buffer == null) return;

        SyscallSendIPC(ATA_PID, 10, lba); 
        Message res = default;
        int retryCount = 0; 

        while (true)
        {
            if (SyscallReceiveIPC(&res) == 1)
            {
                if (res.Sender == ATA_PID) 
                {
                    if (res.Type == 11) {
                        for (int i = 0; i < 512; i++) buffer[i] = SharedMem->AtaRawBuffer[i];
                        break; 
                    }
                    else if (res.Type == 111) {
                        retryCount++;
                        if (retryCount >= 5) { // Tăng lượt retry
                            fixed(char* err = "[!] FAT16: ATA is dead. Aborting ReadSector.\n\0") SyscallPrint(err);
                            break;
                        }
                        SyscallSendIPC(ATA_PID, 10, lba); 
                    }
                }
                else 
                {
                    // Lưu lại tin nhắn của App, nếu đầy hàng đợi thì in cảnh báo để debug
                    int nextHead = (PendingHead + 1) % PENDING_MAX;
                    if (nextHead != PendingTail) {
                        PendingQueue[PendingHead] = res;
                        PendingHead = nextHead;
                    } else {
                        fixed(char* warn = "[WARN] FAT Server PendingQueue OVERFLOW!\n\0") SyscallPrint(warn);
                    }
                }
            }
            else SyscallWaitIPC();
        }
    }

    public static void WriteSectorIPC(uint lba, byte* buffer)
    {
        // Kiểm tra xem buffer có null không
        if (buffer == null) {
            fixed(char* err = "[!] FATAL: Null buffer in WriteSectorIPC!\n\0") SyscallPrint(err);
            return;
        }
        
        // Kiểm tra xem lba có hợp lệ không
        if (lba > 0xFFFFFF) {
            fixed(char* err = "[!] FATAL: Invalid LBA address in WriteSectorIPC!\n\0") SyscallPrint(err);
            return;
        }
        
        for (int i = 0; i < 512; i++) SharedMem->AtaRawBuffer[i] = buffer[i];
        SyscallSendIPC(ATA_PID, 12, lba);
        Message res = default;
        int retryCount = 0;
        while (true) {
            if (SyscallReceiveIPC(&res) == 1) {
                if (res.Sender == ATA_PID) {
                    if (res.Type == 13) break;
                    else if (res.Type == 111) {
                        // [FIX BẢO MẬT - MEDIUM] Trước đây ACK lỗi (Type 111) từ ATA Daemon
                        // không khớp điều kiện nào ở đây (không phải Type 13 thành công, cũng
                        // không phải "sender khác ATA" để xếp hàng chờ) nên bị ÂM THẦM RƠI MẤT,
                        // khiến vòng lặp chờ ACK vô hạn, treo cả FAT16 Daemon (và mọi client
                        // đang chờ nó) khi ATA gặp lỗi ghi thật. Giờ xử lý đối xứng với
                        // ReadSectorIPC: thử gửi lại có giới hạn, bỏ cuộc nếu ATA thực sự hỏng
                        // thay vì treo cứng vô thời hạn.
                        retryCount++;
                        if (retryCount >= 5) {
                            fixed(char* err = "[!] FAT16: ATA is dead. Aborting WriteSector.\n\0") SyscallPrint(err);
                            break;
                        }
                        for (int i = 0; i < 512; i++) SharedMem->AtaRawBuffer[i] = buffer[i];
                        SyscallSendIPC(ATA_PID, 12, lba);
                    }
                }
                else {
                    int nextHead = (PendingHead + 1) % PENDING_MAX;
                    if (nextHead != PendingTail) { PendingQueue[PendingHead] = res; PendingHead = nextHead; }
                    else { fixed(char* warn = "[WARN] FAT Server PendingQueue OVERFLOW!\n\0") SyscallPrint(warn); }
                }
            }
            else SyscallWaitIPC();
        }
    }

    public static void FlushCacheIPC()
    {
        SyscallSendIPC(ATA_PID, 14, 0);
        Message res = default;
        int retryCount = 0;
        while (true) {
            if (SyscallReceiveIPC(&res) == 1) {
                if (res.Sender == ATA_PID) {
                    if (res.Type == 15) break;
                    else if (res.Type == 111) {
                        // [FIX BẢO MẬT - MEDIUM] Cùng lỗi mất ACK như WriteSectorIPC - Type 111
                        // (lỗi flush) trước đây không khớp nhánh nào, treo vô hạn.
                        retryCount++;
                        if (retryCount >= 5) {
                            fixed(char* err = "[!] FAT16: ATA is dead. Aborting FlushCache.\n\0") SyscallPrint(err);
                            break;
                        }
                        SyscallSendIPC(ATA_PID, 14, 0);
                    }
                }
                else {
                    int nextHead = (PendingHead + 1) % PENDING_MAX;
                    if (nextHead != PendingTail) { PendingQueue[PendingHead] = res; PendingHead = nextHead; }
                    else { fixed(char* warn = "[WARN] FAT Server PendingQueue OVERFLOW!\n\0") SyscallPrint(warn); }
                }
            }
            else SyscallWaitIPC();
        }
    }

    public static ushort GetFatEntry(ushort cluster, byte* fatBuf)
    {
        uint fatOffset = (uint)cluster * 2;
        uint fatSector = FatStartLba + CachedBPB.ReservedSectorCount + (fatOffset / 512);
        ReadSectorIPC(fatSector, fatBuf);
        return *(ushort*)(fatBuf + (fatOffset % 512));
    }

    public static void SetFatEntry(ushort cluster, ushort value, byte* fatBuf)
    {
        uint fatOffset = (uint)cluster * 2;
        uint fatSector = FatStartLba + CachedBPB.ReservedSectorCount + (fatOffset / 512);
        ReadSectorIPC(fatSector, fatBuf);
        ushort* ptr = (ushort*)(fatBuf + (fatOffset % 512));
        *ptr = value;
        WriteSectorIPC(fatSector, fatBuf); 
        WriteSectorIPC(fatSector + CachedBPB.FATSize16, fatBuf); 
    }

    public static void FormatFATName(char* input, byte* output)
    {
        // Kiểm tra xem các con trỏ có null không
        if (input == null || output == null) {
            fixed(char* err = "[!] FATAL: Null pointer in FormatFATName!\n\0") SyscallPrint(err);
            return;
        }

        for (int i = 0; i < 11; i++) output[i] = (byte)' ';
        int idx = 0;
        while (input[idx] != '.' && input[idx] != '\0' && idx < 8) {
            char c = input[idx]; if (c >= 'a' && c <= 'z') c = (char)(c - 32); 
            output[idx] = (byte)c; idx++;
        }
        if (input[idx] == '.') {
            idx++; int extIdx = 8;
            while (input[idx] != '\0' && extIdx < 11) {
                char c = input[idx]; if (c >= 'a' && c <= 'z') c = (char)(c - 32);
                output[extIdx] = (byte)c; idx++; extIdx++;
            }
        }
    }

    // ==========================================================
    // [FIX CHÍ MẠNG] SAN PHẲNG HÀM CỤC BỘ (FLATTENING)
    // Cấm dùng Closure Heap Allocation trên OS Zero-Stdlib!
    // ==========================================================
    private static int CheckSectorInline(byte* buf, byte* formattedName, ushort* outCluster, uint* outSize, byte* outAttr, ushort* outOwnerUID, ushort* outOwnerGID, ushort* outPerms) {
        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)buf;
        for (int i = 0; i < 16; i++) {
            if (entries[i].Name[0] == 0x00) return 2; // 2 = ABORT
            if (entries[i].Name[0] == 0xE5 || entries[i].Attributes == 0x0F || (entries[i].Attributes & 0x08) != 0) continue;
            bool match = true;
            for (int j = 0; j < 11; j++) if (entries[i].Name[j] != formattedName[j]) { match = false; break; }
            if (match) { 
                *outCluster = entries[i].FirstClusterLow; *outSize = entries[i].FileSize; *outAttr = entries[i].Attributes; 
                *outOwnerUID = entries[i].OwnerUID; *outOwnerGID = entries[i].OwnerGID; *outPerms = entries[i].Permissions;
                return 1; // 1 = FOUND
            }
        }
        return 0; // 0 = CONTINUE
    }

    private static bool FindEntry(char* name, ushort* outCluster, uint* outSize, byte* outAttr, ushort* outOwnerUID, ushort* outOwnerGID, ushort* outPerms, byte* sectorBuf, byte* fatBuf, byte* formattedName)
    {
        // Kiểm tra xem các con trỏ có null không
        if (name == null || outCluster == null || outSize == null || outAttr == null || 
            outOwnerUID == null || outOwnerGID == null || outPerms == null || 
            sectorBuf == null || fatBuf == null || formattedName == null) {
            fixed(char* err = "[!] FATAL: Null pointer in FindEntry!\n\0") SyscallPrint(err);
            return false;
        }

        if (name[0] == '.' && name[1] == '.' && name[2] == '\0') { formattedName[0] = (byte)'.'; formattedName[1] = (byte)'.'; for(int k=2; k<11; k++) formattedName[k] = (byte)' '; }
        else FormatFATName(name, formattedName);

        bool found = false;

        if (CurrentDirCluster == 0) {
            // Kiểm tra xem RootDirSectors có hợp lệ không
            if (RootDirSectors > 0x10000) {
                fixed(char* err = "[!] FATAL: Invalid root directory sectors in FindEntry!\n\0") SyscallPrint(err);
                return false;
            }

            for (uint s = 0; s < RootDirSectors; s++) { 
                ReadSectorIPC(RootDirLba + s, sectorBuf); 
                int st = CheckSectorInline(sectorBuf, formattedName, outCluster, outSize, outAttr, outOwnerUID, outOwnerGID, outPerms);
                if (st == 1) { found = true; break; }
                if (st == 2) break;
            }
        } else {
            ushort cluster = CurrentDirCluster;
            while (cluster >= 0x0002 && cluster <= 0xFFEF) {
                // Kiểm tra xem cluster có hợp lệ không
                if (cluster < 2 || cluster > 0xFFEF) {
                    fixed(char* err = "[!] FATAL: Invalid cluster number in FindEntry!\n\0") SyscallPrint(err);
                    return false;
                }

                uint clusterLba = FirstDataSector + ((uint)(cluster - 2) * (uint)CachedBPB.SectorsPerCluster);
                
                // Kiểm tra xem clusterLba có hợp lệ không
                if (clusterLba > 0xFFFFFF) {
                    fixed(char* err = "[!] FATAL: Invalid cluster LBA in FindEntry!\n\0") SyscallPrint(err);
                    return false;
                }

                bool abort = false;
                for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) { 
                    ReadSectorIPC(clusterLba + (uint)s, sectorBuf); 
                    int st = CheckSectorInline(sectorBuf, formattedName, outCluster, outSize, outAttr, outOwnerUID, outOwnerGID, outPerms);
                    if (st == 1) { found = true; break; }
                    if (st == 2) { abort = true; break; }
                }
                if (found || abort) break;
                uint fatOffset = (uint)cluster * 2; uint fatSector = FatStartLba + CachedBPB.ReservedSectorCount + (fatOffset / 512);
                
                // Kiểm tra xem fatSector có hợp lệ không
                if (fatSector > 0xFFFFFF) {
                    fixed(char* err = "[!] FATAL: Invalid FAT sector in FindEntry!\n\0") SyscallPrint(err);
                    return false;
                }

                ReadSectorIPC(fatSector, fatBuf); cluster = *(ushort*)(fatBuf + (fatOffset % 512));
            }
        }
        return *outSize > 0 || *outAttr != 0 || *outCluster != 0; 
    }

    // ==========================================================
    // SAN PHẲNG CÁC HÀM CỦA LỆNH LS (Tránh dùng stackalloc trong closure)
    // ==========================================================
    public static void AppendChar(char c, char* outStr, ref int outIdx, int maxChars) {
        // Kiểm tra xem các tham số có hợp lệ không
        if (outStr == null || outIdx < 0 || outIdx >= maxChars) {
            return;
        }
        
        if (outIdx < maxChars) outStr[outIdx++] = c;
    }
    public static void AppendStr(char* str, char* outStr, ref int outIdx, int maxChars) {
        int k = 0; while (str[k] != '\0') { AppendChar(str[k++], outStr, ref outIdx, maxChars); }
    }
    public static void AppendNumPadded(ulong num, char* outStr, ref int outIdx, int maxChars) {
        char* rev = stackalloc char[20]; int revCount = 0; ulong temp = num;
        if (temp == 0) { rev[revCount++] = '0'; } else { while(temp > 0) { rev[revCount++] = (char)('0' + (temp % 10)); temp /= 10; } }
        while(revCount > 0) { AppendChar(rev[--revCount], outStr, ref outIdx, maxChars); }
        int digits = 1; ulong t2 = num; while (t2 >= 10) { digits++; t2 /= 10; } if (num == 0) digits = 1;
        for (int s = 0; s < 10 - digits; s++) { fixed(char* sp = " \0") AppendStr(sp, outStr, ref outIdx, maxChars); }
    }
    public static void ProcessLSSector(byte* buf, char* outStr, ref int outIdx, int maxChars) {
        // Kiểm tra xem các con trỏ có null không
        if (buf == null || outStr == null) {
            fixed(char* err = "[!] FATAL: Null pointer in ProcessLSSector!\n\0") SyscallPrint(err);
            return;
        }
        
        // Kiểm tra xem outIdx có hợp lệ không
        if (outIdx < 0 || outIdx >= maxChars) {
            fixed(char* err = "[!] FATAL: Invalid output index in ProcessLSSector!\n\0") SyscallPrint(err);
            return;
        }

        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)buf;
        for (int i = 0; i < 16; i++) {
            if (entries[i].Name[0] == 0x00) return;
            if (entries[i].Name[0] == 0xE5 || entries[i].Attributes == 0x0F || (entries[i].Attributes & 0x08) != 0) continue;
            for (int j = 0; j < 11; j++) { char c = (char)entries[i].Name[j]; AppendChar((c >= 32 && c <= 126) ? c : ' ', outStr, ref outIdx, maxChars); }
            fixed(char* sep1 = " | \0") AppendStr(sep1, outStr, ref outIdx, maxChars);
            AppendNumPadded(entries[i].FileSize, outStr, ref outIdx, maxChars);
            fixed(char* sep2 = " bytes | \0") AppendStr(sep2, outStr, ref outIdx, maxChars);
            if ((entries[i].Attributes & 0x10) != 0) { fixed(char* dir = "<DIR>\n\0") AppendStr(dir, outStr, ref outIdx, maxChars); }
            else { fixed(char* file = "FILE\n\0") AppendStr(file, outStr, ref outIdx, maxChars); }
        }
    }

    // ==========================================================
    // SAN PHẲNG CÁC HÀM XỬ LÝ GHI (WRITE / MKDIR / RM)
    // ==========================================================
    private static void ProcessSilentRm(uint lba, byte* formattedName, ushort targetCluster, byte* fatBuf, byte* sectorBuf, ref bool deletedOld) {
        if (deletedOld) return;
        ReadSectorIPC(lba, sectorBuf);
        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)sectorBuf;
        for (int i = 0; i < 16; i++) {
            if (entries[i].Name[0] == 0x00) return;
            if (entries[i].Name[0] == 0xE5) continue;
            bool match = true;
            for(int j=0; j<11; j++) if(entries[i].Name[j] != formattedName[j]) { match = false; break; }
            if (match) {
                entries[i].Name[0] = 0xE5; WriteSectorIPC(lba, sectorBuf); 
                if (targetCluster >= 2) {
                    ushort cur = targetCluster;
                    while(cur >= 0x0002 && cur <= 0xFFEF) {
                        ushort next = GetFatEntry(cur, fatBuf);
                        SetFatEntry(cur, 0x0000, fatBuf); 
                        cur = next;
                    }
                }
                deletedOld = true; return;
            }
        }
    }

    private static void ProcessWriteSector(uint lba, byte* formattedName, ushort firstCluster, uint fileSize, uint callerUID, uint callerGID, byte* sectorBuf, ref bool saved) {
        if (saved) return;
        ReadSectorIPC(lba, sectorBuf);
        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)sectorBuf;
        for (int i = 0; i < 16; i++) {
            if (entries[i].Name[0] == 0x00 || entries[i].Name[0] == 0xE5) {
                for (int j = 0; j < 11; j++) entries[i].Name[j] = formattedName[j];
                entries[i].Attributes = 0x20; 
                entries[i].OwnerGID = (ushort)callerGID;
                entries[i].CreationTime = 0; entries[i].CreationDate = 0; 
                entries[i].Permissions = 420; 
                entries[i].WriteTime = 0; entries[i].WriteDate = 0;
                entries[i].OwnerUID = (ushort)callerUID;
                entries[i].FirstClusterLow = firstCluster; 
                entries[i].FileSize = fileSize;
                WriteSectorIPC(lba, sectorBuf); 
                saved = true; return;
            }
        }
    }

    private static void ProcessMkdirSector(uint lba, byte* formattedName, ushort newCluster, uint callerUID, uint callerGID, byte* sectorBuf, ref bool created) {
        if (created) return;
        ReadSectorIPC(lba, sectorBuf);
        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)sectorBuf;
        for(int i=0; i<16; i++) {
            if (entries[i].Name[0] == 0x00 || entries[i].Name[0] == 0xE5) {
                for(int j=0; j<11; j++) entries[i].Name[j] = formattedName[j];
                entries[i].Attributes = 0x10; entries[i].OwnerGID = (ushort)callerGID;
                entries[i].CreationTime = 0; entries[i].CreationDate = 0; entries[i].Permissions = 493; 
                entries[i].OwnerUID = (ushort)callerUID; entries[i].WriteTime = 0; entries[i].WriteDate = 0;
                entries[i].FirstClusterLow = newCluster; entries[i].FileSize = 0; 
                WriteSectorIPC(lba, sectorBuf); created = true; return;
            }
        }
    }

    private static void DoMkdir(char* privateName, uint effectiveOwnerUID, uint effectiveOwnerGID, uint callerUID, uint callerGID, uint client, byte* sectorBuf, byte* fatBuf, byte* formattedName, uint responseType) {
        FormatFATName(privateName, formattedName);

        bool canCreateHere = false;
        if (CurrentDirCluster == 0) {
            if (callerUID == 0) canCreateHere = true;
        } else {
            uint curDirLba = FirstDataSector + ((uint)(CurrentDirCluster - 2) * (uint)CachedBPB.SectorsPerCluster);
            ReadSectorIPC(curDirLba, sectorBuf);
            FAT_DirectoryEntry* dotEntry = (FAT_DirectoryEntry*)sectorBuf;
            if (CheckAccess(callerUID, callerGID, dotEntry[0].OwnerUID, dotEntry[0].OwnerGID, dotEntry[0].Permissions, W_OK)) canCreateHere = true;
        }

        ushort tmpCluster = 0; uint tmpSize = 0; byte tmpAttr = 0; ushort tmpOwner = 0; ushort tmpOwnerGID = 0; ushort tmpPerms = 0;
        if (FindEntry(privateName, &tmpCluster, &tmpSize, &tmpAttr, &tmpOwner, &tmpOwnerGID, &tmpPerms, sectorBuf, fatBuf, formattedName)) {
            SyscallSendIPC(client, responseType, 0); SyscallYieldApp(); return;
        } else {
            if (!canCreateHere) {
                fixed(char* err = "[!] Access Denied: You do not own or have Write (w) permission on this Directory!\n\0") SyscallPrint(err);
                SyscallSendIPC(client, responseType, 0); SyscallYieldApp(); return;
            }
        }

        ushort newCluster = 0;
        for (ushort c = 2; c < 0xFFEF; c++) {
            if (GetFatEntry(c, fatBuf) == 0x0000) { newCluster = c; SetFatEntry(c, 0xFFFF, fatBuf); break; }
        }

        if (newCluster == 0) { SyscallSendIPC(client, responseType, 0); SyscallYieldApp(); return; }

        uint newClusterLba = FirstDataSector + ((uint)(newCluster - 2) * (uint)CachedBPB.SectorsPerCluster);
        for(int b = 0; b < 512; b++) sectorBuf[b] = 0;
        for(int s = 0; s < CachedBPB.SectorsPerCluster; s++) { WriteSectorIPC(newClusterLba + (uint)s, sectorBuf); }

        ReadSectorIPC(newClusterLba, sectorBuf);
        FAT_DirectoryEntry* dotEntries = (FAT_DirectoryEntry*)sectorBuf;

        for(int i=0; i<11; i++) dotEntries[0].Name[i] = (byte)' ';
        dotEntries[0].Name[0] = (byte)'.'; dotEntries[0].Attributes = 0x10;
        dotEntries[0].OwnerUID = (ushort)effectiveOwnerUID; dotEntries[0].OwnerGID = (ushort)effectiveOwnerGID;
        dotEntries[0].Permissions = 493; dotEntries[0].FirstClusterLow = newCluster;

        for(int i=0; i<11; i++) dotEntries[1].Name[i] = (byte)' ';
        dotEntries[1].Name[0] = (byte)'.'; dotEntries[1].Name[1] = (byte)'.';
        dotEntries[1].Attributes = 0x10; dotEntries[1].OwnerUID = (ushort)effectiveOwnerUID;
        dotEntries[1].OwnerGID = (ushort)effectiveOwnerGID; dotEntries[1].Permissions = 493;
        dotEntries[1].FirstClusterLow = CurrentDirCluster;
        WriteSectorIPC(newClusterLba, sectorBuf);

        bool created = false;

        if (CurrentDirCluster == 0) {
            for(uint s=0; s<RootDirSectors; s++) ProcessMkdirSector(RootDirLba + s, formattedName, newCluster, effectiveOwnerUID, effectiveOwnerGID, sectorBuf, ref created);
        } else {
            ushort curClus = CurrentDirCluster;
            while(curClus >= 0x0002 && curClus <= 0xFFEF) {
                uint clusterLba = FirstDataSector + ((uint)(curClus - 2) * (uint)CachedBPB.SectorsPerCluster);
                for(int s=0; s<CachedBPB.SectorsPerCluster; s++) ProcessMkdirSector(clusterLba + (uint)s, formattedName, newCluster, effectiveOwnerUID, effectiveOwnerGID, sectorBuf, ref created);
                curClus = GetFatEntry(curClus, fatBuf);
            }
        }

        if (!created) {
            if (CurrentDirCluster == 0) {
                SetFatEntry(newCluster, 0x0000, fatBuf); FlushCacheIPC(); SyscallSendIPC(client, responseType, 0);
            } else {
                ushort lastCluster = CurrentDirCluster;
                while (true) {
                    ushort next = GetFatEntry(lastCluster, fatBuf);
                    if (next >= 0x0002 && next <= 0xFFEF) lastCluster = next; else break;
                }
                ushort expandCluster = 0;
                for (ushort c = 2; c < 0xFFEF; c++) {
                    if (GetFatEntry(c, fatBuf) == 0x0000) {
                        expandCluster = c; SetFatEntry(lastCluster, expandCluster, fatBuf); SetFatEntry(expandCluster, 0xFFFF, fatBuf); break;
                    }
                }
                if (expandCluster == 0) {
                    SetFatEntry(newCluster, 0x0000, fatBuf); FlushCacheIPC(); SyscallSendIPC(client, responseType, 0);
                } else {
                    uint expandLba = FirstDataSector + ((uint)(expandCluster - 2) * (uint)CachedBPB.SectorsPerCluster);
                    for (int b = 0; b < 512; b++) sectorBuf[b] = 0;
                    for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) { WriteSectorIPC(expandLba + (uint)s, sectorBuf); }
                    FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)sectorBuf;
                    for(int j=0; j<11; j++) entries[0].Name[j] = formattedName[j];
                    entries[0].Attributes = 0x10; entries[0].OwnerGID = (ushort)effectiveOwnerGID;
                    entries[0].CreationTime = 0; entries[0].CreationDate = 0; entries[0].Permissions = 493;
                    entries[0].OwnerUID = (ushort)effectiveOwnerUID; entries[0].WriteTime = 0; entries[0].WriteDate = 0;
                    entries[0].FirstClusterLow = newCluster; entries[0].FileSize = 0;
                    WriteSectorIPC(expandLba, sectorBuf); FlushCacheIPC(); SyscallSendIPC(client, responseType, 1);
                }
            }
        } else { FlushCacheIPC(); SyscallSendIPC(client, responseType, 1); }
    }

    // ==========================================================
    // [CHMOD/CHOWN] Quet 1 sector, neu khop ten thi sua Permissions va/hoac
    // OwnerUID/OwnerGID tai cho (khong xoa/di chuyen entry) - dung chung cho ca
    // hai lenh vi cung logic tim+sua-tai-cho, chi khac field nao duoc ap dung.
    // ==========================================================
    private static void ProcessChattrSector(uint lba, byte* formattedName, byte* sectorBuf, ref bool found, bool applyOwner, uint newUID, uint newGID, bool applyPerms, ushort newPerms) {
        if (found) return;
        ReadSectorIPC(lba, sectorBuf);
        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)sectorBuf;
        for (int i = 0; i < 16; i++) {
            if (entries[i].Name[0] == 0x00) return;
            if (entries[i].Name[0] == 0xE5) continue;
            bool match = true; for(int j=0; j<11; j++) if(entries[i].Name[j] != formattedName[j]) { match = false; break; }
            if (match) {
                if (applyOwner) { entries[i].OwnerUID = (ushort)newUID; entries[i].OwnerGID = (ushort)newGID; }
                if (applyPerms) { entries[i].Permissions = newPerms; }
                WriteSectorIPC(lba, sectorBuf); found = true; return;
            }
        }
    }

    // [CHMOD] Chi chu so huu (OwnerUID == callerUID) hoac root duoc phep doi
    // Permissions - dung UNIX semantics thong thuong (chmod cua chinh minh).
    private static void DoChmod(char* privateName, uint callerUID, uint callerGID, uint client, byte* sectorBuf, byte* fatBuf, byte* formattedName, ushort newPerms) {
        FormatFATName(privateName, formattedName);
        ushort curCluster = 0; uint curSize = 0; byte curAttr = 0; ushort curUID = 0, curGID = 0, curPerms = 0;
        if (!FindEntry(privateName, &curCluster, &curSize, &curAttr, &curUID, &curGID, &curPerms, sectorBuf, fatBuf, formattedName)) {
            SyscallSendIPC(client, 59, 0); SyscallYieldApp(); return;
        }
        if (callerUID != 0 && callerUID != curUID) {
            fixed(char* err = "[!] Access Denied: Only the owner or root can chmod this entry!\n\0") SyscallPrint(err);
            SyscallSendIPC(client, 59, 0); SyscallYieldApp(); return;
        }

        bool found = false;
        if (CurrentDirCluster == 0) {
            for (uint s = 0; s < RootDirSectors; s++) ProcessChattrSector(RootDirLba + s, formattedName, sectorBuf, ref found, false, 0, 0, true, newPerms);
        } else {
            ushort cur = CurrentDirCluster;
            while (cur >= 0x0002 && cur <= 0xFFEF) {
                uint clusterLba = FirstDataSector + ((uint)(cur - 2) * (uint)CachedBPB.SectorsPerCluster);
                for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) ProcessChattrSector(clusterLba + (uint)s, formattedName, sectorBuf, ref found, false, 0, 0, true, newPerms);
                cur = GetFatEntry(cur, fatBuf);
            }
        }
        if (found) { FlushCacheIPC(); SyscallSendIPC(client, 59, 1); } else SyscallSendIPC(client, 59, 0);
    }

    // [CHOWN] Chi root duoc phep doi OwnerUID/OwnerGID - giong UNIX (chown that
    // su chi root moi lam duoc, owner thuong khong the "cho" file cua minh).
    private static void DoChown(char* privateName, uint callerUID, uint callerGID, uint client, byte* sectorBuf, byte* fatBuf, byte* formattedName, uint newUID, uint newGID) {
        FormatFATName(privateName, formattedName);
        ushort curCluster = 0; uint curSize = 0; byte curAttr = 0; ushort curUID = 0, curGID = 0, curPerms = 0;
        if (!FindEntry(privateName, &curCluster, &curSize, &curAttr, &curUID, &curGID, &curPerms, sectorBuf, fatBuf, formattedName)) {
            SyscallSendIPC(client, 61, 0); SyscallYieldApp(); return;
        }
        if (callerUID != 0) {
            fixed(char* err = "[!] Access Denied: Only root can chown!\n\0") SyscallPrint(err);
            SyscallSendIPC(client, 61, 0); SyscallYieldApp(); return;
        }

        bool found = false;
        if (CurrentDirCluster == 0) {
            for (uint s = 0; s < RootDirSectors; s++) ProcessChattrSector(RootDirLba + s, formattedName, sectorBuf, ref found, true, newUID, newGID, false, 0);
        } else {
            ushort cur = CurrentDirCluster;
            while (cur >= 0x0002 && cur <= 0xFFEF) {
                uint clusterLba = FirstDataSector + ((uint)(cur - 2) * (uint)CachedBPB.SectorsPerCluster);
                for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) ProcessChattrSector(clusterLba + (uint)s, formattedName, sectorBuf, ref found, true, newUID, newGID, false, 0);
                cur = GetFatEntry(cur, fatBuf);
            }
        }
        // [FIX] Neu target la thu muc, phai cap nhat them entry "." ben trong no
        // de DoMkdir/CheckAccess (doc dotEntry[0].OwnerUID) phan anh dung owner moi.
        // curAttr da co tu FindEntry o tren; curCluster la first cluster cua thu muc do.
        if (found && (curAttr & 0x10) != 0 && curCluster >= 2) {
            uint dotLba = FirstDataSector + ((uint)(curCluster - 2) * (uint)CachedBPB.SectorsPerCluster);
            ReadSectorIPC(dotLba, sectorBuf);
            FAT_DirectoryEntry* dotEntries = (FAT_DirectoryEntry*)sectorBuf;
            // entry 0 = ".", entry 1 = ".."
            if (dotEntries[0].Name[0] == '.') {
                dotEntries[0].OwnerUID = (ushort)newUID;
                dotEntries[0].OwnerGID = (ushort)newGID;
                WriteSectorIPC(dotLba, sectorBuf);
            }
        }
        if (found) { FlushCacheIPC(); SyscallSendIPC(client, 61, 1); } else SyscallSendIPC(client, 61, 0);
    }

    private static void ProcessRmSector(uint lba, byte* formattedName, uint callerUID, uint callerGID, byte* fatBuf, byte* sectorBuf, ref bool deleted, ref bool isDirError, ref bool accessDenied) {
        if (deleted || isDirError || accessDenied) return;
        ReadSectorIPC(lba, sectorBuf); 
        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)sectorBuf;
        for (int i = 0; i < 16; i++) {
            if (entries[i].Name[0] == 0x00) return; 
            if (entries[i].Name[0] == 0xE5) continue;
            bool match = true; for(int j=0; j<11; j++) if(entries[i].Name[j] != formattedName[j]) { match = false; break; }
            if (match) {
                if (!CheckAccess(callerUID, callerGID, entries[i].OwnerUID, entries[i].OwnerGID, entries[i].Permissions, W_OK)) { accessDenied = true; return; }
                if ((entries[i].Attributes & 0x10) != 0) { isDirError = true; return; }
                ushort startCluster = entries[i].FirstClusterLow;
                entries[i].Name[0] = 0xE5; WriteSectorIPC(lba, sectorBuf); 
                if (startCluster >= 2) { 
                    ushort cur = startCluster; 
                    while(cur >= 0x0002 && cur <= 0xFFEF) { ushort next = GetFatEntry(cur, fatBuf); SetFatEntry(cur, 0x0000, fatBuf); cur = next; } 
                }
                deleted = true; return;
            }
        }
    }

    // ==========================================================
    // SAN PHẲNG ĐỆ QUY HỦY DIỆT (RM -RF)
    // ==========================================================
    public static void DestroyDirectory(ushort dirCluster, byte* fatBuf) 
    {
        if (dirCluster < 2 || dirCluster > 0xFFEF) return;
        
        // Kiểm xem fatBuf có null không
        if (fatBuf == null) {
            fixed(char* err = "[!] FATAL: Null FAT buffer in DestroyDirectory!\n\0") SyscallPrint(err);
            return;
        }

        if (NukeDepth >= 32) return; 

        byte* localBuf = RecursePool + (NukeDepth * 512);
        NukeDepth++; 

        ushort curClus = dirCluster;
        while(curClus >= 0x0002 && curClus <= 0xFFEF) {
            // Kiểm xem curClus có hợp lệ không
            if (curClus < 2 || curClus > 0xFFEF) {
                fixed(char* err = "[!] FATAL: Invalid cluster number in DestroyDirectory loop!\n\0") SyscallPrint(err);
                return;
            }

            uint clusterLba = FirstDataSector + ((uint)(curClus - 2) * (uint)CachedBPB.SectorsPerCluster);

            // Kiểm xem clusterLba có hợp lệ không
            if (clusterLba > 0xFFFFFF) {
                fixed(char* err = "[!] FATAL: Invalid cluster LBA in DestroyDirectory!\n\0") SyscallPrint(err);
                return;
            }

            for (int s=0; s<CachedBPB.SectorsPerCluster; s++) {
                uint lba = clusterLba + (uint)s;
                ReadSectorIPC(lba, localBuf);
                FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)localBuf;
                bool modified = false;

                for(int c=0; c<16; c++) {
                    if (entries[c].Name[0] == 0x00) break; 
                    if (entries[c].Name[0] == 0xE5) continue; 
                    bool isDot = (entries[c].Name[0] == '.' && entries[c].Name[1] == ' ');
                    bool isDotDot = (entries[c].Name[0] == '.' && entries[c].Name[1] == '.' && entries[c].Name[2] == ' ');
                    if (isDot || isDotDot) continue;

                    ushort itemCluster = entries[c].FirstClusterLow;
                    if ((entries[c].Attributes & 0x10) != 0) { DestroyDirectory(itemCluster, fatBuf); }

                    if (itemCluster >= 2) {
                        ushort fClus = itemCluster;
                        while(fClus >= 0x0002 && fClus <= 0xFFEF) {
                            // Kiểm xem fClus có hợp lệ không
                            if (fClus < 2 || fClus > 0xFFEF) {
                                fixed(char* err = "[!] FATAL: Invalid cluster number in DestroyDirectory FAT traversal!\n\0") SyscallPrint(err);
                                return;
                            }
                            
                            ushort next = GetFatEntry(fClus, fatBuf);
                            SetFatEntry(fClus, 0x0000, fatBuf); 
                            fClus = next;
                        }
                    }
                    entries[c].Name[0] = 0xE5; modified = true;
                }
                if (modified) WriteSectorIPC(lba, localBuf);
            }
            curClus = GetFatEntry(curClus, fatBuf);
        }
        NukeDepth--; 
    }

    private static void FindAndNuke(uint lba, byte* formattedName, uint callerUID, uint callerGID, byte* fatBuf, byte* sectorBuf, ref bool deleted, ref uint errorCode) {
        if (deleted || errorCode != 0) return;
        ReadSectorIPC(lba, sectorBuf);
        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)sectorBuf;
        for (int i = 0; i < 16; i++) {
            if (entries[i].Name[0] == 0x00) return; 
            if (entries[i].Name[0] == 0xE5) continue; 
            bool match = true;
            for(int j=0; j<11; j++) if(entries[i].Name[j] != formattedName[j]) { match = false; break; }
            
            if (match) {
                if (!CheckAccess(callerUID, callerGID, entries[i].OwnerUID, entries[i].OwnerGID, entries[i].Permissions, W_OK)) { errorCode = 4; return; }
                if ((entries[i].Attributes & 0x10) == 0) { errorCode = 2; return; }

                ushort targetCluster = entries[i].FirstClusterLow;
                DestroyDirectory(targetCluster, fatBuf);

                if (targetCluster >= 2) {
                    ushort cur = targetCluster;
                    while(cur >= 0x0002 && cur <= 0xFFEF) { ushort next = GetFatEntry(cur, fatBuf); SetFatEntry(cur, 0x0000, fatBuf); cur = next; }
                }
                entries[i].Name[0] = 0xE5; WriteSectorIPC(lba, sectorBuf); 
                deleted = true; errorCode = 1; return;
            }
        }
    }

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();
        
        fixed (char* ataName = "ATA.EXE\0") 
        {
            int pid = SyscallGetPIDByName(ataName);
            if (pid == -1) { fixed(char* e = "[!] FATAL: ATA.EXE Daemon not found! FAT16 Locked!\n\0") SyscallPrint(e); SyscallExit(); }
            ATA_PID = (uint)pid;
        }
        
        fixed(char* m1 = "[*] FAT Server (Ring 3) Initializing... Calling ATA via IPC...\n\0") SyscallPrint(m1);

        ulong workspaceAddr = SyscallAllocMem(1); 
        if (workspaceAddr == 0) {
            fixed(char* err = "[!] FATAL: Failed to allocate workspace memory in FAT16 Driver!\n\0") SyscallPrint(err);
            SyscallExit();
            return;
        }

        FATWorkspaceBlock* ws = (FATWorkspaceBlock*)workspaceAddr;
        
        byte* sectorBuf     = (byte*)ws->SectorBuf;             
        byte* fatBuf        = (byte*)ws->FatBuf;        
        byte* formattedName = (byte*)ws->FormattedName;
        char* privateName   = (char*)ws->PrivateName;

        PendingQueue = (Message*)SyscallAllocMem(1);
        if (PendingQueue == null) {
            fixed(char* err = "[!] FATAL: Failed to allocate pending queue in FAT16 Driver!\n\0") SyscallPrint(err);
            SyscallExit();
            return;
        }

        PendingHead = 0; PendingTail = 0;

        RecursePool = (byte*)SyscallAllocMem(4);
        if (RecursePool == null) {
            fixed(char* err = "[!] FATAL: Failed to allocate recurse pool in FAT16 Driver!\n\0") SyscallPrint(err);
            SyscallExit();
            return;
        }

        SharedMem = (SharedMemoryBlock*)SyscallGetSharedMem();
        if (SharedMem == null) {
            fixed(char* err = "[!] FATAL: Failed to get shared memory in FAT16 Driver!\n\0") SyscallPrint(err);
            SyscallExit();
            return;
        }

        ReadSectorIPC(0, sectorBuf); 

        bool isSuperFloppy = false;
        if (sectorBuf[0] == 0xEB && sectorBuf[2] == 0x90) isSuperFloppy = true;
        else if (sectorBuf[0] == 0xE9) isSuperFloppy = true;

        if (isSuperFloppy) FatStartLba = 0; 
        else {
            MBR_Partition* part1 = (MBR_Partition*)(sectorBuf + 446);
            if (part1->Type > 0 && part1->Type <= 0xFF && part1->LbaStart > 0) { 
                FatStartLba = part1->LbaStart; 
                ReadSectorIPC(FatStartLba, sectorBuf); 
            } else {
                fixed(char* err = "[!] FATAL: Invalid partition in FAT16 Driver!\n\0") SyscallPrint(err);
                SyscallExit();
                return;
            }
        }

        FAT_BPB* bpbPtr = (FAT_BPB*)sectorBuf; CachedBPB = *bpbPtr;
        if (CachedBPB.BytesPerSector == 0) CachedBPB.BytesPerSector = 512;
        RootDirSectors = ((uint)CachedBPB.RootEntryCount * 32 + (uint)CachedBPB.BytesPerSector - 1) / CachedBPB.BytesPerSector;
        RootDirLba = FatStartLba + CachedBPB.ReservedSectorCount + (uint)(CachedBPB.NumFATs * CachedBPB.FATSize16);
        FirstDataSector = RootDirLba + RootDirSectors;

        SyscallSendIPC(0, 39, 0);
        fixed(char* m2 = "[+] FAT Server (Ring 3) Online & Listening for File Requests!\n\0") SyscallPrint(m2);

        while (true)
        {
            Message msg = default;
            bool hasMsg = false;

            if (PendingHead != PendingTail) {
                msg = PendingQueue[PendingTail];
                PendingTail = (PendingTail + 1) % PENDING_MAX;
                hasMsg = true;
            }
            else if (SyscallReceiveIPC(&msg) == 1) {
                hasMsg = true;
            }

            if (hasMsg)
            {
                uint client = msg.Sender;
                uint callerUID = SyscallGetThreadUID(client);
                uint callerGID = SyscallGetThreadGID(client);

                if (msg.Type == 30) // READ
                {
                    char* sharedName = (char*)SharedMem->FatRequestName;
                    int n = 0; while(sharedName[n] != '\0' && n < 255) { privateName[n] = sharedName[n]; n++; }
                    privateName[n] = '\0';

                    ushort cluster = 0; uint fileSize = 0; byte attr = 0; 
                    ushort ownerUID = 0; ushort ownerGID = 0; ushort perms = 0;
                    
                    FindEntry(privateName, &cluster, &fileSize, &attr, &ownerUID, &ownerGID, &perms, sectorBuf, fatBuf, formattedName);

                    // [FIX BẢO MẬT - HIGH] Trước đây file có phần mở rộng .EXE được bỏ qua
                    // hoàn toàn kiểm tra quyền đọc (R_OK), bất kể chủ sở hữu/permission bits -
                    // cho phép user thường đọc nội dung bất kỳ file .EXE nào kể cả của root với
                    // quyền hạn chế (VD: 700). Giờ mọi loại file đều phải qua CheckAccess như nhau.
                    bool canReadFile = CheckAccess(callerUID, callerGID, ownerUID, ownerGID, perms, R_OK);
                    // [FIX BẢO MẬT] Riêng /ETC/PASSWD (chứa salt+hash) không được hưởng quyền
                    // "world-readable" mặc định của file hệ thống không chủ (xem CheckAccess) -
                    // chỉ root được đọc, bất kể callerUID/GID hay Permissions là gì.
                    if (IsSecretName(formattedName) && callerUID != 0) canReadFile = false;
                    if (cluster != 0 && !canReadFile) {
                        fixed (char* e = "[!] Access Denied: You do not have Read (r) permission for this file!\n\0") SyscallPrint(e);
                        SyscallSendIPC(client, 31, 0); SyscallYieldApp(); continue;
                    }

                    if (cluster == 0 && fileSize == 0) { SyscallSendIPC(client, 31, 0); SyscallYieldApp(); continue; }
                    SyscallSendIPC(client, 31, fileSize); 

                    Message ack = default;
                    while(true) { if (SyscallReceiveIPC(&ack) == 1 && ack.Type == 311 && ack.Sender == client) break; SyscallYieldApp(); }

                    uint bytesRead = 0;
                    byte* dataChunk = (byte*)SharedMem->FatResponseData; 

                    while (cluster >= 0x0002 && cluster <= 0xFFEF && bytesRead < fileSize) {
                        uint clusterLba = FirstDataSector + ((uint)(cluster - 2) * (uint)CachedBPB.SectorsPerCluster);
                        for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) {
                            if (bytesRead >= fileSize) break;
                            ReadSectorIPC(clusterLba + (uint)s, sectorBuf);
                            for (int b = 0; b < 512; b++) { if (bytesRead + b < fileSize) dataChunk[b] = sectorBuf[b]; }
                            SyscallSendIPC(client, 38, bytesRead); 
                            Message kAck = default;
                            while(true) { if (SyscallReceiveIPC(&kAck) == 1 && kAck.Type == 39 && kAck.Sender == client) break; SyscallYieldApp(); }
                            bytesRead += 512;
                        }
                        cluster = GetFatEntry(cluster, fatBuf); 
                    }
                    SyscallSendIPC(client, 42, 1);
                }
                else if (msg.Type == 32) // WRITE
                {
                    uint fileSize = (uint)msg.Payload;
                    if (CachedBPB.SectorsPerCluster == 0) CachedBPB.SectorsPerCluster = 1;
                    if (fileSize == 0) fileSize = 1;

                    // [FIX BẢO MẬT - LOW] Trước đây fileSize (client tự khai báo) không bị
                    // giới hạn, khiến "numClusters = (fileSize + clusterSize - 1) / clusterSize"
                    // có thể TRÀN SỐ uint khi fileSize gần UINT_MAX, làm numClusters tính sai
                    // (quá nhỏ) - cấp phát thiếu cluster so với dữ liệu client định gửi. Chặn
                    // ngay từ đầu bằng dung lượng đĩa THẬT lấy động từ BPB đã parse lúc mount
                    // (TotalSectors16/32, KHÔNG hardcode) - không file nào có thể lớn hơn cả ổ đĩa.
                    ulong bytesPerSectorU = (ulong)(CachedBPB.BytesPerSector == 0 ? 512 : CachedBPB.BytesPerSector);
                    ulong totalSectorsU = CachedBPB.TotalSectors32 != 0 ? CachedBPB.TotalSectors32 : CachedBPB.TotalSectors16;
                    ulong maxFileBytes = totalSectorsU * bytesPerSectorU;
                    if (maxFileBytes != 0 && fileSize > maxFileBytes) {
                        fixed(char* err = "[!] Access Denied: Declared file size exceeds disk capacity!\n\0") SyscallPrint(err);
                        SyscallSendIPC(client, 35, 0); SyscallYieldApp(); continue;
                    }

                    char* sharedName = (char*)SharedMem->FatRequestName;
                    int n = 0; while(sharedName[n] != '\0' && n < 255) { privateName[n] = sharedName[n]; n++; }
                    privateName[n] = '\0';

                    bool canCreateHere = false;
                    if (CurrentDirCluster == 0) {
                        if (callerUID == 0) canCreateHere = true; 
                    } else {
                        uint curDirLba = FirstDataSector + ((uint)(CurrentDirCluster - 2) * (uint)CachedBPB.SectorsPerCluster);
                        ReadSectorIPC(curDirLba, sectorBuf);
                        FAT_DirectoryEntry* dotEntry = (FAT_DirectoryEntry*)sectorBuf;
                        if (CheckAccess(callerUID, callerGID, dotEntry[0].OwnerUID, dotEntry[0].OwnerGID, dotEntry[0].Permissions, W_OK)) canCreateHere = true;
                    }

                    ushort existCluster = 0; uint existSize = 0; byte existAttr = 0; 
                    ushort existOwnerUID = 0; ushort existOwnerGID = 0; ushort existPerms = 0;
                    
                    if (FindEntry(privateName, &existCluster, &existSize, &existAttr, &existOwnerUID, &existOwnerGID, &existPerms, sectorBuf, fatBuf, formattedName)) 
                    {
                        if (!CheckAccess(callerUID, callerGID, existOwnerUID, existOwnerGID, existPerms, W_OK)) {
                            fixed(char* err = "[!] Access Denied: You do not have Write (w) permission for this file!\n\0") SyscallPrint(err);
                            SyscallSendIPC(client, 35, 0); SyscallYieldApp(); continue;
                        }

                        if ((existAttr & 0x10) != 0) {
                            fixed(char* err = "[!] Access Denied! Cannot overwrite a Directory.\n\0") SyscallPrint(err);
                            SyscallSendIPC(client, 35, 0); SyscallYieldApp(); continue;
                        }
                        
                        ushort targetCluster = existCluster; 
                        bool deletedOld = false;
                        
                        if (CurrentDirCluster == 0) {
                            for(uint s=0; s<RootDirSectors; s++) ProcessSilentRm(RootDirLba + s, formattedName, targetCluster, fatBuf, sectorBuf, ref deletedOld);
                        } else {
                            ushort curClus = CurrentDirCluster;
                            while(curClus >= 0x0002 && curClus <= 0xFFEF) {
                                uint clusterLba = FirstDataSector + ((uint)(curClus - 2) * (uint)CachedBPB.SectorsPerCluster);
                                for (int s=0; s<CachedBPB.SectorsPerCluster; s++) ProcessSilentRm(clusterLba + (uint)s, formattedName, targetCluster, fatBuf, sectorBuf, ref deletedOld);
                                curClus = GetFatEntry(curClus, fatBuf);
                            }
                        }
                        FlushCacheIPC();
                    }
                    else
                    {
                        if (!canCreateHere) {
                            fixed(char* err = "[!] Access Denied: You do not own this Directory! Cannot create files here.\n\0") SyscallPrint(err);
                            SyscallSendIPC(client, 35, 0); SyscallYieldApp(); continue;
                        }
                    }
                    
                    uint clusterSize = (uint)CachedBPB.SectorsPerCluster * 512;
                    uint numClusters = (fileSize + clusterSize - 1) / clusterSize;
                    if (numClusters == 0) numClusters = 1;

                    ushort firstCluster = 0; ushort prevCluster = 0; uint allocated = 0;

                    for (ushort c = 2; c < 0xFFEF; c++) {
                        if (GetFatEntry(c, fatBuf) == 0x0000) {
                            if (allocated == 0) firstCluster = c; else SetFatEntry(prevCluster, c, fatBuf);
                            SetFatEntry(c, 0xFFFF, fatBuf); prevCluster = c; allocated++;
                            if (allocated == numClusters) break;
                        }
                    }

                    if (allocated < numClusters) { SyscallSendIPC(client, 35, 0); SyscallYieldApp(); continue; }

                    uint bytesWritten = 0; ushort currentCluster = firstCluster;
                    byte* dataChunk = (byte*)SharedMem->FatResponseData;

                    while (currentCluster >= 2 && currentCluster <= 0xFFEF && bytesWritten < fileSize) {
                        uint clusterLba = FirstDataSector + ((uint)(currentCluster - 2) * (uint)CachedBPB.SectorsPerCluster);
                        for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) {
                            if (bytesWritten >= fileSize) break;
                            SyscallSendIPC(client, 33, bytesWritten); 
                            Message dataRes = default;
                            while(true) { if (SyscallReceiveIPC(&dataRes) == 1 && dataRes.Type == 34 && dataRes.Sender == client) break; SyscallYieldApp(); }

                            for (int b = 0; b < 512; b++) sectorBuf[b] = 0; 
                            for (int b = 0; b < 512 && bytesWritten < fileSize; b++) { sectorBuf[b] = dataChunk[b]; bytesWritten++; }
                            WriteSectorIPC(clusterLba + (uint)s, sectorBuf); 
                        }
                        currentCluster = GetFatEntry(currentCluster, fatBuf);
                    }

                    FormatFATName(privateName, formattedName);
                    bool saved = false;

                    if (CurrentDirCluster == 0) {
                        for (uint s = 0; s < RootDirSectors; s++) { ProcessWriteSector(RootDirLba + s, formattedName, firstCluster, fileSize, callerUID, callerGID, sectorBuf, ref saved); }
                    } else {
                        ushort curClus = CurrentDirCluster;
                        while (curClus >= 0x0002 && curClus <= 0xFFEF) {
                            uint clusterLba = FirstDataSector + ((uint)(curClus - 2) * (uint)CachedBPB.SectorsPerCluster);
                            for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) { ProcessWriteSector(clusterLba + (uint)s, formattedName, firstCluster, fileSize, callerUID, callerGID, sectorBuf, ref saved); }
                            curClus = GetFatEntry(curClus, fatBuf);
                        }
                    }

                    FlushCacheIPC();
                    
                    if (!saved) 
                    {
                        if (CurrentDirCluster == 0) {
                            FlushCacheIPC(); SyscallSendIPC(client, 35, 0); 
                        } else {
                            ushort lastCluster = CurrentDirCluster;
                            while (true) {
                                ushort next = GetFatEntry(lastCluster, fatBuf);
                                if (next >= 0x0002 && next <= 0xFFEF) lastCluster = next; else break;
                            }
                            ushort expandCluster = 0;
                            for (ushort c = 2; c < 0xFFEF; c++) {
                                if (GetFatEntry(c, fatBuf) == 0x0000) { 
                                    expandCluster = c;
                                    SetFatEntry(lastCluster, expandCluster, fatBuf);
                                    SetFatEntry(expandCluster, 0xFFFF, fatBuf);
                                    break;
                                }
                            }
                            if (expandCluster == 0) {
                                ushort rClus = firstCluster;
                                while(rClus >= 0x0002 && rClus <= 0xFFEF) {
                                    ushort nextClus = GetFatEntry(rClus, fatBuf);
                                    SetFatEntry(rClus, 0x0000, fatBuf);
                                    rClus = nextClus;
                                }
                                FlushCacheIPC(); SyscallSendIPC(client, 35, 0); 
                            } else {
                                uint expandLba = FirstDataSector + ((uint)(expandCluster - 2) * (uint)CachedBPB.SectorsPerCluster);
                                for (int b = 0; b < 512; b++) sectorBuf[b] = 0;
                                for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) { WriteSectorIPC(expandLba + (uint)s, sectorBuf); }

                                FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)sectorBuf;
                                for(int j=0; j<11; j++) entries[0].Name[j] = formattedName[j];
                                entries[0].Attributes = 0x20; entries[0].OwnerGID = (ushort)callerGID;
                                entries[0].CreationTime = 0; entries[0].CreationDate = 0; entries[0].Permissions = 420; 
                                entries[0].OwnerUID = (ushort)callerUID; entries[0].WriteTime = 0; entries[0].WriteDate = 0;
                                entries[0].FirstClusterLow = firstCluster;
                                entries[0].FileSize = fileSize; 
                                WriteSectorIPC(expandLba, sectorBuf);
                                FlushCacheIPC(); SyscallSendIPC(client, 35, 1);
                            }
                        }
                    } else { FlushCacheIPC(); SyscallSendIPC(client, 35, 1); }
                }
                else if (msg.Type == 36) // CD
                {
                    char* sharedName = (char*)SharedMem->FatRequestName;
                    int n = 0; while(sharedName[n] != '\0' && n < 255) { privateName[n] = sharedName[n]; n++; }
                    privateName[n] = '\0';

                    if (privateName[0] == '\\' && privateName[1] == '\0') { CurrentDirCluster = 0; SyscallSendIPC(client, 37, 1); continue; }
                    ushort cluster = 0; uint size = 0; byte attr = 0; 
                    ushort ownerUID = 0; ushort ownerGID = 0; ushort perms = 0;
                    FindEntry(privateName, &cluster, &size, &attr, &ownerUID, &ownerGID, &perms, sectorBuf, fatBuf, formattedName);
                
                    if ((attr & 0x10) != 0) { 
                        if (!CheckAccess(callerUID, callerGID, ownerUID, ownerGID, perms, X_OK)) {
                            fixed(char* e = "[!] Access Denied: You do not have Execute (x) permission to enter this directory!\n\0") SyscallPrint(e);
                            SyscallSendIPC(client, 37, 0);
                        } else { CurrentDirCluster = cluster; SyscallSendIPC(client, 37, 1); }
                    } else SyscallSendIPC(client, 37, 0);
                }
                else if (msg.Type == 40) // LS
                {
                    char* outStr = (char*)SharedMem->FatResponseData; 
                    int outIdx = 0; int maxChars = 4000; 

                    if (CurrentDirCluster == 0) {
                        for (uint s = 0; s < RootDirSectors; s++) {
                            if (outIdx >= maxChars) break; 
                            ReadSectorIPC(RootDirLba + s, sectorBuf); ProcessLSSector(sectorBuf, outStr, ref outIdx, maxChars);
                        }
                    } else {
                        ushort cluster = CurrentDirCluster;
                        while (cluster >= 0x0002 && cluster <= 0xFFEF) {
                            if (outIdx >= maxChars) break;
                            uint clusterLba = FirstDataSector + ((uint)(cluster - 2) * (uint)CachedBPB.SectorsPerCluster);
                            for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) { ReadSectorIPC(clusterLba + (uint)s, sectorBuf); ProcessLSSector(sectorBuf, outStr, ref outIdx, maxChars); }
                            cluster = GetFatEntry(cluster, fatBuf);
                        }
                    }
                    outStr[outIdx] = '\0'; SyscallSendIPC(client, 41, 1);
                }
                else if (msg.Type == 44) // MKDIR
                {
                    char* sharedName = (char*)SharedMem->FatRequestName;
                    int n = 0; while(sharedName[n] != '\0' && n < 255) { privateName[n] = sharedName[n]; n++; }
                    privateName[n] = '\0';
                    DoMkdir(privateName, callerUID, callerGID, callerUID, callerGID, client, sectorBuf, fatBuf, formattedName, 45);
                }
                else if (msg.Type == 56) // MKDIR_AS - chi root duoc phep chi dinh owner khac cho thu muc moi
                {
                    if (callerUID != 0) {
                        fixed(char* err = "[!] Access Denied: MKDIR_AS requires root privileges!\n\0") SyscallPrint(err);
                        SyscallSendIPC(client, 57, 0); SyscallYieldApp(); continue;
                    }

                    char* sharedName = (char*)SharedMem->FatRequestName;
                    int n = 0; while(sharedName[n] != '\0' && n < 255) { privateName[n] = sharedName[n]; n++; }
                    privateName[n] = '\0';

                    int p = n + 1; uint targetUID = 0, targetGID = 0;
                    while (sharedName[p] != '\0' && sharedName[p] >= '0' && sharedName[p] <= '9') { targetUID = targetUID * 10 + (uint)(sharedName[p] - '0'); p++; }
                    if (sharedName[p] == ':') p++;
                    while (sharedName[p] != '\0' && sharedName[p] >= '0' && sharedName[p] <= '9') { targetGID = targetGID * 10 + (uint)(sharedName[p] - '0'); p++; }

                    DoMkdir(privateName, targetUID, targetGID, callerUID, callerGID, client, sectorBuf, fatBuf, formattedName, 57);
                }
                else if (msg.Type == 58) // CHMOD - path\0mode(decimal)\0
                {
                    char* sharedName = (char*)SharedMem->FatRequestName;
                    int n = 0; while(sharedName[n] != '\0' && n < 255) { privateName[n] = sharedName[n]; n++; }
                    privateName[n] = '\0';

                    int p = n + 1; uint mode = 0;
                    while (sharedName[p] != '\0' && sharedName[p] >= '0' && sharedName[p] <= '9') { mode = mode * 10 + (uint)(sharedName[p] - '0'); p++; }

                    DoChmod(privateName, callerUID, callerGID, client, sectorBuf, fatBuf, formattedName, (ushort)mode);
                }
                else if (msg.Type == 60) // CHOWN - path\0uid:gid\0
                {
                    char* sharedName = (char*)SharedMem->FatRequestName;
                    int n = 0; while(sharedName[n] != '\0' && n < 255) { privateName[n] = sharedName[n]; n++; }
                    privateName[n] = '\0';

                    int p = n + 1; uint targetUID = 0, targetGID = 0;
                    while (sharedName[p] != '\0' && sharedName[p] >= '0' && sharedName[p] <= '9') { targetUID = targetUID * 10 + (uint)(sharedName[p] - '0'); p++; }
                    if (sharedName[p] == ':') p++;
                    while (sharedName[p] != '\0' && sharedName[p] >= '0' && sharedName[p] <= '9') { targetGID = targetGID * 10 + (uint)(sharedName[p] - '0'); p++; }

                    DoChown(privateName, callerUID, callerGID, client, sectorBuf, fatBuf, formattedName, targetUID, targetGID);
                }
                else if (msg.Type == 46) // RM
                {
                    char* sharedName = (char*)SharedMem->FatRequestName; int n = 0;
                    // [FIX BẢO MẬT - CRITICAL] Chặn tràn bộ nhớ: các handler khác đều giới hạn
                    // n < 255 khi copy tên file từ shared memory (client-controlled, tối đa 4096
                    // byte) vào privateName (chỉ 256 phần tử) - riêng RM trước đây thiếu điều
                    // kiện này, cho phép ghi tràn ra ngoài buffer và phá hỏng vùng nhớ kế cận.
                    while(sharedName[n] != '\0' && n < 255) { privateName[n] = sharedName[n]; n++; } privateName[n] = '\0';
                    FormatFATName(privateName, formattedName);

                    bool deleted = false; bool isDirError = false; bool accessDenied = false;

                    if (CurrentDirCluster == 0) { for(uint s=0; s<RootDirSectors; s++) ProcessRmSector(RootDirLba + s, formattedName, callerUID, callerGID, fatBuf, sectorBuf, ref deleted, ref isDirError, ref accessDenied); } 
                    else { ushort cluster = CurrentDirCluster; while(cluster >= 0x0002 && cluster <= 0xFFEF) { 
                        uint clusterLba = FirstDataSector + ((uint)(cluster - 2) * (uint)CachedBPB.SectorsPerCluster); 
                        for (int s=0; s<CachedBPB.SectorsPerCluster; s++) ProcessRmSector(clusterLba + (uint)s, formattedName, callerUID, callerGID, fatBuf, sectorBuf, ref deleted, ref isDirError, ref accessDenied); cluster = GetFatEntry(cluster, fatBuf); 
                    } }
                    FlushCacheIPC();
                    if (accessDenied) { fixed(char* err = "[!] Access Denied! You do not own this file.\n\0") SyscallPrint(err); SyscallSendIPC(client, 47, 0); } 
                    else if (isDirError) { SyscallSendIPC(client, 47, 2); } else { SyscallSendIPC(client, 47, deleted ? 1UL : 0UL); }
                }
                else if (msg.Type == 48) // RM -RF
                {
                    char* sharedName = (char*)SharedMem->FatRequestName; int n = 0; while(sharedName[n] != '\0' && n < 255) { privateName[n] = sharedName[n]; n++; } privateName[n] = '\0';
                    FormatFATName(privateName, formattedName);
                    if (formattedName[0] == (byte)'.') { SyscallSendIPC(client, 49, 0); SyscallYieldApp(); continue; }

                    bool deleted = false; uint errorCode = 0; 

                    if (CurrentDirCluster == 0) { for(uint s=0; s<RootDirSectors; s++) FindAndNuke(RootDirLba + s, formattedName, callerUID, callerGID, fatBuf, sectorBuf, ref deleted, ref errorCode); }
                    else { ushort cluster = CurrentDirCluster; while(cluster >= 0x0002 && cluster <= 0xFFEF) { 
                        uint clusterLba = FirstDataSector + ((uint)(cluster - 2) * (uint)CachedBPB.SectorsPerCluster); 
                        for (int s=0; s<CachedBPB.SectorsPerCluster; s++) FindAndNuke(clusterLba + (uint)s, formattedName, callerUID, callerGID, fatBuf, sectorBuf, ref deleted, ref errorCode); cluster = GetFatEntry(cluster, fatBuf); 
                    } }
                    FlushCacheIPC();
                    
                    if (errorCode == 4) { fixed(char* err = "[!] Access Denied! You do not own this directory.\n\0") SyscallPrint(err); SyscallSendIPC(client, 49, 0); } 
                    else { SyscallSendIPC(client, 49, errorCode); }
                }
                else if (msg.Type == 0xDEAD) {
                    fixed(char* dieMsg = "\n[*] FAT16: SIGTERM received. Sweeping workspace and signing off. Goodbye!\n\0") SyscallPrint(dieMsg);
                    // [FIX AN TOÀN SHUTDOWN] Đảm bảo mọi cache còn dang dở được đẩy xuống
                    // ATA trước khi thoát - phòng thân cho các đường ghi tương lai không
                    // flush ngay sau mỗi thao tác. An toàn vì Power.cs giờ luôn giữ ATA
                    // Daemon sống tới sau cùng, nên IPC này chắc chắn có người nhận.
                    FlushCacheIPC();
                    SyscallExit();
                }
            }
            else SyscallWaitIPC();
        }
    }
    public static void Main() { }
}