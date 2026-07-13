// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

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

// ==========================================================
// INTEROP: Core MPMC lock-free queue algorithm (architecture-independent)
// ported to src/ipc.pas. Atomic operations (XCHG, fences) are x86_64-specific
// but abstracted as function calls, so the queue algorithm itself is portable.
// C# keeps Init() (PMM allocation) and Scheduler wakeup policy.
// ==========================================================
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

    // ==========================================================
    // INTEROP: Gọi sang Pascal MPMC queue algorithms
    // ==========================================================
    [DllImport("*", EntryPoint = "IPC_SendCore_Pas")]
    private static extern byte IPC_SendCore_Pas(Message* queue, int maxMessages, uint type, uint sender, uint receiver, ulong payload, out byte needsWakeup, out uint wakeReceiverId);

    [DllImport("*", EntryPoint = "IPC_ReceiveFor_Pas")]
    private static extern byte IPC_ReceiveFor_Pas(Message* queue, int maxMessages, uint receiverId, out uint type, out uint sender, out ulong payload);

    [DllImport("*", EntryPoint = "IPC_Receive_Pas")]
    private static extern byte IPC_Receive_Pas(Message* queue, int maxMessages, out uint type, out uint sender, out uint receiver, out ulong payload);

    [DllImport("*", EntryPoint = "IPC_ClearMailbox_Pas")]
    private static extern void IPC_ClearMailbox_Pas(Message* queue, int maxMessages, uint threadId);

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

        // ==========================================================
        // [ARCHITECTURE DECOUPLING] Delegate MPMC queue algorithm to Pascal.
        // Only thread wakeup policy (OS-specific) stays in C#.
        // ==========================================================
        byte needsWakeup;
        uint wakeReceiverId;
        byte success = IPC_SendCore_Pas(queue, MAX_MESSAGES, type, sender, receiver, payload, out needsWakeup, out wakeReceiverId);

        if (success != 0 && needsWakeup != 0)
        {
            // [FIX CVE-2026-001] MÁY ĐÁNH THỨC CORE - BẢO VỆ BẰNG SCHEDLOCK!
            // Tránh race condition với Timer interrupt hoặc cores khác thay đổi Active state
            bool schedIrq = Scheduler.AcquireSchedLockSafe();
            if (Scheduler.Threads[wakeReceiverId].Active == 2)
            {
                Scheduler.Threads[wakeReceiverId].Active = 1;     // Trở lại trạng thái Ready!
                Scheduler.Threads[wakeReceiverId].WakeUpTick = 0; // Xóa cờ ngủ hẹn giờ
            }
            Scheduler.ReleaseSchedLockSafe(schedIrq);
        }

        return success != 0;
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

        uint type, sender;
        ulong payload;
        byte success = IPC_ReceiveFor_Pas(queue, MAX_MESSAGES, receiverId, out type, out sender, out payload);

        if (success != 0)
        {
            *outType = type;
            *outSender = sender;
            *outPayload = payload;
            return true;
        }

        return false;
    }

    public static bool ReceiveRaw(uint* outType, uint* outSender, uint* outReceiver, ulong* outPayload) {
        if (outType == null || outSender == null || outReceiver == null || outPayload == null || queue == null) return false;

        uint type, sender, receiver;
        ulong payload;
        byte success = IPC_Receive_Pas(queue, MAX_MESSAGES, out type, out sender, out receiver, out payload);

        if (success != 0)
        {
            *outType = type;
            *outSender = sender;
            *outReceiver = receiver;
            *outPayload = payload;
            return true;
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

        IPC_ClearMailbox_Pas(queue, MAX_MESSAGES, threadId);
    }
}