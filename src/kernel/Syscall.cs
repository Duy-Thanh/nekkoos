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

    // [PASCAL PORT] Compare wide string vs fixed ASCII byte buffer
    [DllImport("*", EntryPoint = "StrEqWideBytes_Pas")]
    private static extern byte StrEqWideBytes_Pas(char* wideStr, byte* byteStr);

    // [PASCAL PORT] Privileged IPC type check (security gate for SIGTERM/shutdown msgs)
    [DllImport("*", EntryPoint = "IsPrivilegedIpcType_Pas")]
    private static extern byte IsPrivilegedIpcType_Pas(uint msgType);

    // [PASCAL PORT] Milliseconds to scheduler ticks conversion
    [DllImport("*", EntryPoint = "MsToTicks_Pas")]
    private static extern ulong MsToTicks_Pas(ulong ms);

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
                // [PASCAL PORT] IsPrivilegedIpcType_Pas replaces inline magic-constant check
                bool isPrivilegedType = IsPrivilegedIpcType_Pas(msgType) != 0;
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
                // [PASCAL PORT] MemCopy_Pas replaces inline byte loop
                LibC.MemCpy(pInfo->Name, Scheduler.Threads[targetId].Name, 16);
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

            // [REFACTOR] Syscall 88 (internal shell) extracted to InternalShell.cs
            case 88:
            {
                InternalShell.Dispatch(id, currentTicks, isKing, ctx);
                break;
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

            // [PORTABLE] Arch-specific syscall 91 (set UID with MPU trap) delegated to arch vtable
            case 91:
            {
                uint targetUID = (uint)ArchCtx.GetArg(ctx, 0);
                fixed (ulong* trapPtr = &MpuTrapPage_Phys) {
                    ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchSetUID(id, targetUID, trapPtr));
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

            // [PORTABLE] Arch-specific syscall 93 (set GID with MPU trap) delegated to arch vtable
            case 93:
            {
                uint targetGID = (uint)ArchCtx.GetArg(ctx, 0);
                fixed (ulong* trapPtr = &MpuTrapPage_Phys) {
                    ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchSetGID(id, targetGID, trapPtr));
                }
                break;
            }

            // [REFACTOR] Syscall 94 (sudo) extracted to Sudo.cs
            case 94:
            {
                Sudo.Dispatch(id, ctx);
                break;
            }

            // [SYSCALL 96]: XEM GIỜ (Get RTC Seconds)
            case 96: { ArchCtx.SetRet(ctx, RTC.GetSeconds()); break; }

            // [SYSCALL 97]: NGỦ ĐÔNG CÓ HẸN GIỜ (Sleep ms)
            case 97:
            {
                // [PASCAL PORT] MsToTicks_Pas replaces inline ms-to-ticks math
                ulong ticksToSleep = MsToTicks_Pas(ArchCtx.GetArg(ctx, 1));
                bool irq = Scheduler.AcquireSchedLockSafe();
                Scheduler.Threads[id].WakeUpTick = currentTicks + ticksToSleep;
                Scheduler.Threads[id].Active = 2;
                Scheduler.ReleaseSchedLockSafe(irq);
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

            // [PORTABLE] Arch-specific syscall 99 (global shared memory) delegated to arch vtable
            case 99:
            {
                fixed (ulong* physPtr = &GlobalSharedRAM_Phys) {
                    ArchCtx.SetRet(ctx, Arch.SyscallImpl!.DispatchGlobalSharedMemory(id, physPtr));
                }
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