using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct Message { 
    public uint Type; 
    public uint Sender; 
    public uint Receiver; 
    public uint IsLocked; // [CỜ MỚI] 0 = Tự do, 1 = Đang có thằng thao tác!
    public ulong Payload; 
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct SharedMemoryBlock { 
    public fixed byte ShellCommandBuffer[4096];
    public fixed byte FatRequestName[4096];
    public fixed byte FatResponseData[8192];
    public fixed byte AtaRawBuffer[4096];
}

public static unsafe class IPC
{
    // Định nghĩa hằng số ulong.MaxValue vì nó không có sẵn trong --stdlib zero
    public const ulong ULongMaxValue = 0xFFFFFFFFFFFFFFFF;

    [DllImport("*", EntryPoint = "CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "StoreFence")] public static extern void StoreFence();
    [DllImport("*", EntryPoint = "FullFence")] public static extern void FullFence();
    [DllImport("*", EntryPoint = "LoadFence")] public static extern void LoadFence();
    
    // [VŨ KHÍ MỚI] GỌI THẲNG LỆNH XCHG TỪ ASSEMBLY!
    [DllImport("*", EntryPoint = "AtomicExchange")] 
    public static extern uint AtomicExchange(ref uint location, uint newValue);

    public static Message* queue;
    public static int MAX_MESSAGES; 

    public static void Init(int capacity = 8192) {
        // Kiểm tra xem capacity có hợp lệ không
        if (capacity <= 0 || capacity > 100000) { // Giới hạn 100,000 tin nhắn
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid IPC capacity!\n\0") Terminal.Print(err);
            return;
        }

        MAX_MESSAGES = capacity;
        ulong requiredBytes = (ulong)MAX_MESSAGES * (ulong)sizeof(Message);

        // Kiểm tra xem phép nhân có gây ra tràn số không
        if (requiredBytes > ULongMaxValue / (ulong)sizeof(Message)) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IPC capacity too large!\n\0") Terminal.Print(err);
            return;
        }

        ulong numPages = (requiredBytes + 4095) / 4096;

        // Kiểm tra xem numPages có hợp lệ không
        if (numPages > 10000) { // Giới hạn 10,000 trang (40MB)
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IPC memory allocation too large!\n\0") Terminal.Print(err);
            return;
        }

        queue = (Message*)PMM.AllocateContiguousPages(numPages);
        if (queue == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Cannot allocate memory for IPC queue!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem queue có được căn chỉnh đúng không
        if (((ulong)queue & 0x7) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IPC queue is not 8-byte aligned!\n\0") Terminal.Print(err);
            return;
        }
        
        LibC.MemSet((byte*)queue, 0, (uint)(numPages * 4096));
        StoreFence();

        Terminal.SetColor(0x00FFFF00);
        fixed (char* msg = "[+] IPC Mailbox (Atomic XCHG MPMC): \0") Terminal.Print(msg); Terminal.PrintDec((uint)MAX_MESSAGES);
        fixed (char* msg3 = " slots secured.\n\0") Terminal.Print(msg3);
    }

    public static bool Send(uint type, uint sender, uint receiver, ulong payload) {
        if (queue == null) return false;
        if (type == 0) return false; 

        for (int i = 0; i < MAX_MESSAGES; i++) {
            // [BỌC THÉP 1] CHỈ KHI NÀO THẤY Ô TRỐNG THÌ MỚI LAO VÀO KHÓA!
            // Tránh việc nện lệnh LOCK XCHG bừa bãi lên các ô đã đầy gây bão Cache!
            if (queue[i].Type == 0 && queue[i].IsLocked == 0) 
            {
                // Lao vào chiếm quyền sở hữu ô RAM
                if (AtomicExchange(ref queue[i].IsLocked, 1) == 0) 
                {
                    // Double check lại một lần nữa cho chắc chắn sau khi đã cầm khóa
                    if (queue[i].Type == 0) 
                    {
                        queue[i].Sender = sender;
                        queue[i].Receiver = receiver;
                        queue[i].Payload = payload;
                        FullFence(); 
                        queue[i].Type = type; // Chốt hạ Type để giải phóng trạng thái trống
                        StoreFence(); 
                        queue[i].IsLocked = 0; // Nhả khóa an toàn

                        // [FIX CVE-2026-001] MÁY ĐÁNH THỨC CORE - BẢO VỆ BẰNG SCHEDLOCK!
                        // Tránh race condition với Timer interrupt hoặc cores khác thay đổi Active state
                        bool schedIrq = Scheduler.AcquireSchedLockSafe();
                        if (Scheduler.Threads[receiver].Active == 2)
                        {
                            Scheduler.Threads[receiver].Active = 1;     // Trở lại trạng thái Ready!
                            Scheduler.Threads[receiver].WakeUpTick = 0; // Xóa cờ ngủ hẹn giờ
                        }
                        Scheduler.ReleaseSchedLockSafe(schedIrq);

                        return true;
                    }
                    queue[i].IsLocked = 0; // Trả khóa nếu bị thằng khác nẫng tay trên giữa chừng
                }
            }
        }
        return false; 
    }

    public static bool SendFromInterrupt(uint type, uint sender, uint receiver, ulong payload) {
        // Kiểm tra xem queue có được khởi tạo chưa
        if (queue == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IPC queue not initialized!\n\0") Terminal.Print(err);
            return false;
        }

        // Y chang hàm Send, vì XCHG an toàn 100% trong Interrupt!
        return Send(type, sender, receiver, payload);
    }

    public static bool ReceiveForRaw(uint receiverId, uint* outType, uint* outSender, ulong* outPayload) {
        if (outType == null || outSender == null || outPayload == null || queue == null) return false;
        
        for (int i = 0; i < MAX_MESSAGES; i++) {
            // [BỌC THÉP 2] Kiểm tra thô trước khi ra đòn khóa nguyên tử
            if (queue[i].Type != 0 && queue[i].Receiver == receiverId && queue[i].IsLocked == 0) 
            {
                if (AtomicExchange(ref queue[i].IsLocked, 1) == 0) 
                {
                    if (queue[i].Type != 0 && queue[i].Receiver == receiverId) {
                        *outType = queue[i].Type; 
                        *outSender = queue[i].Sender;
                        *outPayload = queue[i].Payload;
                        
                        StoreFence();
                        queue[i].Type = 0; // Đánh dấu ô trống NGAY TRONG KHÓA
                        StoreFence();
                        queue[i].IsLocked = 0; // Mở khóa
                        return true;
                    }
                    queue[i].IsLocked = 0; 
                }
            }
        }
        return false;
    }

    public static bool ReceiveRaw(uint* outType, uint* outSender, uint* outReceiver, ulong* outPayload) {
        if (outType == null || outSender == null || outReceiver == null || outPayload == null || queue == null) return false;
        
        for (int i = 0; i < MAX_MESSAGES; i++) {
            // [BỌC THÉP 3] Kiểm tra thô tránh bão Cache Line
            if (queue[i].Type != 0 && queue[i].IsLocked == 0) {
                if (AtomicExchange(ref queue[i].IsLocked, 1) == 0) {
                    if (queue[i].Type != 0) {
                        *outType = queue[i].Type;
                        *outSender = queue[i].Sender;
                        *outReceiver = queue[i].Receiver;
                        *outPayload = queue[i].Payload;
                        StoreFence();
                        queue[i].Type = 0; 
                        StoreFence();
                        queue[i].IsLocked = 0;
                        return true;
                    }
                    queue[i].IsLocked = 0;
                }
            }
        }
        return false;
    }

    public static void ClearMailbox(uint threadId) {
        // Kiểm tra xem queue có được khởi tạo chưa
        if (queue == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IPC queue not initialized!\n\0") Terminal.Print(err);
            return;
        }
        
        for (int i = 0; i < MAX_MESSAGES; i++) {
            if (queue[i].Type != 0 && (queue[i].Receiver == threadId || queue[i].Sender == threadId)) {
                if (AtomicExchange(ref queue[i].IsLocked, 1) == 0) {
                    if (queue[i].Type != 0 && (queue[i].Receiver == threadId || queue[i].Sender == threadId)) {
                        queue[i].Sender = 0;
                        queue[i].Receiver = 0;
                        queue[i].Payload = 0;
                        StoreFence();
                        queue[i].Type = 0;
                    }
                    queue[i].IsLocked = 0;
                }
            }
        }
    }
}