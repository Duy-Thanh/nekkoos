using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct RegisterContext
{
    public ulong R15; public ulong R14; public ulong R13; public ulong R12;
    public ulong R11; public ulong R10; public ulong R9;  public ulong R8;
    public ulong Rdi; public ulong Rsi; public ulong Rbp; public ulong Rbx;
    public ulong Rdx; public ulong Rcx; public ulong Rax;
    
    public ulong ErrorCode; // <-- THÊM THẰNG NÀY VÀO ĐỂ HẤP THỤ 8 BYTES CỦA CPU!
    
    public ulong Rip; public ulong Cs;  public ulong Rflags;
    public ulong Rsp; public ulong Ss;
}

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
    public static ulong GlobalSharedRAM_Phys = 0;
    public static ulong MpuTrapPage_Phys = 0;
    public static Spinlock SharedMemLock;
    private static ulong SyscallLogCounter = 0;

    // Mặt nạ địa chỉ vật lý chuẩn x86_64 (bit 12->51), giống hệt VMM.cs's PHYS_ADDR_MASK.
    private const ulong PHYS_ADDR_MASK = 0x000FFFFFFFFFF000UL;

    // [FIX CRITICAL #2] Trước đây chỉ kiểm tra ptr có nằm trong dải canonical hợp lệ hay
    // không (0x1000 -> 0x00007FFFFFFFFFFF) - KHÔNG hề xác minh trang đó có thực sự được
    // MAP (Present) trong PML4 của chính tiến trình gọi syscall hay chưa. Một con trỏ
    // canonical nhưng CHƯA MAP vẫn lọt qua kiểm tra này, rồi bị Ring0 dereference thẳng ở
    // các syscall (case 1/8/10/14/51/52/88) -> Page Fault xảy ra Ở RING 0
    // (InterruptHandlers.cs PageFaultHandler, nhánh Ring0) -> BroadcastApocalypse() +
    // HardReboot/LegacyReboot/HaltSystemForever - tức là MỘT SYSCALL TỪ RING3 THƯỜNG CŨNG
    // CÓ THỂ RESET/TREO TOÀN BỘ MÁY, không chỉ giết tiến trình gọi nó. Fix: đi bộ (walk)
    // PML4 của chính luồng gọi syscall (Scheduler.CurrentThreadId), xác minh cờ Present
    // (bit 0) VÀ User (bit 2) tồn tại xuyên suốt PML4 -> PDPT -> PD -> PT (hoặc dừng sớm ở
    // PD nếu là Huge Page 2MB) trước khi coi con trỏ là hợp lệ để Ring0 đụng vào.
    private static bool IsPageMappedForUser(int threadId, ulong virtAddr)
    {
        if (threadId < 0 || threadId >= Scheduler.ThreadCount) return false;

        ulong pml4Phys = Scheduler.Threads[threadId].Pml4;
        if (pml4Phys == 0 || pml4Phys >= PMM.TotalPages * 4096UL) return false;
        ulong* pml4 = (ulong*)pml4Phys;

        ulong pml4Index = (virtAddr >> 39) & 0x1FF;
        ulong pdptIndex = (virtAddr >> 30) & 0x1FF;
        ulong pdIndex   = (virtAddr >> 21) & 0x1FF;
        ulong ptIndex   = (virtAddr >> 12) & 0x1FF;

        ulong e4 = pml4[pml4Index];
        if ((e4 & 0x01) == 0 || (e4 & 0x04) == 0) return false; // Present + User

        ulong* pdpt = (ulong*)(e4 & PHYS_ADDR_MASK);
        if (pdpt == null || (ulong)pdpt >= PMM.TotalPages * 4096UL) return false;
        ulong e3 = pdpt[pdptIndex];
        if ((e3 & 0x01) == 0 || (e3 & 0x04) == 0) return false;

        ulong* pd = (ulong*)(e3 & PHYS_ADDR_MASK);
        if (pd == null || (ulong)pd >= PMM.TotalPages * 4096UL) return false;
        ulong e2 = pd[pdIndex];
        if ((e2 & 0x01) == 0 || (e2 & 0x04) == 0) return false;
        if ((e2 & 0x80) != 0) return true; // Huge Page 2MB - đã Present + User, dừng ở đây

        ulong* pt = (ulong*)(e2 & PHYS_ADDR_MASK);
        if (pt == null || (ulong)pt >= PMM.TotalPages * 4096UL) return false;
        ulong e1 = pt[ptIndex];
        if ((e1 & 0x01) == 0 || (e1 & 0x04) == 0) return false;

        return true;
    }

    private static bool IsValidUserPtr(ulong ptr)
    {
        if (ptr < 0x1000 || ptr > 0x00007FFFFFFFFFFF) return false;
        return IsPageMappedForUser(Scheduler.CurrentThreadId, ptr);
    }

    // [SUDO BUILTIN] Tach "arg1 arg2..." thanh 2 phan (vd "755 /file" -> "755","/file"),
    // dung y het logic Shell.cs's SplitTwoArgs (khong the tai su dung truc tiep vi
    // Syscall.cs build rieng vao Kernel.exe, khong link chung voi Shell.cs).
    private static bool SplitTwoArgsSudo(char* rest, char* outFirst, int firstCap, char* outSecond, int secondCap) {
        int i = 0; int f = 0;
        while (rest[i] != '\0' && rest[i] != ' ' && f < firstCap - 1) outFirst[f++] = rest[i++];
        outFirst[f] = '\0';
        if (f == 0) return false;
        while (rest[i] == ' ') i++;
        if (rest[i] == '\0') return false;
        int s = 0; while (rest[i] != '\0' && s < secondCap - 1) outSecond[s++] = rest[i++];
        outSecond[s] = '\0';
        return true;
    }

    [UnmanagedCallersOnly(EntryPoint = "SyscallHandler")]
    public static ulong SyscallHandler(ulong currentRsp)
    {
        // [FIX CHÍ MẠNG VŨ TRỤ] CẤM TUYỆT ĐỐI BẬT NGẮT Ở ĐÂY!
        // Nếu bật ngắt, Timer sẽ nã Context Switch giữa lúc đang thao tác Page Table,
        // ReadCR3() sẽ trả về PML4 của thằng khác → GHI BỘ NHỚ VÀO TIẾN TRÌNH SAI → KERNEL PANIC!
        //
        // ==========================================================
        // [FIX CHÍ MẠNG NGẮT LỒNG - NGUỒN GỐC GPF "THOẮT ẨN THOẮT HIỆN"]
        // TUYỆT ĐỐI CẤM gọi Scheduler.Yield() (dùng "int 0x81") TỪ BÊN TRONG
        // hàm này! SyscallHandler đang chạy TRONG NGẮT "int 0x80" (Ring3->Ring0),
        // nên CPU đã đẩy đủ Frame 5-word (RIP/CS/RFLAGS/RSP/SS) lên Stack.
        // Nếu gọi Yield() ở đây, nó tạo ra một NGẮT MỀM LỒNG bên trong ngắt
        // hiện tại. Vì lúc này đã ở Ring 0 rồi (không đổi quyền), CPU chỉ đẩy
        // Frame CỤT 3-word (RIP/CS=0x08/RFLAGS) cho ngắt lồng đó - KHÔNG có
        // RSP/SS! SwitchTask() lại đi lưu Rsp của Thread NÀY (vốn dĩ là App
        // Ring 3!) trúng ngay cái Frame cụt CS=0x08 (Ring 0) đó. Khi Scheduler
        // sau này phục hồi lại Thread này, IRETQ đọc CS=0x08 -> tưởng vẫn
        // Ring0->Ring0 -> KHÔNG phục hồi RSP/SS thật -> Stack lệch -> IRETQ
        // nạp CS rác từ Stack sai vị trí -> #GP FAULT ngay tại chính IRETQ!
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

        ulong syscallId = ctx->Rax;
        int id = Scheduler.CurrentThreadId;

        // Low-volume syscall logging for triage: sample 1/256 calls
        SyscallLogCounter++;
        if ((SyscallLogCounter & 0xFF) == 0) {
            ulong cr3 = VMM.ReadCR3() & 0x000FFFFFFFFFF000UL;
            fixed (char* s1 = "[SYSCALL] ID: \0") Serial.WriteString(s1);
            Serial.WriteHex(syscallId);
            fixed (char* s2 = " TID: \0") Serial.WriteString(s2);
            Serial.WriteHex((ulong)id);
            fixed (char* s3 = " CR3: \0") Serial.WriteString(s3);
            Serial.WriteHex(cr3);
            fixed (char* nl = "\n\0") Serial.WriteString(nl);
        }

        // Validate scheduler/thread table before touching it
        if (Scheduler.Threads == null || id < 0 || id >= Scheduler.ThreadCount) {
            ctx->Rax = 0; return currentRsp;
        }

        bool isKing = (Scheduler.Threads[id].UID == 0);

        if (Scheduler.Threads[id].IsJailed == 1 && Scheduler.Threads[id].IsPhantomDead == 1)
        {
            if (syscallId == 0) { Scheduler.TerminateCurrentTask(); return currentRsp; }
            if (syscallId == 6 || syscallId == 99) { ctx->Rax = (0x0000DEADBEEF0000 | 0x0000FEEBDEAD0000); return currentRsp; }
            ctx->Rax = 1; 
            return Scheduler.SwitchTask(currentRsp);
        }

        if (Scheduler.Threads[id].IsJailed == 1)
        {
            if (syscallId == 7 || syscallId == 91 || syscallId == 93) { Scheduler.Threads[id].IsPhantomDead = 1; ctx->Rax = 1; return currentRsp; }
            if (syscallId == 6 && ctx->Rcx > 256) { Scheduler.Threads[id].IsPhantomDead = 1; ctx->Rax = (0x0000DEADBEEF0000 & 0x0000FEEBDEAD0000); return currentRsp; }
        }

        ulong currentTicks = Scheduler.SystemTicks;

        switch (syscallId)
        {
            // [SYSCALL 0]: TỰ SÁT (Exit)
            case 0: { Scheduler.TerminateCurrentTask(); break; }
            
            // [SYSCALL 1]: IN CHUỖI RA MÀN HÌNH (Print)
            case 1: 
            {                
                if (ctx->Rcx == 0 || !IsValidUserPtr(ctx->Rcx)) { ctx->Rax = 0; break; }
                char* str = (char*)ctx->Rcx;
                
                bool irq = Terminal.ScreenLock.AcquireSafe();
                int maxPrint = 8192; 
                while (*str != '\0' && maxPrint > 0) 
                {
                    Terminal.DrawCharUnsafe(*str); 
                    str++; maxPrint--;
                }
                Terminal.ScreenLock.ReleaseSafe(irq);
                break;
            }

            // [SYSCALL 2]: VẼ PIXEL (Draw Pixel)
            case 2:
            {
                // [FIX BẢO MẬT - LOW] Chỉ tiến trình đang ở Foreground mới được vẽ lên màn
                // hình dùng chung - trước đây bất kỳ process nền nào cũng vẽ đè lên UI của
                // tiến trình đang active, cùng gốc rễ với bug tranh chấp bàn phím đã vá ở Syscall 4.
                int fgTaskDraw = Scheduler.ForegroundTask;
                bool fgValidDraw = fgTaskDraw >= 0 && fgTaskDraw < Scheduler.ThreadCount && Scheduler.Threads[fgTaskDraw].Active != 0;
                if (fgValidDraw && fgTaskDraw != id) { ctx->Rax = 0; break; }

                uint x = (uint)ctx->Rcx; uint y = (uint)ctx->Rdx; uint color = (uint)ctx->R8;

                // [FIX CHÍ MẠNG] CHẶN ĐỨNG GHI ĐÈ KERNEL MEMORY!
                if (x >= Terminal.width || y >= Terminal.height) { ctx->Rax = 0; break; }

                Terminal.fb[y * Terminal.scanLine + x] = color;
                break;
            }

            // [SYSCALL 3]: XÓA MÀN HÌNH (Clear Screen)
            case 3:
            {
                // [FIX BẢO MẬT - LOW] Cùng gate Foreground như Syscall 2 - chặn tiến trình
                // nền tự ý xóa sạch màn hình của tiến trình đang active.
                int fgTaskClear = Scheduler.ForegroundTask;
                bool fgValidClear = fgTaskClear >= 0 && fgTaskClear < Scheduler.ThreadCount && Scheduler.Threads[fgTaskClear].Active != 0;
                if (fgValidClear && fgTaskClear != id) { ctx->Rax = 0; break; }

                uint bgColor = (uint)ctx->Rcx; Terminal.Clear(bgColor); break;
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
            case 4:
            {
                bool found = false;
                char c = '\0';

                int fgTask = Scheduler.ForegroundTask;
                bool fgValid = fgTask >= 0 && fgTask < Scheduler.ThreadCount && Scheduler.Threads[fgTask].Active != 0;
                bool allowedToConsume = !fgValid || fgTask == id;

                if (allowedToConsume)
                {
                    // Lục soát toàn bộ mảng IPC (Không khóa)
                    for (int i = 0; i < IPC.MAX_MESSAGES; i++)
                    {
                        // Nếu là phím bấm (Type = 1) và từ Keyboard (Sender = 33)
                        if (IPC.queue[i].Type == 1 && IPC.queue[i].Sender == 33)
                        {
                            // [VŨ KHÍ MỚI] Cướp quyền đọc bằng AtomicExchange trên cờ IsLocked!
                            if (IPC.AtomicExchange(ref IPC.queue[i].IsLocked, 1) == 0)
                            {
                                // Kiểm tra lại lần nữa cho chắc sau khi chiếm được khóa ô
                                if (IPC.queue[i].Type == 1 && IPC.queue[i].Sender == 33)
                                {
                                    c = KeyboardDriver.ProcessScanCode((byte)IPC.queue[i].Payload);
                                    IPC.StoreFence();
                                    IPC.queue[i].Type = 0; // Hủy tin nhắn
                                    IPC.StoreFence();
                                    IPC.queue[i].IsLocked = 0; // Nhả khóa
                                    found = true;
                                    break;
                                }
                                IPC.queue[i].IsLocked = 0; // Bị hố thì nhả khóa
                            }
                        }
                    }
                }

                if (found) {
                    if (c != '\0') { ctx->Rax = (ulong)c; } else { ctx->Rax = 0; }
                    break;
                }
                
                // Đi ngủ 1 Tick
                bool irq = Scheduler.AcquireSchedLockSafe();
                Scheduler.Threads[id].WakeUpTick = currentTicks + 1; 
                Scheduler.Threads[id].Active = 2; 
                Scheduler.ReleaseSchedLockSafe(irq);
                
                // Gọi SwitchTask trực tiếp — IsrSyscall dùng mov rsp,rax để
                // nhảy sang thread mới ngay lập tức, không spin CPU vô tận.
                ctx->Rax = 0; 
                return Scheduler.SwitchTask(currentRsp);
            }
            
            // [SYSCALL 5]: GỬI TIN NHẮN IPC (Send IPC)
            case 5:
            {
                uint receiverId = (uint)ctx->Rcx;
                uint msgType = (uint)ctx->Rdx;
                if (receiverId >= Scheduler.ThreadCount || Scheduler.Threads[receiverId].Active == 0) { ctx->Rax = 0; break; }
                if (Scheduler.Threads[id].IsJailed == 1 && (receiverId == 0 || receiverId == 1)) {
                    Scheduler.Threads[id].IsPhantomDead = 1; ctx->Rax = 1; break;
                }

                // [FIX BẢO MẬT - CRITICAL] Type "quyền lực sinh tử" (SIGTERM daemon,
                // shutdown, reboot) chỉ root (UID==0) mới được gửi. Nếu không, bất kỳ
                // user thường nào cũng bắn thẳng 0xDEAD/0xBEEF cho ACPI/ATA/FAT16 Daemon
                // để tắt máy/reboot/kill daemon, bỏ qua hoàn toàn kiểm tra isKing ở case 88.
                bool isPrivilegedType = (msgType == 0xDEAD || msgType == 0xBEEF);
                if (isPrivilegedType && Scheduler.Threads[id].UID != 0) {
                    ctx->Rax = 0; break;
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
                    if (!isFat16Daemon) { ctx->Rax = 0; break; }
                }

                // Gọi Send của cấu trúc Lock-Free mới
                IPC.Send(msgType, (uint)id, receiverId, ctx->R8);

                bool irq = Scheduler.AcquireSchedLockSafe();
                if (Scheduler.Threads[receiverId].Active == 2) {
                    Scheduler.Threads[receiverId].Active = 1; 
                }
                Scheduler.Threads[receiverId].VRuntime = Scheduler.Threads[id].VRuntime;
                Scheduler.ReleaseSchedLockSafe(irq);
                
                // [FIX CHÍ MẠNG NGẮT LỒNG] Bỏ Scheduler.Yield() lồng - xem giải
                // thích ở đầu hàm SyscallHandler. Timer Interrupt tự lo liệu.
                ctx->Rax = 1; break;
            }

            // [SYSCALL 6]: XIN THÊM RAM ẢO (Allocate Heap Memory)
            case 6: 
            {
                ulong numPages = ctx->Rcx;
                if (numPages == 0) { ctx->Rax = Scheduler.Threads[id].AppHeapBase; break; }
                if (!isKing && numPages > 256) { Scheduler.Threads[id].IsPhantomDead = 1; ctx->Rax = 0; break; }
                if (numPages > 1024) { ctx->Rax = 0; break; }

                bool irq = Scheduler.AcquireSchedLockSafe();

                ulong physAddr = (ulong)PMM.AllocateContiguousPages(numPages);
                if (physAddr == 0) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }

                ulong virtAddr = Scheduler.Threads[id].AppHeapBase;
                
                // ==========================================================
                // [FIX CHÍ MẠNG VŨ TRỤ] DÙNG PML4 CỦA THREAD, ĐÉO DÙNG ReadCR3()!
                // Validate the PML4 pointer thoroughly before mapping into it.
                // ==========================================================
                // Ensure caller maps into the currently active PML4 (CR3) to avoid dereferencing other PML4s
                ulong* threadPml4 = (ulong*)Scheduler.Threads[id].Pml4;
                if (threadPml4 == null || (ulong)threadPml4 == 0 || (ulong)threadPml4 >= PMM.TotalPages * 4096UL || !VMM.IsCanonical((ulong)threadPml4)) {
                    Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                // Only allow mapping when the caller's PML4 matches the currently loaded CR3.
                ulong* currentPml4 = (ulong*)(VMM.ReadCR3() & 0x000FFFFFFFFFF000UL);
                if ((ulong*)threadPml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                for(ulong p = 0; p < numPages; p++) { VMM.MapPage(physAddr + (p * 4096), virtAddr + (p * 4096), 0x07, currentPml4); }
                VMM.MapPage(0, virtAddr + (numPages * 4096), 0x04, currentPml4); 

                Scheduler.Threads[id].PhysPages += (uint)numPages;
                Scheduler.Threads[id].VirtPages += (uint)numPages + 1;
                Scheduler.Threads[id].AppHeapBase += (numPages * 4096) + 4096;
                
                Scheduler.ReleaseSchedLockSafe(irq);
                
                ctx->Rax = virtAddr;
                break;
            }

            // [SYSCALL 7]: XIN QUYỀN TRUY CẬP CỔNG PHẦN CỨNG (Grant I/O Port)
            case 7: 
            {
                if (!isKing) { Scheduler.Threads[id].IsPhantomDead = 1; ctx->Rax = 1; break; }
                ushort port = (ushort)ctx->Rcx; GDT.GrantPortAccess(port); ctx->Rax = 1; break;
            }

            // ==========================================================
            // [SYSCALL 8]: KIỂM TRA HÒM THƯ IPC (Receive IPC - Non Blocking)
            // ==========================================================
            case 8: 
            {
                if (ctx->Rcx == 0 || !IsValidUserPtr(ctx->Rcx)) { ctx->Rax = 0; break; }
                
                // Mặc dù User Space (App Ring 3) vẫn dùng struct Message
                // Nhưng Kernel (Ring 0) sẽ hứng qua ReceiveRaw rồi đắp data vào con trỏ đó!
                Message* outMsg = (Message*)ctx->Rcx;
                
                uint rType = 0, rSender = 0; ulong rPayload = 0;
                
                if (IPC.ReceiveForRaw((uint)id, &rType, &rSender, &rPayload)) 
                { 
                    outMsg->Type = rType;
                    outMsg->Sender = rSender;
                    outMsg->Receiver = (uint)id;
                    outMsg->Payload = rPayload;
                    ctx->Rax = 1; 
                } 
                else 
                { 
                    ctx->Rax = 0; 
                }
                break;
            }

            // [SYSCALL 10]: ĐIỀU TRA LÝ LỊCH (Get Process Info)
            case 10: 
            {
                uint targetId = (uint)ctx->Rcx; ulong outPtr = ctx->Rdx;
                if (!IsValidUserPtr(outPtr) || targetId >= Scheduler.ThreadCount) { ctx->Rax = 0; break; }

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
                
                ctx->Rax = 1; break;
            }

            // [SYSCALL 11]: LẤY ĐỊA CHỈ ACPI RSDP
            case 11: { ctx->Rax = Program.GlobalBootInfo->AcpiRsdp; break; }

            // [SYSCALL 12]: MƯỢN ĐẤT PHẦN CỨNG (Map Physical Memory)
            case 12: 
            {
                if (!isKing) { Scheduler.Threads[id].IsPhantomDead = 1; ctx->Rax = 0; break; }
                ulong physAddr = ctx->Rcx; ulong numPages = ctx->Rdx;
                if (numPages == 0 || numPages > 256) { ctx->Rax = 0; break; }

                bool irq = Scheduler.AcquireSchedLockSafe();

                ulong alignedPhys = physAddr & ~0xFFFUL; ulong offset = physAddr & 0xFFFUL; 
                ulong virtAddr = Scheduler.Threads[id].AppHeapBase;
                
                // [FIX CHÍ MẠNG] DÙNG PML4 CỦA THREAD! Validate pointer first.
                ulong* threadPml4 = (ulong*)Scheduler.Threads[id].Pml4;
                if (threadPml4 == null || (ulong)threadPml4 == 0 || (ulong)threadPml4 >= PMM.TotalPages * 4096UL || !VMM.IsCanonical((ulong)threadPml4)) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                // Ensure the syscall is running under the thread's PML4 before mapping.
                ulong* currentPml4 = (ulong*)(VMM.ReadCR3() & 0x000FFFFFFFFFF000UL);
                if ((ulong*)threadPml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                for(ulong p = 0; p < numPages; p++) { VMM.MapPage(alignedPhys + (p * 4096), virtAddr + (p * 4096), 0x07, currentPml4); }
                VMM.MapPage(0, virtAddr + (numPages * 4096), 0x04, currentPml4); 

                Scheduler.Threads[id].AppHeapBase += (numPages * 4096) + 4096;
                Scheduler.ReleaseSchedLockSafe(irq);
                
                ctx->Rax = virtAddr + offset; break;
            }

            // [SYSCALL 13]: KHAI BÁO PHẦN CỨNG BẬC CAO (Hardware Report)
            case 13: 
            {
                if (!isKing) { Scheduler.Threads[id].IsPhantomDead = 1; ctx->Rax = 0; break; }
                uint hwType = (uint)ctx->Rcx; ulong payload = ctx->Rdx;
                if (hwType == 1) { APIC.Init(payload); ctx->Rax = 1; }
                else if (hwType == 2) { APIC.CoreCount = (uint)payload; ctx->Rax = 1; }
                else if (hwType == 3) { APIC.IOApicBase = payload; ctx->Rax = 1; }
                else { ctx->Rax = 0; }
                break;
            }

            // [SYSCALL 14]: TÌM NGƯỜI THÂN (Get PID By Name)
            case 14: 
            {
                if (!IsValidUserPtr(ctx->Rcx)) { ctx->Rax = unchecked((ulong)-1); break; }
                char* targetName = (char*)ctx->Rcx; long foundId = -1; 

                bool irq = Scheduler.AcquireSchedLockSafe(); 
                for (int i = 1; i < Scheduler.ThreadCount; i++) {
                    if (Scheduler.Threads[i].Active != 0) {
                        bool match = true;
                        for (int j = 0; j < 15; j++) {
                            if (targetName[j] == '\0' && Scheduler.Threads[i].Name[j] == '\0') break;
                            if (targetName[j] != Scheduler.Threads[i].Name[j]) { match = false; break; }
                        }
                        if (match) { foundId = i; break; }
                    }
                }
                Scheduler.ReleaseSchedLockSafe(irq);
                
                ctx->Rax = (ulong)foundId; break;
            }

            // [SYSCALL 50] YÊU CẦU QUYỀN SỞ HỮU MÀN HÌNH (MAP FRAMEBUFFER)
            case 50: 
            {
                if (!isKing) { 
                    Scheduler.Threads[id].IsPhantomDead = 1; 
                    ctx->Rax = 0; 
                    break; 
                }

                ulong fbPhys = Program.GlobalBootInfo->FrameBufferBase; 
                ulong fbSize = (ulong)(Terminal.scanLine * Terminal.height * 4); 
                
                ulong vAddr = Scheduler.Threads[id].AppHeapBase; 

                ulong numPages = (fbSize + 4095) / 4096;
                ulong pml4 = Scheduler.Threads[id].Pml4;

                if (pml4 == 0 || pml4 >= PMM.TotalPages * 4096UL || !VMM.IsCanonical(pml4)) { ctx->Rax = 0; break; }

                bool irq = Scheduler.AcquireSchedLockSafe();

                // Map only when current CR3 equals the thread's PML4.
                ulong* currentPml4 = (ulong*)(VMM.ReadCR3() & 0x000FFFFFFFFFF000UL);
                if ((ulong*)pml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                for(ulong p = 0; p < numPages; p++) {
                    VMM.MapPage(fbPhys + (p * 4096), vAddr + (p * 4096), 0x07, currentPml4);
                }
                
                Scheduler.Threads[id].AppHeapBase += (numPages * 4096) + 4096;
                Scheduler.Threads[id].VirtPages += (uint)numPages;
                
                Scheduler.ReleaseSchedLockSafe(irq);

                ctx->Rax = vAddr; 
                break;
            }

            // [SYSCALL 51]
            case 51:
            {
                ulong* ptrWidth = (ulong*)ctx->Rcx;
                ulong* ptrHeight = (ulong*)ctx->Rdx;
                ulong* ptrScanLine = (ulong*)ctx->R8;

                if (ptrWidth != null && IsValidUserPtr((ulong)ptrWidth)) *ptrWidth = Terminal.width;
                if (ptrHeight != null && IsValidUserPtr((ulong)ptrHeight)) *ptrHeight = Terminal.height;
                if (ptrScanLine != null && IsValidUserPtr((ulong)ptrScanLine)) *ptrScanLine = Terminal.scanLine;

                ctx->Rax = 1; 
                break;
            }

            // [SYSCALL 52] ĐỔI HƯỚNG TERMINAL (VIRTUAL FRAMEBUFFER)
            case 52:
            {
                // [FIX BẢO MẬT - HIGH] Chỉ root mới được đổi hướng Terminal toàn cục -
                // Terminal.fb/width/height/scanLine là state DÙNG CHUNG toàn hệ thống,
                // trước đây bất kỳ process nào (kể cả jailed) cũng chiếm được nó.
                if (!isKing) {
                    Scheduler.Threads[id].IsPhantomDead = 1;
                    ctx->Rax = 0;
                    break;
                }

                ulong newFb = ctx->Rcx;
                uint w = (uint)ctx->Rdx;
                uint h = (uint)ctx->R8;
                uint sl = (uint)ctx->R9;

                if (IsValidUserPtr(newFb)) {
                    Terminal.RedirectOutput((uint*)newFb, w, h, sl);
                    ctx->Rax = 1;
                } else {
                    ctx->Rax = 0;
                }
                break;
            }

            // [SYSCALL 88]: BỘ ĐÀM TỔNG TƯ LỆNH (Internal Shell / Run Daemon)
            case 88: 
            {
                if (ctx->Rcx == 0 || !IsValidUserPtr(ctx->Rcx)) { ctx->Rax = 0; break; }
                char* cmdStr = (char*)ctx->Rcx;

                // Lấy địa chỉ cửa sổ ảo do CMD.EXE truyền vào qua RDX
                ulong targetFb = ctx->Rdx; 

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
                                        if ((c >= 32 && c <= 126) || c == '\n' || c == '\t') Terminal.DrawChar(c);
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
                            ctx->Rax = 0; break; 
                        }

                        char* appName = isDaemon ? cmdStr + 7 : cmdStr + 4;
                        if (*appName == '\0') { ctx->Rax = 0; break; }

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
                                NekkoOS.Kernel.Heap.Free(rawData); ctx->Rax = 0; break; 
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
                
                Terminal.SetColor(0x00FFFFFF); ctx->Rax = 1; break;
            }

            // [SYSCALL 89]: XEM CHỨNG MINH THƯ (Get Current UID)
            case 89: { ctx->Rax = Scheduler.Threads[id].UID; break; }

            // [SYSCALL 90]: ĐIỀU TRA CHỨNG MINH THƯ KẺ KHÁC (Get Target UID)
            case 90: 
            {
                uint targetThread = (uint)ctx->Rbx;
                if (targetThread < Scheduler.ThreadCount) { ctx->Rax = Scheduler.Threads[targetThread].UID; } 
                else { ctx->Rax = 9999; }
                break;
            }

            // [SYSCALL 91]: TỰ RỚT ĐÀI (Set UID - Drop Privilege)
            case 91: 
            {
                uint targetUID = (uint)ctx->Rbx; uint currentUID = Scheduler.Threads[id].UID;
                if (currentUID == 0 || targetUID == currentUID) { Scheduler.Threads[id].UID = targetUID; ctx->Rax = 1; } 
                else {
                    if (MpuTrapPage_Phys == 0) MpuTrapPage_Phys = (ulong)PMM.AllocatePage();
                    if (Scheduler.Threads[id].SharedMemVirt != 0) {
                        ulong pml4tmp = Scheduler.Threads[id].Pml4;
                        if (pml4tmp != 0 && pml4tmp < PMM.TotalPages * 4096UL && VMM.IsCanonical(pml4tmp)) {
                            VMM.MapPage(MpuTrapPage_Phys, Scheduler.Threads[id].SharedMemVirt, 0x05, (ulong*)pml4tmp);
                        }
                    }
                    ctx->Rax = 0; 
                }
                break;
            }

            // [SYSCALL 92 & 93]: ĐIỀU TRA & XÉT DUYỆT GROUP ID (Get/Set GID)
            case 92: 
            {
                uint targetThreadForGID = (uint)ctx->Rbx;
                if (targetThreadForGID < Scheduler.ThreadCount) { ctx->Rax = Scheduler.Threads[targetThreadForGID].GID; } 
                else { ctx->Rax = 9999; }
                break;
            }

            case 93: 
            {
                uint targetGID = (uint)ctx->Rbx; uint currentGID = Scheduler.Threads[id].GID;
                if (currentGID == 0 || Scheduler.Threads[id].UID == 0 || targetGID == currentGID) { Scheduler.Threads[id].GID = targetGID; ctx->Rax = 1; } 
                else {
                    if (MpuTrapPage_Phys == 0) MpuTrapPage_Phys = (ulong)PMM.AllocatePage();
                    if (Scheduler.Threads[id].SharedMemVirt != 0) {
                        ulong pml4tmp = Scheduler.Threads[id].Pml4;
                        if (pml4tmp != 0 && pml4tmp < PMM.TotalPages * 4096UL && VMM.IsCanonical(pml4tmp)) {
                            VMM.MapPage(MpuTrapPage_Phys, Scheduler.Threads[id].SharedMemVirt, 0x05, (ulong*)pml4tmp);
                        }
                    }
                    ctx->Rax = 0; 
                }
                break;
            }

            // [SYSCALL 94]: SUDO (Elevate-one-command)
            // Xác thực lại mật khẩu của CHÍNH thread gọi (dò bằng UID thật của
            // Scheduler.Threads[id], không tin username tự khai) qua /ETC/PASSWD,
            // kiểm tra /ETC/SUDOERS, rồi nếu đúng: nạp app với forceRoot:true.
            // Thread gọi (Shell.exe) KHÔNG hề bị đổi UID/GID - chỉ tiến trình MỚI
            // sinh ra mang UID/GID root, đúng phạm vi "một lệnh" đã chốt trong kế hoạch.
            // ctx->Rax trả về: 0=sai mật khẩu/không có tài khoản, 1=thành công,
            // 2=không nằm trong sudoers, 3=không tìm thấy app cần chạy.
            case 94:
            {
                if (ctx->Rcx == 0 || !IsValidUserPtr(ctx->Rcx) || ctx->Rdx == 0 || !IsValidUserPtr(ctx->Rdx)) { ctx->Rax = 0; break; }
                char* appName = (char*)ctx->Rcx;
                char* inputPass = (char*)ctx->Rdx;

                // [SUDO WRITE] R8 = con tro Ring3 toi noi dung "write" da duoc Shell.cs
                // tu doc tu ban phim SAN (0/null neu app khong phai "write <path>"),
                // R9 = do dai byte. Validate y het appName/inputPass truoc khi doc thang
                // tu Ring0 - KHONG dung shared memory de tranh dung do voi AtaRawBuffer/
                // FatResponseData dang duoc cac thao tac disk khac dung song song.
                byte* sudoWriteContent = (ctx->R8 != 0 && IsValidUserPtr(ctx->R8)) ? (byte*)ctx->R8 : null;
                uint sudoWriteContentLen = (uint)ctx->R9;

                int callerThreadForSudo = id;
                uint callerUidForSudo = Scheduler.Threads[id].UID;
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

                    if (passBuf != null && passSize > 0) {
                        int i = 0;
                        while (i < (int)passSize) {
                            int u = 0, s = 0, h = 0, ud = 0; int stage = 0;
                            while (i < (int)passSize && passBuf[i] != '\n' && passBuf[i] != '\r') {
                                char c = (char)passBuf[i];
                                if (c == ':') { stage++; }
                                else {
                                    if (stage == 0 && u < 31) lineUser[u++] = c;
                                    else if (stage == 1 && s < 63) lineSalt[s++] = c;
                                    else if (stage == 2 && h < 79) lineHash[h++] = c;
                                    else if (stage == 3 && ud < 15) lineUID[ud++] = c;
                                }
                                i++;
                            }
                            lineUser[u] = '\0'; lineSalt[s] = '\0'; lineHash[h] = '\0'; lineUID[ud] = '\0';

                            uint lineUidVal = 0;
                            for (int k = 0; lineUID[k] != '\0'; k++) { if (lineUID[k] >= '0' && lineUID[k] <= '9') lineUidVal = lineUidVal * 10 + (uint)(lineUID[k] - '0'); else break; }

                            if (u > 0 && lineUidVal == callerUidForSudo) {
                                int mm = 0; while (lineUser[mm] != '\0' && mm < 31) { matchedUser[mm] = lineUser[mm]; mm++; } matchedUser[mm] = '\0';

                                int saltLen = KernHexUtil.HexToBytes(lineSalt, saltBytes, 32);
                                int passLen = 0; while (inputPass[passLen] != '\0') passLen++;
                                int hashInputLen = 0;
                                for (int k = 0; k < saltLen; k++) hashInputBuf[hashInputLen++] = saltBytes[k];
                                for (int k = 0; k < passLen; k++) hashInputBuf[hashInputLen++] = (byte)inputPass[k];

                                SHA256.Compute(hashInputBuf, (ulong)hashInputLen, computedHash);
                                KernHexUtil.BytesToHex(computedHash, 32, computedHashHex);

                                foundAccount = true;
                                bool passOk = KernHexUtil.ConstantTimeEq(computedHashHex, lineHash, 64);

                                KernHexUtil.ZeroMemChar(lineSalt, 64); KernHexUtil.ZeroMemChar(lineHash, 80);
                                KernHexUtil.ZeroMemByte(saltBytes, 32); KernHexUtil.ZeroMemByte(hashInputBuf, 64);
                                KernHexUtil.ZeroMemByte(computedHash, 32); KernHexUtil.ZeroMemChar(computedHashHex, 80);

                                if (!passOk) { NekkoOS.Kernel.Heap.Free(passBuf); ctx->Rax = 0; break; }

                                // Kiểm tra /ETC/SUDOERS: username đọc được từ chính PASSWD (không
                                // phải do Ring3 tự khai) có nằm trong danh sách cho phép không.
                                bool inSudoers = false;
                                fixed (char* sudoersFile = "SUDOERS\0") {
                                    FAT16.Cd(dirEtc, 0);
                                    uint sudoSize = 0;
                                    // [FIX BAO MAT] Tuong tu PASSWD o tren - doc SUDOERS bang
                                    // tham quyen von co cua Kernel (callerThreadOverride=0), khong
                                    // dung UID that cua nguoi goi.
                                    byte* sudoBuf = FAT16.ReadFile(sudoersFile, &sudoSize, 0);
                                    FAT16.Cd(dirRoot, 0);
                                    if (sudoBuf != null && sudoSize > 0) {
                                        int j = 0;
                                        while (j < (int)sudoSize) {
                                            char* lineSudo = stackalloc char[32]; int ls = 0;
                                            while (j < (int)sudoSize && sudoBuf[j] != '\n' && sudoBuf[j] != '\r' && ls < 31) { lineSudo[ls++] = (char)sudoBuf[j]; j++; }
                                            lineSudo[ls] = '\0';
                                            while (j < (int)sudoSize && sudoBuf[j] != '\n' && sudoBuf[j] != '\r') j++;
                                            while (j < (int)sudoSize && (sudoBuf[j] == '\n' || sudoBuf[j] == '\r')) j++;
                                            if (ls > 0 && LibC.StrCmp(lineSudo, matchedUser)) { inSudoers = true; break; }
                                        }
                                        NekkoOS.Kernel.Heap.Free(sudoBuf);
                                    }
                                }

                                if (!inSudoers) { NekkoOS.Kernel.Heap.Free(passBuf); ctx->Rax = 2; break; }

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
                                        uint sudoOrigUid = Scheduler.Threads[id].UID;
                                        uint sudoOrigGid = Scheduler.Threads[id].GID;
                                        Scheduler.Threads[id].UID = 0; Scheduler.Threads[id].GID = 0;

                                        if (LibC.StrCmp(appName, vLs) || LibC.StrCmp(appName, vLl)) {
                                            char* listBuf = stackalloc char[2048];
                                            if (FAT16.ListDir(listBuf, 2048, callerThreadForSudo)) {
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
                                                            if ((c >= 32 && c <= 126) || c == '\n' || c == '\t') Terminal.DrawChar(c);
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
                                                uint mode = 0; for (int mi = 0; modeStr[mi] != '\0'; mi++) { if (modeStr[mi] < '0' || modeStr[mi] > '7') break; mode = mode * 8 + (uint)(modeStr[mi] - '0'); }
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
                                        NekkoOS.Kernel.Heap.Free(passBuf);
                                        ctx->Rax = 1; break;
                                    }
                                }

                                uint appFileSize = 0;
                                byte* rawData = FAT16.ReadFile(appName, &appFileSize, callerThreadForSudo);
                                if (rawData == null || rawData[0] != 'M' || rawData[1] != 'Z') {
                                    if (rawData != null) NekkoOS.Kernel.Heap.Free(rawData);
                                    NekkoOS.Kernel.Heap.Free(passBuf); ctx->Rax = 3; break;
                                }

                                PELoader.LoadAndRun(rawData, false, false, true, appName, 1);
                                NekkoOS.Kernel.Heap.Free(passBuf);
                                ctx->Rax = 1; break;
                            }
                            while (i < (int)passSize && (passBuf[i] == '\n' || passBuf[i] == '\r')) i++;
                        }
                        if (!foundAccount) { NekkoOS.Kernel.Heap.Free(passBuf); ctx->Rax = 0; }
                    } else { ctx->Rax = 0; }
                }
                break;
            }

            // [SYSCALL 96]: XEM GIỜ (Get RTC Seconds)
            case 96: { ctx->Rax = RTC.GetSeconds(); break; }

            // [SYSCALL 97]: NGỦ ĐÔNG CÓ HẸN GIỜ (Sleep ms)
            case 97: 
            {
                ulong sleepMs = ctx->Rcx; ulong ticksToSleep = (sleepMs / 10) + 1; 
                bool irq = Scheduler.AcquireSchedLockSafe();
                Scheduler.Threads[id].WakeUpTick = currentTicks + ticksToSleep;
                Scheduler.Threads[id].Active = 2; 
                Scheduler.ReleaseSchedLockSafe(irq);
                // Context switch ngay — không spin CPU đợi timer.
                ctx->Rax = 1;
                return Scheduler.SwitchTask(currentRsp);
            }

            // [SYSCALL 98]: ĐẦU HÀNG TẠM THỜI (Pure Yield)
            case 98: 
            {
                bool irq = Scheduler.AcquireSchedLockSafe();
                Scheduler.Threads[id].VRuntime += 1000; // Đẩy VRuntime để không bị chọn lại ngay
                Scheduler.ReleaseSchedLockSafe(irq);
                // Context switch ngay — thread tiếp tục khi được lên lịch lại.
                ctx->Rax = 1;
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
                        ctx->Rax = 0; 
                        break; 
                    }
                }

                if (Scheduler.Threads[id].SharedMemPhys == 0) {
                    ulong allocPage = (ulong)PMM.AllocatePage();
                    if (allocPage == 0) { 
                        Scheduler.ReleaseSchedLockSafe(irq); 
                        ctx->Rax = 0; 
                        break; 
                    }

                    Scheduler.Threads[id].SharedMemPhys = allocPage;
                    Scheduler.Threads[id].PhysPages += 1;
                    Scheduler.Threads[id].VirtPages += 5;
                    Scheduler.Threads[id].SharedMemVirt = Scheduler.Threads[id].AppHeapBase;
                    
                    // [FIX CHÍ MẠNG] DÙNG PML4 CỦA THREAD! Validate PML4 and GlobalSharedRAM_Phys
                    ulong* threadPml4 = (ulong*)Scheduler.Threads[id].Pml4;
                    if (threadPml4 == null || (ulong)threadPml4 == 0 || (ulong)threadPml4 >= PMM.TotalPages * 4096UL || !VMM.IsCanonical((ulong)threadPml4)) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                    if (GlobalSharedRAM_Phys == 0 || GlobalSharedRAM_Phys >= PMM.TotalPages * 4096UL) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                    ulong* currentPml4 = (ulong*)(VMM.ReadCR3() & 0x000FFFFFFFFFF000UL);
                    if ((ulong*)threadPml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                    VMM.MapPage(allocPage, Scheduler.Threads[id].SharedMemVirt, 0x07, currentPml4); 
                    for (ulong p = 1; p < 5; p++) {
                        ulong cand = GlobalSharedRAM_Phys + (p * 4096);
                        if (cand >= PMM.TotalPages * 4096UL) break;
                        VMM.MapPage(cand, Scheduler.Threads[id].SharedMemVirt + (p * 4096), 0x07, currentPml4);
                    }
                    
                    Scheduler.Threads[id].AppHeapBase += (4096 * 5); 
                }
                
                ulong resultVirt = Scheduler.Threads[id].SharedMemVirt;
                Scheduler.ReleaseSchedLockSafe(irq);
                
                ctx->Rax = resultVirt; 
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
                    ctx->Rax = 1; 
                    break;
                }

                // 3. [CHIẾN LƯỢC HẠ NHIỆT KHÔN NGOAN] 
                // Thay vì ngủ cứng hay ngủ vô thời hạn, ta dùng cơ chế ngủ nhịp ngắn 
                // giúp giữ luồng ở trạng thái Chờ thực sự, ép KernelIdleLoop phải HLT lâu hơn.
                Scheduler.Threads[id].Active = 2; // CHỜ NGẮT / IPC
                Scheduler.Threads[id].WakeUpTick = currentTicks + 2; 

                Scheduler.ReleaseSchedLockSafe(irq);

                // Context switch ngay — không spin CPU vô tận chờ IPC.
                ctx->Rax = 1;
                return Scheduler.SwitchTask(currentRsp);
            }

            // [SYSCALL 101] CẦU ÁNH SÁNG (SECURE SHARED MEMORY PIPELINE)
            case 101:
            {
                uint targetPid = (uint)ctx->Rcx;
                ulong numPages = ctx->Rdx;

                if (targetPid >= Scheduler.ThreadCount || Scheduler.Threads[targetPid].Active == 0) { ctx->Rax = 0; break; }
                if (numPages == 0 || numPages > 4096) { ctx->Rax = 0; break; } 

                bool irq = Scheduler.AcquireSchedLockSafe();

                ulong myVAddr = Scheduler.Threads[id].AppHeapBase;
                ulong targetVAddr = Scheduler.Threads[targetPid].AppHeapBase;
                ulong targetPml4 = Scheduler.Threads[targetPid].Pml4;
                // [FIX CHÍ MẠNG] DÙNG PML4 CỦA THREAD THAY VÌ ReadCR3()!
                ulong* myPml4 = (ulong*)Scheduler.Threads[id].Pml4;
                if (myPml4 == null || (ulong)myPml4 == 0 || (ulong)myPml4 >= PMM.TotalPages * 4096UL || !VMM.IsCanonical((ulong)myPml4)) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                if (targetPml4 == 0 || targetPml4 >= PMM.TotalPages * 4096UL || !VMM.IsCanonical(targetPml4)) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }

                ulong physAddr = (ulong)PMM.AllocateContiguousPages(numPages);
                if (physAddr == 0) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }

                // Require current CR3 to match caller's PML4 before mapping into caller space.
                ulong* currentPml4 = (ulong*)(VMM.ReadCR3() & 0x000FFFFFFFFFF000UL);
                if ((ulong*)myPml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); ctx->Rax = 0; break; }
                for(ulong p = 0; p < numPages; p++) {
                    VMM.MapPage(physAddr + (p * 4096), myVAddr + (p * 4096), 0x07, currentPml4); 
                    // Only map into target PML4 if it matches current CR3 (otherwise skip to avoid unsafe deref)
                    if ((ulong*)targetPml4 == currentPml4) {
                        VMM.MapPage(physAddr + (p * 4096), targetVAddr + (p * 4096), 0x07, (ulong*)targetPml4);
                    }
                }

                Scheduler.Threads[id].PhysPages += (uint)numPages;
                Scheduler.Threads[id].VirtPages += (uint)numPages;
                Scheduler.Threads[id].AppHeapBase += (numPages * 4096);

                Scheduler.Threads[targetPid].VirtPages += (uint)numPages;
                Scheduler.Threads[targetPid].AppHeapBase += (numPages * 4096);

                Scheduler.ReleaseSchedLockSafe(irq);

                // [FIX CHÍ MẠNG] Only load PML4 if it matches current CR3 to avoid loading
                // an attacker-controlled or stale PML4 (hard-block unsafe loads).
                ulong* currentPml4_after = (ulong*)(VMM.ReadCR3() & 0x000FFFFFFFFFF000UL);
                if ((ulong*)myPml4 == currentPml4_after) {
                    VMM.LoadPML4_ASM((void*)myPml4);
                } else {
                    // Unsafe to load other PML4 — fail the syscall rather than risk instability.
                    ctx->Rax = 0; ctx->Rbx = 0; return currentRsp;
                }

                ctx->Rax = myVAddr; 
                ctx->Rbx = targetVAddr; 
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
            case 60:
            {
                Driver.ATA.AtaHardwareLock.Acquire();
                ctx->Rax = 1;
                break;
            }

            // [SYSCALL 61] MỞ KHÓA PHẦN CỨNG ATA DÙNG CHUNG
            case 61:
            {
                Driver.ATA.AtaHardwareLock.Release();
                ctx->Rax = 1;
                break;
            }

            // [SYSCALL 399]: DỌN DẸP BÃI CHIẾN TRƯỜNG (Reset Cursor)
            case 399: 
            {
                bool irq = Terminal.ScreenLock.AcquireSafe();
                Terminal.CursorX = 0; 
                Terminal.CursorY = 0;
                Terminal.ScreenLock.ReleaseSafe(irq);
                
                ctx->Rax = 1; 
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