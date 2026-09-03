// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// [ARCH] RegisterContext (layout frame x86_64) đã tách sang
// src/arch/x86_64/ContextLayout.cs - kernel generic không định nghĩa
// layout thanh ghi. [ARCH ABI] Đã migrate: mọi truy cập qua ArchCtx
// (GetNumber/GetArg/SetRet/SetRet2) - port arch chỉ cần sửa ContextLayout.cs.

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct ProcessInfo
{
    public uint ID; public uint UID; public uint GID;
    public byte Active; public byte IsJailed; public byte IsPhantomDead;
    public ulong HeapMemory; public fixed byte Name[16];
    public ulong CpuTicks; public uint PhysPages; public uint VirtPages; 
}

public static unsafe class Syscall
{
    // [PASCAL PORT] User pointer validation ported to syscall_security.pas
    [DllImport("*", EntryPoint = "IsValidUserPtr_Pas")]
    private static extern byte IsValidUserPtr_Pas(int threadId, ulong virtAddr, ulong pml4Phys, ulong totalPages);

    // [PASCAL PORT] String splitting delegated to libc.SplitTwoArgs_Pas
    [DllImport("*", EntryPoint = "SplitTwoArgs_Pas")]
    private static extern byte SplitTwoArgs_Pas(char* rest, char* outFirst, int firstCap, char* outSecond, int secondCap);

    // [PASCAL PORT] PASSWD / SUDOERS file parsing delegated to passwd_parser.pas
    [DllImport("*", EntryPoint = "ParsePasswdLine_Pas")]
    private static extern uint ParsePasswdLine_Pas(char* linePtr, char* userOut, uint userCap, char* saltOut, uint saltCap, char* hashOut, uint hashCap, char* uidOut, uint uidCap);

    [DllImport("*", EntryPoint = "SudoersContains_Pas")]
    private static extern byte SudoersContains_Pas(byte* buf, uint bufLen, char* user);

    // [PASCAL PORT] Decimal string to uint (for parsing PASSWD uid field)
    [DllImport("*", EntryPoint = "Atoi_Pas")]
    private static extern uint Atoi_Pas(char* str);

    // [PASCAL PORT] Octal string to uint (for parsing chmod mode bits)
    [DllImport("*", EntryPoint = "OctalStrToUInt_Pas")]
    private static extern uint OctalStrToUInt_Pas(char* str);

    // [PASCAL PORT] Printable char classification (for cat builtin byte filter)
    [DllImport("*", EntryPoint = "IsPrintableChar_Pas")]
    private static extern byte IsPrintableChar_Pas(ushort c);

    // [PASCAL PORT] Compare wide string vs fixed ASCII byte buffer
    [DllImport("*", EntryPoint = "StrEqWideBytes_Pas")]
    private static extern byte StrEqWideBytes_Pas(char* wideStr, byte* byteStr);

    // [PASCAL PORT] Capped string copy (used in case 94 for username pass-through)
    [DllImport("*", EntryPoint = "StrCpyLimited_Pas")]
    private static extern uint StrCpyLimited_Pas(char* dest, char* src, uint cap);

    public static ulong GlobalSharedRAM_Phys = 0;
    public static ulong MpuTrapPage_Phys = 0;
    public static Spinlock SharedMemLock;
    private static ulong SyscallLogCounter = 0;

    // [SUDO-DBG] Stage mirror của syscall 94 (sudo) tại PA cố định 0x8000 - nằm trong
    // vùng "SMP Memory Land" (0x8000-0x9FFF) mà trampoline không dùng lại sau boot.
    // Mục đích: chẩn đoán hậu kỳ khi hệ thống treo - đọc giá trị bằng QEMU monitor
    // (socat -> unix socket monitor -> `xp /1wx 0x8000`) để biết sudo đang kẹt ở
    // giai đoạn nào mà KHÔNG cần I/O (không phá vỡ timing như debug qua COM1).
    // Bit mã hóa: 1=enter, 2=đọc PASSWD xong, 3=match account, 4=salt/pass prep,
    // 5|0x100=so hash đúng (5|0x000=sai), 6=sai pass đã free, 7=bắt đầu đọc SUDOERS,
    // 9=vào nhánh builtin, 10=ListDir gọi, 11=ListDir xong, 12=trước free cuối,
    // 13=hoàn tất sạch.

    // [PASCAL PORT] PHYS_ADDR_MASK now defined in syscall_security.pas
    // (kept here as no-op for reference; all page-table logic ported)

    // [PASCAL PORT] IsPageMappedForUser + IsValidUserPtr replaced with
    // syscall_security.pas IsValidUserPtr_Pas for the full PML4 walk.
    // Returns true if ptr is within canonical user range AND mapped with
    // Present + User bits in the calling thread's address space.
    private static bool IsValidUserPtr(ulong ptr)
    {
        if (ptr < 0x1000 || ptr > 0x00007FFFFFFFFFFF) return false;
        int tid = Scheduler.CurrentThreadId;
        if (tid < 0 || tid >= Scheduler.ThreadCount) return false;
        ulong pml4Phys = Scheduler.Threads[tid].AddrSpace;
        return IsValidUserPtr_Pas(tid, ptr, pml4Phys, PMM.TotalPages * 4096UL) != 0;
    }

    // [PASCAL PORT] Delegates to libc.SplitTwoArgs_Pas for string tokenizing
    private static bool SplitTwoArgsSudo(char* rest, char* outFirst, int firstCap, char* outSecond, int secondCap) {
        return SplitTwoArgs_Pas(rest, outFirst, firstCap, outSecond, secondCap) != 0;
    }

    [UnmanagedCallersOnly(EntryPoint = "SyscallHandler")]
    public static ulong SyscallHandler(ulong currentRsp)
    {
        // ==========================================================
        // [CRITICAL PRECAUTION] Disable interrupts during syscall handling
        // Enabling interrupts allows context switches during page table modifications,
        // which could cause CR3 address space mismatches and lead to kernel crashes.
        // ==========================================================
        //
        // ==========================================================
        // [SCHEDULER PROTECTION] Prevent nested interrupts and soft yields
        // Do not call Scheduler.Yield() (via int 0x81) inside the syscall handler.
        // The syscall handler runs within an active "int 0x80" frame (Ring 3 to Ring 0 transition),
        // meaning the CPU pushed a full 5-word interrupt stack frame (RIP/CS/RFLAGS/RSP/SS).
        // Calling Yield() here triggers a nested Ring 0 interrupt, which only pushes a 3-word frame,
        // omitting RSP/SS. When the scheduler attempts to restore this task, the missing stack context
        // causes stack misalignment and general protection faults (#GP) on IRETQ.
        // ==========================================================
        // Đã verify bằng cách disassemble Kernel.exe: RIP crash luôn lệch
        // đúng offset cố định trước "Kernel Text Address" - trúng phóc lệnh
        // iretq cuối IsrYield, bất kể KASLR đổi base mỗi lần boot.
        //
        // THAY VÀO ĐÓ: IsrSyscall bây giờ dùng "mov rsp, rax" (giống IsrTimer),
        // nên SyscallHandler có thể gọi Scheduler.SwitchTask(currentRsp) TRỰC TIẾP
        // và trả về RSP mới. Cơ chế CONTEXT SWITCH NGAY TRONG SYSCALL HANDLER,
        // KHÔNG cần nested interrupt, KHÔNG spin CPU vô tận!
        // ==========================================================

        RegisterContext* ctx = (RegisterContext*)currentRsp;

        if (currentRsp == 0 || currentRsp < 0x1000) return currentRsp;

        ulong syscallId = ArchCtx.GetNumber(ctx);
        int id = Scheduler.CurrentThreadId;

        // [FIX CVE-2026-009] DISABLED: Serial logging leaks CR3/TID to QEMU monitor
        // This information can be used to bypass ASLR or map kernel memory layout
        // If debugging is needed, re-enable temporarily and rebuild
        /*
        SyscallLogCounter++;
        if ((SyscallLogCounter & 0xFF) == 0) {
            ulong cr3 = Arch.ReadPageTable() & 0x000FFFFFFFFFF000UL;
            fixed (char* s1 = "[SYSCALL] ID: \0") Serial.WriteString(s1);
            Serial.WriteHex(syscallId);
            fixed (char* s2 = " TID: \0") Serial.WriteString(s2);
            Serial.WriteHex((ulong)id);
            fixed (char* s3 = " CR3: \0") Serial.WriteString(s3);
            Serial.WriteHex(cr3);
            fixed (char* nl = "\n\0") Serial.WriteString(nl);
        }
        */

        // Validate scheduler/thread table before touching it
        if (Scheduler.Threads == null || id < 0 || id >= Scheduler.ThreadCount) {
            ArchCtx.SetRet(ctx, 0); return currentRsp;
        }

        bool isKing = (Scheduler.Threads[id].UID == 0);

        if (Scheduler.Threads[id].IsJailed == 1 && Scheduler.Threads[id].IsPhantomDead == 1)
        {
            if (syscallId == 0) { Scheduler.TerminateCurrentTask(); return currentRsp; }
            if (syscallId == 6 || syscallId == 99) { ArchCtx.SetRet(ctx, (0x0000DEADBEEF0000 | 0x0000FEEBDEAD0000)); return currentRsp; }
            ArchCtx.SetRet(ctx, 1); 
            return Scheduler.SwitchTask(currentRsp);
        }

        if (Scheduler.Threads[id].IsJailed == 1)
        {
            if (syscallId == 7 || syscallId == 91 || syscallId == 93) { Scheduler.Threads[id].IsPhantomDead = 1; ArchCtx.SetRet(ctx, 1); return currentRsp; }
            if (syscallId == 6 && ArchCtx.GetArg(ctx, 1) > 256) { Scheduler.Threads[id].IsPhantomDead = 1; ArchCtx.SetRet(ctx, (0x0000DEADBEEF0000 & 0x0000FEEBDEAD0000)); return currentRsp; }
        }

        ulong currentTicks = Scheduler.SystemTicks;

        switch (syscallId)
        {
            // [SYSCALL 0]: TỰ SÁT (Exit)
            case 0: { Scheduler.TerminateCurrentTask(); break; }
            
            // [PORTABLE] I/O-specific syscall 1 (print string) delegated to arch vtable
            case 1:
            {
                if (ArchCtx.GetArg(ctx, 1) == 0 || !IsValidUserPtr(ArchCtx.GetArg(ctx, 1))) { ArchCtx.SetRet(ctx, 0); break; }
                char* str = (char*)ArchCtx.GetArg(ctx, 1);
                ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchPrint(id, str));
                break;
            }

            // [PORTABLE] I/O-specific syscall 2 (draw pixel) delegated to arch vtable
            case 2:
            {
                ulong x = ArchCtx.GetArg(ctx, 1); ulong y = ArchCtx.GetArg(ctx, 2); ulong color = ArchCtx.GetArg(ctx, 3);
                ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchDrawPixel(id, x, y, color));
                break;
            }

            // [PORTABLE] I/O-specific syscall 3 (clear screen) delegated to arch vtable
            case 3:
            {
                ulong bgColor = ArchCtx.GetArg(ctx, 1);
                ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchClearScreen(id, bgColor));
                break;
            }

            // [SYSCALL 4]: ĐỌC BÀN PHÍM (GLOBAL INTERCEPT HACK)
            // ==========================================================
            // [FIX TRIỆT ĐỂ - TRANH CHẤP BÀN PHÍM] Trước đây HÀM NÀY cho phép
            // BẤT KỲ thread nào gọi SyscallGetChar() cướp quyền đọc bất kỳ
            // scancode nào trong hàng đợi IPC (KeyboardHandler gửi broadcast
            // Receiver=0, không phân biệt ai "nên" nhận). Hậu quả: khi Shell
            // chạy "run top.exe" (không blocking - PELoader.LoadAndRun tạo
            // thread mới rồi trả về ngay), Shell quay lại vòng lặp đọc phím
            // CỦA CHÍNH NÓ ngay lập tức, chạy song song và tranh giành từng
            // scancode 'q' với top.exe đang ở foreground. Kết quả: bấm 'q'
            // nhiều lần mới thoát được top.exe (vì 1 số lần 'q' bị Shell cướp
            // mất), và những 'q' đó nằm lại trong sharedCmdBuffer của Shell,
            // sau đó bị submit thành lệnh rác "qqqqq" khi Enter được nhấn.
            //
            // Kernel đã có sẵn Scheduler.ForegroundTask (set khi tạo tiến
            // trình foreground ở Thread.cs:CreateUserTask, trả về ParentId
            // khi tiến trình đó thoát/sập ở Thread.cs:TerminateTask và các
            // Handler crash) nhưng KHÔNG hề được dùng để gác cổng bàn phím -
            // đây chính là gốc rễ của bug. Fix: chỉ cho phép thread gọi cướp
            // phím nếu nó ĐANG LÀ ForegroundTask. Có fallback an toàn: nếu
            // ForegroundTask không hợp lệ/đã chết (VD: -1 lúc boot, hoặc bị
            // zombie hóa mà chưa kịp trả về ParentId), KHÔNG khóa cứng bàn
            // phím - mở lại cho tất cả để tránh input bị "câm" vĩnh viễn.
            // [PORTABLE] I/O-specific syscall 4 (keyboard read) delegated to arch vtable
            case 4:
            {
                return Arch.SyscallImpl!.DispatchKeyboardRead(id, isKing, ctx, currentRsp);
            }
            
            // [SYSCALL 5]: GỬI TIN NHẮN IPC (Send IPC)
            case 5:
            {
                uint receiverId = (uint)ArchCtx.GetArg(ctx, 1);
                uint msgType = (uint)ArchCtx.GetArg(ctx, 2);
                if (receiverId >= Scheduler.ThreadCount || Scheduler.Threads[receiverId].Active == 0) { ArchCtx.SetRet(ctx, 0); break; }
                if (Scheduler.Threads[id].IsJailed == 1 && (receiverId == 0 || receiverId == 1)) {
                    Scheduler.Threads[id].IsPhantomDead = 1; ArchCtx.SetRet(ctx, 1); break;
                }

                // [FIX BẢO MẬT - CRITICAL] Type "quyền lực sinh tử" (SIGTERM daemon,
                // shutdown, reboot) chỉ root (UID==0) mới được gửi. Nếu không, bất kỳ
                // user thường nào cũng bắn thẳng 0xDEAD/0xBEEF cho ACPI/ATA/FAT16 Daemon
                // để tắt máy/reboot/kill daemon, bỏ qua hoàn toàn kiểm tra isKing ở case 88.
                bool isPrivilegedType = (msgType == 0xDEAD || msgType == 0xBEEF);
                if (isPrivilegedType && Scheduler.Threads[id].UID != 0) {
                    ArchCtx.SetRet(ctx, 0); break;
                }

                // [FIX BẢO MẬT - CRITICAL] ATA Daemon thao tác theo SECTOR vật lý,
                // không có khái niệm "chủ sở hữu file" nên không thể tự CheckAccess -
                // nó tin tưởng tuyệt đối msg.Sender. Trước đây BẤT KỲ tiến trình Ring3
                // nào cũng có thể dò ra ATA.DaemonId qua syscall "Get Process Info" rồi
                // gửi thẳng Type 10/12 (READ/WRITE RAW) để đọc/ghi bất kỳ sector nào,
                // bypass hoàn toàn lớp CheckAccess của FAT16 Driver (kể cả /ETC/PASSWD).
                // Toàn bộ luồng hợp pháp (Shell/Login/explorer/dsrv) chỉ nói chuyện với
                // FAT16 Daemon qua IPC, KHÔNG BAO GIỜ gửi thẳng cho ATA Daemon - luồng
                // Ring0 (ATA.cs) tới ATA Daemon lại gọi IPC.Send() trực tiếp (hàm nội bộ,
                // không qua syscall 5) nên không bị ảnh hưởng bởi chặn này. Vậy chỉ cần
                // cấm mọi caller Ring3 gửi trực tiếp cho ATA Daemon, trừ chính FAT16
                // Daemon.
                //
                // [FIX CRITICAL #1] KHÔNG còn dùng Thread.Name để nhận diện - đó là chuỗi
                // do NGƯỜI DÙNG tự đặt qua lệnh "run"/"daemon" (Syscall.cs case 88), nên bất
                // kỳ ai cũng đặt tên tiến trình bắt đầu bằng "FAT16" để giả mạo, vượt qua
                // hoàn toàn lớp CheckAccess của FAT16 Daemon để đọc/ghi thẳng RAW sector
                // (kể cả /ETC/PASSWD). Nhận diện bằng Driver.FAT16.TrustedThreadId - ID
                // luồng được chính Kernel.cs ghi nhận NGAY LÚC spawn FAT16.EXE ở boot
                // sequence (Kernel.cs, PELoader.LoadAndRun trả về qua out param), tức là
                // TRƯỚC KHI FAT16 Daemon kịp tự gọi ATA để đọc boot sector - không còn race
                // condition như biến Driver.FAT16.DaemonId (biến đó chỉ được gán SAU KHI
                // FAT16 Daemon hoàn tất IPC handshake Type 39, là sau lúc daemon đã tự đọc
                // boot sector rồi). Vì ID luồng do Scheduler tự sinh (GetFreeThreadSlot),
                // không phải dữ liệu người dùng cung cấp, nên không thể bị giả mạo.
                if (Driver.ATA.DaemonId != 0 && receiverId == Driver.ATA.DaemonId) {
                    bool isFat16Daemon = Driver.FAT16.TrustedThreadId >= 0 && Driver.FAT16.TrustedThreadId == id;
                    if (!isFat16Daemon) { ArchCtx.SetRet(ctx, 0); break; }
                }

                // Gọi Send của cấu trúc Lock-Free mới
                // [FIX CVE-2026-002] BẮT RETURN VALUE để caller biết send có thành công không!
                bool sendSuccess = IPC.Send(msgType, (uint)id, receiverId, ArchCtx.GetArg(ctx, 3));

                if (sendSuccess)
                {
                    // Chỉ wake receiver nếu send thành công
                    bool irq = Scheduler.AcquireSchedLockSafe();
                    if (Scheduler.Threads[receiverId].Active == 2) {
                        Scheduler.Threads[receiverId].Active = 1;
                    }
                    Scheduler.Threads[receiverId].VRuntime = Scheduler.Threads[id].VRuntime;
                    Scheduler.ReleaseSchedLockSafe(irq);

                    ArchCtx.SetRet(ctx, 1);  // Success
                }
                else
                {
                    ArchCtx.SetRet(ctx, 0);  // Failed - queue full, caller nên retry!
                }

                // [SCHEDULER] Do not yield inside the interrupt frame - context switch is handled by the timer IRQ
                break;
            }

            // [PORTABLE] Arch-specific syscall 6 (heap allocation) delegated to arch vtable
            case 6:
            {
                ulong numPages = ArchCtx.GetArg(ctx, 1);
                ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchAllocateHeap(id, numPages, isKing));
                break;
            }

            // [PORTABLE] I/O-specific syscall 7 (grant I/O port access) delegated to arch vtable
            case 7:
            {
                ushort port = (ushort)ArchCtx.GetArg(ctx, 1);
                Arch.SyscallImpl!.DispatchGrantPortAccess(port, id, isKing);
                ArchCtx.SetRet(ctx, 1);
                break;
            }

            // ==========================================================
            // [SYSCALL 8]: KIỂM TRA HÒM THƯ IPC (Receive IPC - Non Blocking)
            // ==========================================================
            case 8: 
            {
                if (ArchCtx.GetArg(ctx, 1) == 0 || !IsValidUserPtr(ArchCtx.GetArg(ctx, 1))) { ArchCtx.SetRet(ctx, 0); break; }
                
                // Mặc dù User Space (App Ring 3) vẫn dùng struct Message
                // Nhưng Kernel (Ring 0) sẽ hứng qua ReceiveRaw rồi đắp data vào con trỏ đó!
                Message* outMsg = (Message*)ArchCtx.GetArg(ctx, 1);
                
                uint rType = 0, rSender = 0; ulong rPayload = 0;
                
                if (IPC.ReceiveForRaw((uint)id, &rType, &rSender, &rPayload)) 
                { 
                    outMsg->Type = rType;
                    outMsg->Sender = rSender;
                    outMsg->Receiver = (uint)id;
                    outMsg->Payload = rPayload;
                    ArchCtx.SetRet(ctx, 1); 
                } 
                else 
                { 
                    ArchCtx.SetRet(ctx, 0); 
                }
                break;
            }

            // [SYSCALL 10]: ĐIỀU TRA LÝ LỊCH (Get Process Info)
            case 10: 
            {
                uint targetId = (uint)ArchCtx.GetArg(ctx, 1); ulong outPtr = ArchCtx.GetArg(ctx, 2);
                if (!IsValidUserPtr(outPtr) || targetId >= Scheduler.ThreadCount) { ArchCtx.SetRet(ctx, 0); break; }

                ProcessInfo* pInfo = (ProcessInfo*)outPtr;
                pInfo->ID = targetId;
                
                bool irq = Scheduler.AcquireSchedLockSafe();
                pInfo->UID = Scheduler.Threads[targetId].UID;
                pInfo->GID = Scheduler.Threads[targetId].GID;
                pInfo->Active = Scheduler.Threads[targetId].Active;
                pInfo->IsJailed = Scheduler.Threads[targetId].IsJailed;
                pInfo->IsPhantomDead = Scheduler.Threads[targetId].IsPhantomDead;
                // [FIX BẢO MẬT - MEDIUM] Chỉ tiết lộ địa chỉ heap thật (KASLR-style) cho
                // root hoặc chính chủ tiến trình đó - trước đây rò rỉ cho bất kỳ ai, hỗ trợ
                // tấn công dò địa chỉ vào các daemon chạy quyền root.
                pInfo->HeapMemory = (isKing || targetId == (uint)id) ? Scheduler.Threads[targetId].AppHeapBase : 0;
                pInfo->CpuTicks = Scheduler.Threads[targetId].CpuTicks;
                pInfo->PhysPages = Scheduler.Threads[targetId].PhysPages;
                pInfo->VirtPages = Scheduler.Threads[targetId].VirtPages; 
                for (int i = 0; i < 16; i++) { pInfo->Name[i] = Scheduler.Threads[targetId].Name[i]; } 
                Scheduler.ReleaseSchedLockSafe(irq);
                
                ArchCtx.SetRet(ctx, 1); break;
            }

            // [SYSCALL 11]: LẤY ĐỊA CHỈ ACPI RSDP
            case 11: { ArchCtx.SetRet(ctx, Program.GlobalBootInfo->AcpiRsdp); break; }

            // [SYSCALL 12]: MƯỢN ĐẤT PHẦN CỨNG (Map Physical Memory)
            // [PORTABLE] I/O-specific syscall 12 (map physical memory) delegated to arch vtable
            case 12:
            {
                return Arch.SyscallImpl!.DispatchMapPhysicalMemory(id, isKing, ctx);
            }

            // [PORTABLE] I/O-specific syscall 13 (hardware reporting) delegated to arch vtable
            case 13:
            {
                uint hwType = (uint)ArchCtx.GetArg(ctx, 1);
                ulong payload = ArchCtx.GetArg(ctx, 2);
                if (!isKing) { Scheduler.Threads[id].IsPhantomDead = 1; ArchCtx.SetRet(ctx, 0); break; }
                ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchHardwareReport(hwType, payload, isKing));
                break;
            }

            // [SYSCALL 14]: TÌM NGƯỜI THÂN (Get PID By Name)
            case 14:
            {
                if (!IsValidUserPtr(ArchCtx.GetArg(ctx, 1))) { ArchCtx.SetRet(ctx, unchecked((ulong)-1)); break; }
                char* targetName = (char*)ArchCtx.GetArg(ctx, 1); long foundId = -1;

                bool irq = Scheduler.AcquireSchedLockSafe();
                for (int i = 1; i < Scheduler.ThreadCount; i++) {
                    if (Scheduler.Threads[i].Active != 0) {
                        // [PASCAL PORT] StrEqWideBytes_Pas compares wide string vs fixed byte buffer
                        if (StrEqWideBytes_Pas(targetName, Scheduler.Threads[i].Name) != 0) { foundId = i; break; }
                    }
                }
                Scheduler.ReleaseSchedLockSafe(irq);
                
                ArchCtx.SetRet(ctx, (ulong)foundId); break;
            }

            // [PORTABLE] I/O-specific syscall 50 (map framebuffer) delegated to arch vtable
            case 50:
            {
                return Arch.SyscallImpl!.DispatchMapFramebuffer(id, isKing, ctx);
            }

            // [PORTABLE] I/O-specific syscall 51 (get framebuffer dims) delegated to arch vtable
            case 51:
            {
                ulong* ptrWidth = (ulong*)ArchCtx.GetArg(ctx, 1);
                ulong* ptrHeight = (ulong*)ArchCtx.GetArg(ctx, 2);
                ulong* ptrScanLine = (ulong*)ArchCtx.GetArg(ctx, 3);
                ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchFramebufferDims(ptrWidth, ptrHeight, ptrScanLine));
                break;
            }

            // [PORTABLE] I/O-specific syscall 52 (redirect framebuffer) delegated to arch vtable
            case 52:
            {
                if (!isKing) { Scheduler.Threads[id].IsPhantomDead = 1; ArchCtx.SetRet(ctx, 0); break; }
                ulong newFb = ArchCtx.GetArg(ctx, 1);
                uint w = (uint)ArchCtx.GetArg(ctx, 2);
                uint h = (uint)ArchCtx.GetArg(ctx, 3);
                uint sl = (uint)ArchCtx.GetArg(ctx, 4);
                ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchRedirectFramebuffer(newFb, w, h, sl, isKing));
                break;
            }

            // [SYSCALL 88]: BỘ ĐÀM TỔNG TƯ LỆNH (Internal Shell / Run Daemon)
            case 88: 
            {
                if (ArchCtx.GetArg(ctx, 1) == 0 || !IsValidUserPtr(ArchCtx.GetArg(ctx, 1))) { ArchCtx.SetRet(ctx, 0); break; }
                char* cmdStr = (char*)ArchCtx.GetArg(ctx, 1);

                // Lấy địa chỉ cửa sổ ảo do CMD.EXE truyền vào qua RDX
                ulong targetFb = ArchCtx.GetArg(ctx, 2); 

                // [BỌC THÉP] LƯU LẠI MÀN HÌNH GỐC CỦA KERNEL!
                uint* oldFb = Terminal.fb;
                uint oldW = Terminal.width;
                uint oldH = Terminal.height;
                uint oldSl = Terminal.scanLine;

                fixed (char* cmdClear = "clear\0")
                fixed (char* cmdHelp = "help\0")
                fixed (char* cmdMem = "mem\0")
                fixed (char* cmdUptime = "uptime\0")
                fixed (char* cmdPci = "pci\0")
                fixed (char* cmdDate = "date\0")
                fixed (char* cmdUname = "uname\0")
                fixed (char* cmdRun = "run \0")
                fixed (char* cmdDaemon = "daemon \0")
                fixed (char* cmdPoweroff = "shutdown\0")
                fixed (char* cmdLogout = "logout\0")
                fixed (char* cmdReboot = "reboot\0")
                fixed (char* cmdCat = "cat \0")
                {
                    if (LibC.StrCmp(cmdStr, cmdClear)) { Terminal.Clear(0x00111111); }
                    else if (LibC.StrCmp(cmdStr, cmdHelp)) { fixed (char* msg = "NekkoOS Microkernel\nCommands: clear, help, mem, uptime, pci, date, uname, run, daemon, ls, cat, cd, write\n\0") Terminal.Print(msg); }
                    else if (LibC.StrCmp(cmdStr, cmdMem)) { fixed (char* msg = "Free memory:\t\t\0") Terminal.Print(msg); Terminal.PrintHex(PMM.FreePages * 4096 / (1024 * 1024)); fixed (char* msg2 = " MB\n\0") Terminal.Print(msg2); }
                    else if (LibC.StrCmp(cmdStr, cmdUptime)) { ulong totalSeconds = currentTicks / 1000; ulong ms = currentTicks % 1000; fixed (char* msg = "System Uptime: \0") Terminal.Print(msg); Terminal.PrintHex(totalSeconds); fixed (char* msg2 = " seconds, \0") Terminal.Print(msg2); Terminal.PrintHex(ms); fixed (char* msg3 = " ms\n\n\0") Terminal.Print(msg3); }
                    else if (LibC.StrCmp(cmdStr, cmdPci)) { PCI.ScanBus(); }
                    else if (LibC.StrCmp(cmdStr, cmdDate)) { RTC.PrintCurrentTime(); }
                    
                    else if (LibC.StrCmp(cmdStr, cmdPoweroff)) { 
                        if (isKing) Power.Shutdown(); 
                        else { Terminal.SetColor(0x00FF0000); fixed(char* e = "[!] Permission Denied: Only Root can shutdown the system!\n\0") Terminal.Print(e); }
                    }
                    else if (LibC.StrCmp(cmdStr, cmdReboot)) { 
                        if (isKing) Power.Reboot();   
                        else { Terminal.SetColor(0x00FF0000); fixed(char* e = "[!] Permission Denied: Only Root can reboot the system!\n\0") Terminal.Print(e); }
                    }
                    else if (LibC.StrCmp(cmdStr, cmdUname)) { fixed (char* buildDate = "NekkoOS Microkernel x86_64\n\0") Terminal.Print(buildDate); }
                    
                    else if (LibC.StrStartsWith(cmdStr, cmdCat))
                    {
                        char* fileName = cmdStr + 4;
                        if (*fileName != '\0') {
                            uint fSize = 0;
                            byte* fBuf = FAT16.ReadFile(fileName, &fSize);
                            if (fBuf != null) {
                                if (fSize > 16384) {
                                    Terminal.SetColor(0x00FF0000);
                                    fixed(char* e = "[!] File too large (>16KB). Refusing to print to prevent Terminal freeze.\n\0") Terminal.Print(e);
                                } else {
                                    Terminal.SetColor(0x00FFFFFF);
                                    for(uint i = 0; i < fSize; i++) {
                                        char c = (char)fBuf[i];
                                        if (c == '\r') continue;
                                        // [PASCAL PORT] IsPrintableChar_Pas replaces inline char filter
                                        if (IsPrintableChar_Pas((ushort)c) != 0) Terminal.DrawChar(c);
                                        else Terminal.DrawChar('.'); 
                                    }
                                    fixed (char* nl2 = "\n\0") Terminal.Print(nl2);
                                }
                                NekkoOS.Kernel.Heap.Free(fBuf); 
                            } else {
                                Terminal.SetColor(0x00FF0000);
                                fixed(char* e = "[!] cat: File not found on FAT16.\n\0") Terminal.Print(e);
                            }
                        }
                    }
                    else if (LibC.StrStartsWith(cmdStr, cmdRun) || LibC.StrStartsWith(cmdStr, cmdDaemon))
                    {
                        bool isDaemon = LibC.StrStartsWith(cmdStr, cmdDaemon);
                        
                        if (!isKing && isDaemon) { 
                            Terminal.SetColor(0x00FF0000); 
                            fixed(char* e = "[!] Permission Denied: Only Root can spawn Daemons!\n\0") Terminal.Print(e);
                            Terminal.SetColor(0x00FFFFFF);
                            ArchCtx.SetRet(ctx, 0); break; 
                        }

                        char* appName = isDaemon ? cmdStr + 7 : cmdStr + 4;
                        if (*appName == '\0') { ArchCtx.SetRet(ctx, 0); break; }

                        // [FIX BẢO MẬT] Chốt sẵn ID luồng gọi TRƯỚC khi bật ngắt cục bộ, tránh
                        // timer IRQ đổi luồng đang chạy trên core này giữa chừng khiến FAT16.ReadFile
                        // gửi IPC với danh tính (UID) sai sang FAT16 Daemon.
                        int callerThreadForRead = id;
                        uint fileSize = 0; IO.EnableInterrupts(); // [FIX] Bật ngắt CỤC BỘ cho I/O!
                        byte* rawData = FAT16.ReadFile(appName, &fileSize, callerThreadForRead);
                        
                        if (rawData != null) {
                            if (rawData[0] != 'M' || rawData[1] != 'Z') {
                                Terminal.SetColor(0x00FF0000);
                                fixed (char* err = "[!] Kernel FATAL: Corrupted PE Header!\n\0") Terminal.Print(err);
                                NekkoOS.Kernel.Heap.Free(rawData); ArchCtx.SetRet(ctx, 0); break; 
                            }
                            
                            Terminal.SetColor(0x00FFFF00);
                            // [FIX BẢO MẬT] Đổi && thành || - user có UID != 0 nhưng GID == 0
                            // (cấu hình hợp lệ trong PASSWD) trước đây thoát Zero Trust Jail hoàn toàn.
                            bool isJailed = (Scheduler.Threads[id].UID != 0 || Scheduler.Threads[id].GID != 0);
                            if (isJailed) { Terminal.SetColor(0x00FF00FF); fixed (char* msg = "[!] ZERO TRUST: Untrusted App detected! Jailing in Phantom Sandbox...\n\0") Terminal.Print(msg); }
                            
                            PELoader.LoadAndRun(rawData, isDaemon, isJailed, false, appName, 1);
                                                                        
                            if (isDaemon) { Terminal.SetColor(0x0000FF00); }
                        }
                        else {
                            Terminal.SetColor(0x00FF0000);
                            fixed (char* err = "[!] Kernel: Execute failed! File not found or OOM: \0") Terminal.Print(err);
                            Terminal.Print(appName); fixed (char* nl = "\n\0") Terminal.Print(nl);
                        }
                    }
                    else if (LibC.StrCmp(cmdStr, cmdLogout))
                    {
                        uint currentUid = Scheduler.Threads[id].UID;
                        Terminal.SetColor(0x00FFFF00); fixed (char* msg = "\n[*] Saving session... Logging out...\n\0") Terminal.Print(msg);

                        int callerThreadForLogout = id;
                        uint fileSize = 0; IO.EnableInterrupts(); byte* rawData = null; // [FIX] Bật ngắt CỤC BỘ!
                        fixed (char* logonFile = "syslogon.exe\0") fixed (char* dirRoot = "\\\0") {
                            // [FIX HOME DIR] FAT16.ReadFile dùng chung CurrentDirCluster (global,
                            // per-daemon, không phải per-client) với lệnh cd - nếu user đang đứng
                            // trong home dir (không phải "/") lúc gõ "logout", ReadFile sẽ tìm
                            // syslogon.exe nhầm chỗ và báo "Cannot find". Phải cd về root trước.
                            FAT16.Cd(dirRoot);
                            rawData = FAT16.ReadFile(logonFile, &fileSize, callerThreadForLogout);
                            if (rawData != null && rawData[0] == 'M' && rawData[1] == 'Z') {
                                PELoader.LoadAndRun(rawData, false, false, true, logonFile);
                            } else {
                                Terminal.SetColor(0x00FF0000);
                                fixed (char* err = "[!] FATAL: Cannot find syslogon.exe! System Halt!\n\0") Terminal.Print(err);
                                if (rawData != null) NekkoOS.Kernel.Heap.Free(rawData);
                                while(true) IO.Hlt();
                            }
                        }

                        if (currentUid == 0) { Scheduler.TerminateCurrentTask(); } 
                        else {
                            bool irq = Scheduler.AcquireSchedLockSafe();
                            for (int i = 1; i < Scheduler.ThreadCount; i++) {
                                if (i != id && Scheduler.Threads[i].Active == 1 && Scheduler.Threads[i].UID == currentUid) {
                                    Scheduler.Threads[i].Active = 0; Scheduler.Threads[i].UID = 9999;
                                }
                            }
                            Scheduler.ReleaseSchedLockSafe(irq);
                            Scheduler.TerminateCurrentTask();
                        }
                    }
                    else {
                        Terminal.SetColor(0x00FF0000);
                        fixed (char* msg = "Kernel: Unknown Command or handled by Ring 3: \0") Terminal.Print(msg);
                        Terminal.Print(cmdStr); fixed (char* nl = "\n\0") Terminal.Print(nl);
                    }
                }
                
                Terminal.SetColor(0x00FFFFFF); ArchCtx.SetRet(ctx, 1); break;
            }

            // [SYSCALL 89]: XEM CHỨNG MINH THƯ (Get Current UID)
            case 89: { ArchCtx.SetRet(ctx, Scheduler.Threads[id].UID); break; }

            // [SYSCALL 90]: ĐIỀU TRA CHỨNG MINH THƯ KẺ KHÁC (Get Target UID)
            case 90: 
            {
                uint targetThread = (uint)ArchCtx.GetArg(ctx, 0);
                if (targetThread < Scheduler.ThreadCount) { ArchCtx.SetRet(ctx, Scheduler.Threads[targetThread].UID); } 
                else { ArchCtx.SetRet(ctx, 9999); }
                break;
            }

            // [SYSCALL 91]: TỰ RỚT ĐÀI (Set UID - Drop Privilege)
            case 91: 
            {
                uint targetUID = (uint)ArchCtx.GetArg(ctx, 0); uint currentUID = Scheduler.Threads[id].UID;
                if (currentUID == 0 || targetUID == currentUID) { Scheduler.Threads[id].UID = targetUID; ArchCtx.SetRet(ctx, 1); } 
                else {
                    if (MpuTrapPage_Phys == 0) MpuTrapPage_Phys = (ulong)PMM.AllocatePage();
                    if (Scheduler.Threads[id].SharedMemVirt != 0) {
                        ulong pml4tmp = Scheduler.Threads[id].AddrSpace;
                        if (pml4tmp != 0 && pml4tmp < PMM.TotalPages * 4096UL && Mem.IsCanonical(pml4tmp)) {
                            Mem.MapPage(MpuTrapPage_Phys, Scheduler.Threads[id].SharedMemVirt, 0x05, (ulong*)pml4tmp);
                        }
                    }
                    ArchCtx.SetRet(ctx, 0); 
                }
                break;
            }

            // [SYSCALL 92 & 93]: ĐIỀU TRA & XÉT DUYỆT GROUP ID (Get/Set GID)
            case 92: 
            {
                uint targetThreadForGID = (uint)ArchCtx.GetArg(ctx, 0);
                if (targetThreadForGID < Scheduler.ThreadCount) { ArchCtx.SetRet(ctx, Scheduler.Threads[targetThreadForGID].GID); } 
                else { ArchCtx.SetRet(ctx, 9999); }
                break;
            }

            case 93: 
            {
                uint targetGID = (uint)ArchCtx.GetArg(ctx, 0); uint currentGID = Scheduler.Threads[id].GID;
                if (currentGID == 0 || Scheduler.Threads[id].UID == 0 || targetGID == currentGID) { Scheduler.Threads[id].GID = targetGID; ArchCtx.SetRet(ctx, 1); } 
                else {
                    if (MpuTrapPage_Phys == 0) MpuTrapPage_Phys = (ulong)PMM.AllocatePage();
                    if (Scheduler.Threads[id].SharedMemVirt != 0) {
                        ulong pml4tmp = Scheduler.Threads[id].AddrSpace;
                        if (pml4tmp != 0 && pml4tmp < PMM.TotalPages * 4096UL && Mem.IsCanonical(pml4tmp)) {
                            Mem.MapPage(MpuTrapPage_Phys, Scheduler.Threads[id].SharedMemVirt, 0x05, (ulong*)pml4tmp);
                        }
                    }
                    ArchCtx.SetRet(ctx, 0); 
                }
                break;
            }

            // [SYSCALL 94]: SUDO (Elevate-one-command)
            // Xác thực lại mật khẩu của CHÍNH thread gọi (dò bằng UID thật của
            // Scheduler.Threads[id], không tin username tự khai) qua /ETC/PASSWD,
            // kiểm tra /ETC/SUDOERS, rồi nếu đúng: nạp app với forceRoot:true.
            // Thread gọi (Shell.exe) KHÔNG hề bị đổi UID/GID - chỉ tiến trình MỚI
            // sinh ra mang UID/GID root, đúng phạm vi "một lệnh" đã chốt trong kế hoạch.
            // SetRet: 0=sai mật khẩu/không có tài khoản, 1=thành công,
            // 2=không nằm trong sudoers, 3=không tìm thấy app cần chạy.
            case 94:
            {
                if (ArchCtx.GetArg(ctx, 1) == 0 || !IsValidUserPtr(ArchCtx.GetArg(ctx, 1)) || ArchCtx.GetArg(ctx, 2) == 0 || !IsValidUserPtr(ArchCtx.GetArg(ctx, 2))) { ArchCtx.SetRet(ctx, 0); break; }
                char* appName = (char*)ArchCtx.GetArg(ctx, 1);
                char* inputPass = (char*)ArchCtx.GetArg(ctx, 2);

                // [SUDO WRITE] R8 = con tro Ring3 toi noi dung "write" da duoc Shell.cs
                // tu doc tu ban phim SAN (0/null neu app khong phai "write <path>"),
                // R9 = do dai byte. Validate y het appName/inputPass truoc khi doc thang
                // tu Ring0 - KHONG dung shared memory de tranh dung do voi AtaRawBuffer/
                // FatResponseData dang duoc cac thao tac disk khac dung song song.
                byte* sudoWriteContent = (ArchCtx.GetArg(ctx, 3) != 0 && IsValidUserPtr(ArchCtx.GetArg(ctx, 3))) ? (byte*)ArchCtx.GetArg(ctx, 3) : null;
                uint sudoWriteContentLen = (uint)ArchCtx.GetArg(ctx, 4);

                int callerThreadForSudo = id;
                uint callerUidForSudo = Scheduler.Threads[id].UID;
                *(uint*)0x8000UL = 1;
                IO.EnableInterrupts();

                char* lineUser = stackalloc char[32];
                char* lineSalt = stackalloc char[64];
                char* lineHash = stackalloc char[80];
                char* lineUID = stackalloc char[16];
                byte* saltBytes = stackalloc byte[32];
                byte* hashInputBuf = stackalloc byte[32 + 32];
                byte* computedHash = stackalloc byte[32];
                char* computedHashHex = stackalloc char[80];
                char* matchedUser = stackalloc char[32];

                bool foundAccount = false;
                fixed (char* dirEtc = "ETC\0") fixed (char* dirRoot = "\\\0") fixed (char* passFileName = "PASSWD\0") {
                    // [FIX] Cd bang callerThreadOverride=0 - phai dung DUNG state "thu muc
                    // hien tai" (CurrentDirCluster rieng cua Kernel, raw) ma ReadFile ben duoi
                    // (cung override=0) se doc, khong phai state cua daemon Ring3.
                    FAT16.Cd(dirRoot, 0); FAT16.Cd(dirEtc, 0);
                    uint passSize = 0;
                    // [FIX BAO MAT] Doc PASSWD bang callerThreadOverride=0 (tham quyen von
                    // co cua Kernel), KHONG dung UID thuc cua nguoi goi (callerThreadForSudo)
                    // - vi day la buoc XAC THUC de CHUNG MINH quyen root, ban than no khong
                    // the bi chan boi permission cua chinh nguoi dung CHUA duoc xac thuc
                    // (giong het viec SysLogon.exe luon chay forceRoot:true de tu doc PASSWD
                    // luc dang nhap). Neu dung UID that o day, PASSWD/SUDOERS bi chmod that
                    // chat (vd 600) se khoa luon ca chuc nang sudo cua chinh no.
                    byte* passBuf = FAT16.ReadFile(passFileName, &passSize, 0);
                    FAT16.Cd(dirRoot, 0);
                    *(uint*)0x8000UL = 2;

                    if (passBuf != null && passSize > 0) {
                        int i = 0;
                        while (i < (int)passSize) {
                            // [PASCAL PORT] Passwd line parsing delegated to passwd_parser.pas
                            ParsePasswdLine_Pas((char*)&passBuf[i], lineUser, 32, lineSalt, 64, lineHash, 80, lineUID, 16);

                            // Skip past the line we just parsed
                            while (i < (int)passSize && passBuf[i] != '\n' && passBuf[i] != '\r') i++;
                            while (i < (int)passSize && (passBuf[i] == '\n' || passBuf[i] == '\r')) i++;

                            // [PASCAL PORT] Atoi_Pas replaces inline decimal parsing
                            uint lineUidVal = Atoi_Pas(lineUID);

                            if (lineUser[0] != '\0' && lineUidVal == callerUidForSudo) {
                                *(uint*)0x8000UL = 3;
                                // [PASCAL PORT] StrCpyLimited_Pas replaces inline char-by-char copy
                                StrCpyLimited_Pas(matchedUser, lineUser, 32);

                                int saltLen = KernHexUtil.HexToBytes(lineSalt, saltBytes, 32);
                                int passLen = 0; while (inputPass[passLen] != '\0') passLen++;
                                *(uint*)0x8000UL = 4;
                                int hashInputLen = 0;
                                for (int k = 0; k < saltLen; k++) hashInputBuf[hashInputLen++] = saltBytes[k];
                                for (int k = 0; k < passLen; k++) hashInputBuf[hashInputLen++] = (byte)inputPass[k];

                                SHA256.Compute(hashInputBuf, (ulong)hashInputLen, computedHash);
                                KernHexUtil.BytesToHex(computedHash, 32, computedHashHex);

                                foundAccount = true;
                                bool passOk = KernHexUtil.ConstantTimeEq(computedHashHex, lineHash, 64);
                                *(uint*)0x8000UL = (uint)(5 | (passOk ? 0x100 : 0));

                                KernHexUtil.ZeroMemChar(lineSalt, 64); KernHexUtil.ZeroMemChar(lineHash, 80);
                                KernHexUtil.ZeroMemByte(saltBytes, 32); KernHexUtil.ZeroMemByte(hashInputBuf, 64);
                                KernHexUtil.ZeroMemByte(computedHash, 32); KernHexUtil.ZeroMemChar(computedHashHex, 80);

                                if (!passOk) {
                                    NekkoOS.Kernel.Heap.Free(passBuf);
                                    *(uint*)0x8000UL = 6;
                                    ArchCtx.SetRet(ctx, 0); break;
                                }

                                // Kiểm tra /ETC/SUDOERS: username đọc được từ chính PASSWD (không
                                // phải do Ring3 tự khai) có nằm trong danh sách cho phép không.
                                bool inSudoers = false;
                                *(uint*)0x8000UL = 7;
                                fixed (char* sudoersFile = "SUDOERS\0") {
                                    FAT16.Cd(dirEtc, 0);
                                    uint sudoSize = 0;
                                    // [FIX BAO MAT] Tuong tu PASSWD o tren - doc SUDOERS bang
                                    // tham quyen von co cua Kernel (callerThreadOverride=0), khong
                                    // dung UID that cua nguoi goi.
                                    byte* sudoBuf = FAT16.ReadFile(sudoersFile, &sudoSize, 0);
                                    FAT16.Cd(dirRoot, 0);
                                    if (sudoBuf != null && sudoSize > 0) {
                                        // [PASCAL PORT] SUDOERS matching delegated to passwd_parser.pas
                                        inSudoers = SudoersContains_Pas(sudoBuf, sudoSize, matchedUser) != 0;
                                        NekkoOS.Kernel.Heap.Free(sudoBuf);
                                    }
                                }

                                if (!inSudoers) { NekkoOS.Kernel.Heap.Free(passBuf); ArchCtx.SetRet(ctx, 2); break; }

                                // ==========================================================
                                // [SUDO BUILTIN - Ve root tam thoi qua IPC] KHONG tu lam logic
                                // filesystem trong Ring0 (se pha vo tinh chat Microkernel) - thay
                                // vao do, Kernel chi NANG UID/GID THAT cua chinh luong goi (id) len
                                // 0 trong dung khoanh khac 1 IPC roundtrip toi FAT16.exe (Ring3
                                // daemon), roi PHUC HOI NGAY sau khi nhan phan hoi. Toan bo logic
                                // FindEntry/CheckAccess/permission van nam nguyen o Ring3 nhu thiet
                                // ke goc - day chi la "ve" dac quyen co thoi han cuc ngan, khong
                                // phai Kernel gianh lam viec cua daemon.
                                // ==========================================================
                                fixed (char* vCat = "cat \0") fixed (char* vRm = "rm \0")
                                fixed (char* vMkdir = "mkdir \0") fixed (char* vRmdir = "rmdir \0")
                                fixed (char* vChmod = "chmod \0") fixed (char* vChown = "chown \0")
                                fixed (char* vLs = "ls\0") fixed (char* vLl = "ll\0") fixed (char* vCd = "cd \0")
                                fixed (char* vWrite = "write \0")
                                {
                                    bool isBuiltin = LibC.StrStartsWith(appName, vCat) || LibC.StrStartsWith(appName, vRm) ||
                                                      LibC.StrStartsWith(appName, vMkdir) || LibC.StrStartsWith(appName, vRmdir) ||
                                                      LibC.StrStartsWith(appName, vChmod) || LibC.StrStartsWith(appName, vChown) ||
                                                      LibC.StrCmp(appName, vLs) || LibC.StrCmp(appName, vLl) ||
                                                      LibC.StrStartsWith(appName, vCd) || LibC.StrStartsWith(appName, vWrite);
                                    if (isBuiltin) {
                                        *(uint*)0x8000UL = 9;
                                        uint sudoOrigUid = Scheduler.Threads[id].UID;
                                        uint sudoOrigGid = Scheduler.Threads[id].GID;
                                        Scheduler.Threads[id].UID = 0; Scheduler.Threads[id].GID = 0;

                                        if (LibC.StrCmp(appName, vLs) || LibC.StrCmp(appName, vLl)) {
                                            char* listBuf = stackalloc char[2048];
                                            *(uint*)0x8000UL = 10;
                                            bool listOk = FAT16.ListDir(listBuf, 2048, callerThreadForSudo);
                                            *(uint*)0x8000UL = 11;
                                            if (listOk) {
                                                Terminal.SetColor(0x00FFFFFF);
                                                Terminal.Print(listBuf);
                                            } else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] sudo ls: Failed to list directory.\n\0") Terminal.Print(e); }
                                        }
                                        else if (LibC.StrStartsWith(appName, vCd)) {
                                            char* p = appName + 3;
                                            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo cd <path>\n\0") Terminal.Print(e); }
                                            else {
                                                // [LUU Y KIEN TRUC] Khac voi Unix that (sudo cd vo nghia vi child
                                                // process chet la mat cwd) - o NekkoOS, cwd duoc DAEMON Ring3
                                                // theo doi THEO THREAD ID cua chinh Shell.exe (khong phai bien
                                                // shell-local), nen "sudo cd" o day CO Y NGHIA THAT: vao tam thoi
                                                // mot thu muc ma UID that khong du quyen enter, va thu muc do VAN
                                                // con hieu luc cho shell sau khi sudo tra ve (vi dung chung 1
                                                // thread id voi lenh cd thuong). Cac lenh sau van bi CheckAccess
                                                // kiem tra bang UID THAT cua user (khong con la root) nhu binh thuong.
                                                // Cd tu in loi qua Terminal.Print neu that bai (giong duong daemon
                                                // binh thuong) - thanh cong thi im lang, dung y het "cd" thuong.
                                                FAT16.Cd(p, callerThreadForSudo);
                                            }
                                        }
                                        else if (LibC.StrStartsWith(appName, vWrite)) {
                                            char* p = appName + 6;
                                            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo write <path>\n\0") Terminal.Print(e); }
                                            else if (sudoWriteContent == null) {
                                                // Khong bao gio xay ra trong luong binh thuong (Shell.cs luon
                                                // capture noi dung truoc khi goi syscall khi appName bat dau
                                                // bang "write ") - phong thu neu con tro bi truyen sai/thieu.
                                                Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] sudo write: No content buffer provided.\n\0") Terminal.Print(e);
                                            }
                                            else {
                                                int wr = FAT16.WriteFileRelay(p, sudoWriteContent, sudoWriteContentLen, callerThreadForSudo);
                                                if (wr == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] File written successfully!\n\0") Terminal.Print(ok); }
                                                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Failed! Disk Full, Access Denied or File is a Directory!\n\0") Terminal.Print(e); }
                                            }
                                        }
                                        else if (LibC.StrStartsWith(appName, vCat)) {
                                            char* p = appName + 4;
                                            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo cat <path>\n\0") Terminal.Print(e); }
                                            else {
                                                uint catSize = 0;
                                                byte* catBuf = FAT16.ReadFile(p, &catSize, callerThreadForSudo);
                                                if (catBuf != null) {
                                                    if (catSize > 16384) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] File too large (>16KB). Refusing to print to prevent Terminal freeze.\n\0") Terminal.Print(e); }
                                                    else {
                                                        Terminal.SetColor(0x00FFFFFF);
                                                        for (uint k = 0; k < catSize; k++) {
                                                            char c = (char)catBuf[k];
                                                            if (c == '\r') continue;
                                                            // [PASCAL PORT] IsPrintableChar_Pas replaces inline char filter
                                                            if (IsPrintableChar_Pas((ushort)c) != 0) Terminal.DrawChar(c);
                                                            else Terminal.DrawChar('.');
                                                        }
                                                        fixed (char* nl2 = "\n\0") Terminal.Print(nl2);
                                                    }
                                                    NekkoOS.Kernel.Heap.Free(catBuf);
                                                } else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] sudo cat: File not found or Access Denied.\n\0") Terminal.Print(e); }
                                            }
                                        }
                                        else if (LibC.StrStartsWith(appName, vMkdir)) {
                                            char* p = appName + 6;
                                            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo mkdir <path>\n\0") Terminal.Print(e); }
                                            else {
                                                int r = FAT16.MakeDir(p, callerThreadForSudo);
                                                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] Directory Created Successfully!\n\0") Terminal.Print(ok); }
                                                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Failed! Directory already exists or Disk Full.\n\0") Terminal.Print(e); }
                                            }
                                        }
                                        else if (LibC.StrStartsWith(appName, vRm)) {
                                            char* p = appName + 3;
                                            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo rm <path>\n\0") Terminal.Print(e); }
                                            else {
                                                int r = FAT16.RemoveFile(p, callerThreadForSudo);
                                                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] File Removed and Clusters Recycled!\n\0") Terminal.Print(ok); }
                                                else if (r == 2) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Cannot use RM on a Directory!\n\0") Terminal.Print(e); }
                                                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] File Not Found.\n\0") Terminal.Print(e); }
                                            }
                                        }
                                        else if (LibC.StrStartsWith(appName, vRmdir)) {
                                            char* p = appName + 6;
                                            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo rmdir <path>\n\0") Terminal.Print(e); }
                                            else {
                                                int r = FAT16.RemoveDir(p, callerThreadForSudo);
                                                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] Directory and ALL its contents obliterated recursively!\n\0") Terminal.Print(ok); }
                                                else if (r == 2) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Target is a File. Use 'sudo rm' instead.\n\0") Terminal.Print(e); }
                                                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Directory Not Found.\n\0") Terminal.Print(e); }
                                            }
                                        }
                                        else if (LibC.StrStartsWith(appName, vChmod)) {
                                            char* rest = appName + 6;
                                            char* modeStr = stackalloc char[16]; char* path = stackalloc char[256];
                                            if (!SplitTwoArgsSudo(rest, modeStr, 16, path, 256)) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo chmod <mode> <path>\n\0") Terminal.Print(e); }
                                            else {
                                                // [PASCAL PORT] Inline OctalStrToUInt replaced with OctalStrToUInt_Pas
                                                uint mode = OctalStrToUInt_Pas(modeStr);
                                                int r = FAT16.Chmod(path, mode, callerThreadForSudo);
                                                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] Permissions Changed Successfully!\n\0") Terminal.Print(ok); }
                                                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Failed! Not Found.\n\0") Terminal.Print(e); }
                                            }
                                        }
                                        else if (LibC.StrStartsWith(appName, vChown)) {
                                            char* rest = appName + 6;
                                            char* ownerStr = stackalloc char[32]; char* path = stackalloc char[256];
                                            if (!SplitTwoArgsSudo(rest, ownerStr, 32, path, 256)) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo chown <uid>:<gid> <path>\n\0") Terminal.Print(e); }
                                            else {
                                                int r = FAT16.Chown(path, ownerStr, callerThreadForSudo);
                                                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] Ownership Changed Successfully!\n\0") Terminal.Print(ok); }
                                                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Failed! Not Found.\n\0") Terminal.Print(e); }
                                            }
                                        }

                                        Scheduler.Threads[id].UID = sudoOrigUid; Scheduler.Threads[id].GID = sudoOrigGid;
                                        Terminal.SetColor(0x00FFFFFF);
                                        *(uint*)0x8000UL = 12;
                                        NekkoOS.Kernel.Heap.Free(passBuf);
                                        *(uint*)0x8000UL = 13;
                                        ArchCtx.SetRet(ctx, 1); break;
                                    }
                                }

                                uint appFileSize = 0;
                                byte* rawData = FAT16.ReadFile(appName, &appFileSize, callerThreadForSudo);
                                if (rawData == null || rawData[0] != 'M' || rawData[1] != 'Z') {
                                    if (rawData != null) NekkoOS.Kernel.Heap.Free(rawData);
                                    NekkoOS.Kernel.Heap.Free(passBuf); ArchCtx.SetRet(ctx, 3); break;
                                }

                                PELoader.LoadAndRun(rawData, false, false, true, appName, 1);
                                NekkoOS.Kernel.Heap.Free(passBuf);
                                ArchCtx.SetRet(ctx, 1); break;
                            }
                        }
                        if (!foundAccount) { NekkoOS.Kernel.Heap.Free(passBuf); ArchCtx.SetRet(ctx, 0); }
                    } else { ArchCtx.SetRet(ctx, 0); }
                }
                break;
            }

            // [SYSCALL 96]: XEM GIỜ (Get RTC Seconds)
            case 96: { ArchCtx.SetRet(ctx, RTC.GetSeconds()); break; }

            // [SYSCALL 97]: NGỦ ĐÔNG CÓ HẸN GIỜ (Sleep ms)
            case 97: 
            {
                ulong sleepMs = ArchCtx.GetArg(ctx, 1); ulong ticksToSleep = (sleepMs / 10) + 1; 
                bool irq = Scheduler.AcquireSchedLockSafe();
                Scheduler.Threads[id].WakeUpTick = currentTicks + ticksToSleep;
                Scheduler.Threads[id].Active = 2; 
                Scheduler.ReleaseSchedLockSafe(irq);
                // Context switch ngay — không spin CPU đợi timer.
                ArchCtx.SetRet(ctx, 1);
                return Scheduler.SwitchTask(currentRsp);
            }

            // [SYSCALL 98]: ĐẦU HÀNG TẠM THỜI (Pure Yield)
            case 98: 
            {
                bool irq = Scheduler.AcquireSchedLockSafe();
                Scheduler.Threads[id].VRuntime += 1000; // Đẩy VRuntime để không bị chọn lại ngay
                Scheduler.ReleaseSchedLockSafe(irq);
                // Context switch ngay — thread tiếp tục khi được lên lịch lại.
                ArchCtx.SetRet(ctx, 1);
                return Scheduler.SwitchTask(currentRsp);
            }

            // [SYSCALL 99]: XIN VÀO KHU TỰ TRỊ (Global Shared Memory)
            case 99: 
            {
                bool irq = Scheduler.AcquireSchedLockSafe();

                if (GlobalSharedRAM_Phys == 0) {
                    ulong allocPhys = (ulong)PMM.AllocateContiguousPages(5);
                    if (allocPhys != 0) {
                        GlobalSharedRAM_Phys = allocPhys; 
                    } else {
                        Scheduler.ReleaseSchedLockSafe(irq); 
                        ArchCtx.SetRet(ctx, 0); 
                        break; 
                    }
                }

                if (Scheduler.Threads[id].SharedMemPhys == 0) {
                    ulong allocPage = (ulong)PMM.AllocatePage();
                    if (allocPage == 0) { 
                        Scheduler.ReleaseSchedLockSafe(irq); 
                        ArchCtx.SetRet(ctx, 0); 
                        break; 
                    }

                    Scheduler.Threads[id].SharedMemPhys = allocPage;
                    Scheduler.Threads[id].PhysPages += 1;
                    Scheduler.Threads[id].VirtPages += 5;
                    Scheduler.Threads[id].SharedMemVirt = Scheduler.Threads[id].AppHeapBase;
                    
                    // [PAGING] Use the thread's own PML4 pointer. Validate PML4 and GlobalSharedRAM_Phys
                    ulong* threadPml4 = (ulong*)Scheduler.Threads[id].AddrSpace;
                    if (threadPml4 == null || (ulong)threadPml4 == 0 || (ulong)threadPml4 >= PMM.TotalPages * 4096UL || !Mem.IsCanonical((ulong)threadPml4)) { Scheduler.ReleaseSchedLockSafe(irq); ArchCtx.SetRet(ctx, 0); break; }
                    if (GlobalSharedRAM_Phys == 0 || GlobalSharedRAM_Phys >= PMM.TotalPages * 4096UL) { Scheduler.ReleaseSchedLockSafe(irq); ArchCtx.SetRet(ctx, 0); break; }
                    ulong* currentPml4 = (ulong*)(Arch.ReadPageTable() & 0x000FFFFFFFFFF000UL);
                    if ((ulong*)threadPml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); ArchCtx.SetRet(ctx, 0); break; }
                    Mem.MapPage(allocPage, Scheduler.Threads[id].SharedMemVirt, 0x07, currentPml4); 
                    for (ulong p = 1; p < 5; p++) {
                        ulong cand = GlobalSharedRAM_Phys + (p * 4096);
                        if (cand >= PMM.TotalPages * 4096UL) break;
                        Mem.MapPage(cand, Scheduler.Threads[id].SharedMemVirt + (p * 4096), 0x07, currentPml4);
                    }
                    
                    Scheduler.Threads[id].AppHeapBase += (4096 * 5); 
                }
                
                ulong resultVirt = Scheduler.Threads[id].SharedMemVirt;
                Scheduler.ReleaseSchedLockSafe(irq);
                
                ArchCtx.SetRet(ctx, resultVirt); 
                break;
            }
            
            case 100: 
            {
                // 1. Khóa Scheduler Lock an toàn xuyên đa nhân
                bool irq = Scheduler.AcquireSchedLockSafe();
                
                // 2. [CHẸN HỌNG RACE CONDITION GIÂY CUỐI]
                bool hasMessage = false;
                if (IPC.queue != null)
                {
                    for (int i = 0; i < IPC.MAX_MESSAGES; i++)
                    {
                        if (IPC.queue[i].Type != 0 && IPC.queue[i].Receiver == (uint)id)
                        {
                            hasMessage = true;
                            break;
                        }
                    }
                }

                if (hasMessage)
                {
                    // Thỏ vào chuồng! Quay lại bốc thư cày tiếp kịch tốc độ
                    Scheduler.ReleaseSchedLockSafe(irq);
                    ArchCtx.SetRet(ctx, 1); 
                    break;
                }

                // 3. [CHIẾN LƯỢC HẠ NHIỆT KHÔN NGOAN] 
                // Thay vì ngủ cứng hay ngủ vô thời hạn, ta dùng cơ chế ngủ nhịp ngắn 
                // giúp giữ luồng ở trạng thái Chờ thực sự, ép KernelIdleLoop phải HLT lâu hơn.
                Scheduler.Threads[id].Active = 2; // CHỜ NGẮT / IPC
                Scheduler.Threads[id].WakeUpTick = currentTicks + 2; 

                Scheduler.ReleaseSchedLockSafe(irq);

                // Context switch ngay — không spin CPU vô tận chờ IPC.
                ArchCtx.SetRet(ctx, 1);
                return Scheduler.SwitchTask(currentRsp);
            }

            // [PORTABLE] Arch-specific syscall 101 (shared memory pipeline) delegated to arch vtable
            case 101:
            {
                uint targetPid = (uint)ArchCtx.GetArg(ctx, 1);
                ulong numPages = ArchCtx.GetArg(ctx, 2);
                ulong targetVAddr = 0;
                ulong myVAddr = Arch.SyscallImpl!.DispatchSharedMemoryPipeline(id, (int)targetPid, numPages, &targetVAddr);
                if (myVAddr == 0) { ArchCtx.SetRet(ctx, 0); ArchCtx.SetRet2(ctx, 0); break; }
                ArchCtx.SetRet(ctx, myVAddr);
                ArchCtx.SetRet2(ctx, targetVAddr);
                break;
            }

            // [SYSCALL 60] KHÓA PHẦN CỨNG ATA DÙNG CHUNG (Ring0 <-> Ring3)
            // ==========================================================
            // [FIX RACE CONDITION ATA/SMP] Trước khi ATA.EXE (Ring 3) chạm vào
            // các cổng IDE thô (0x1F0-0x1F7), nó BẮT BUỘC phải xin khóa này.
            // Khóa dùng CHUNG với ATA.AtaHardwareLock mà Kernel (Ring 0) đã
            // dùng cho đường fallback raw driver lúc boot (đọc ATA.EXE/FAT16.EXE/
            // MOUSE.EXE). Nếu không có khóa này, 2 lõi CPU có thể cùng lúc
            // đụng vào chung bộ thanh ghi IDE -> dữ liệu đọc đĩa bị rác ngẫu nhiên
            // -> GPF / Page Fault / "file not found" thoắt ẩn thoắt hiện.
            // [PORTABLE] I/O-specific syscall 60 (ATA lock acquire) delegated to arch vtable
            case 60:
            {
                Arch.SyscallImpl!.DispatchAtaLockAcquire();
                ArchCtx.SetRet(ctx, 1);
                break;
            }

            // [PORTABLE] I/O-specific syscall 61 (ATA lock release) delegated to arch vtable
            case 61:
            {
                Arch.SyscallImpl!.DispatchAtaLockRelease();
                ArchCtx.SetRet(ctx, 1);
                break;
            }

            // [PORTABLE] I/O-specific syscall 399 (reset cursor) delegated to arch vtable
            case 399:
            {
                Arch.SyscallImpl!.DispatchResetCursor();
                ArchCtx.SetRet(ctx, 1);
                break;
            }

            default:
            {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] Invalid call! Error Code: \0") Terminal.Print(err);
                Terminal.PrintDec(syscallId); fixed (char* nl = "\n\0") Terminal.Print(nl);
                break;
            }
        }
        return currentRsp;
    }
}