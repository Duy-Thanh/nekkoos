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
// [PASCAL PORT] The mailbox lives in ipc_kernel.pas (queue ownership and
// wake-up policy) on top of the ipc.pas MPMC algorithm. This class only
// forwards, and keeps the record layouts C# callers still index directly.
// ==========================================================
public static unsafe class IPC
{
    public const ulong ULongMaxValue = 0xFFFFFFFFFFFFFFFF;

    public static void CompilerFence() => Arch.CompilerFence();
    public static void StoreFence() => Arch.StoreFence();
    public static void FullFence() => Arch.FullFence();
    public static void LoadFence() => Arch.LoadFence();

    public static uint AtomicExchange(ref uint location, uint newValue) => Arch.AtomicExchange(ref location, newValue);

    [DllImport("*", EntryPoint = "IpcK_Init_Pas")] private static extern void Init_Pas(int capacity);
    [DllImport("*", EntryPoint = "IpcK_Send_Pas")] private static extern byte Send_Pas(uint type, uint sender, uint receiver, ulong payload);
    [DllImport("*", EntryPoint = "IpcK_SendFromInterrupt_Pas")] private static extern byte SendFromInterrupt_Pas(uint type, uint sender, uint receiver, ulong payload);
    [DllImport("*", EntryPoint = "IpcK_ReceiveForRaw_Pas")] private static extern byte ReceiveForRaw_Pas(uint receiverId, uint* outType, uint* outSender, ulong* outPayload);
    [DllImport("*", EntryPoint = "IpcK_ReceiveRaw_Pas")] private static extern byte ReceiveRaw_Pas(uint* outType, uint* outSender, uint* outReceiver, ulong* outPayload);
    [DllImport("*", EntryPoint = "IpcK_ClearMailbox_Pas")] private static extern void ClearMailbox_Pas(uint threadId);
    [DllImport("*", EntryPoint = "IpcK_GetQueue_Pas")] private static extern Message* GetQueue_Pas();
    [DllImport("*", EntryPoint = "IpcK_GetMax_Pas")] private static extern int GetMax_Pas();
    [DllImport("*", EntryPoint = "IpcK_HasMessageFor_Pas")] private static extern byte HasMessageFor_Pas(uint receiverId);

    public static Message* queue => GetQueue_Pas();
    public static int MAX_MESSAGES => GetMax_Pas();

    public static void Init(int capacity = 8192) => Init_Pas(capacity);
    public static bool Send(uint type, uint sender, uint receiver, ulong payload) => Send_Pas(type, sender, receiver, payload) != 0;
    public static bool SendFromInterrupt(uint type, uint sender, uint receiver, ulong payload) => SendFromInterrupt_Pas(type, sender, receiver, payload) != 0;
    public static bool ReceiveForRaw(uint receiverId, uint* outType, uint* outSender, ulong* outPayload) => ReceiveForRaw_Pas(receiverId, outType, outSender, outPayload) != 0;
    public static bool ReceiveRaw(uint* outType, uint* outSender, uint* outReceiver, ulong* outPayload) => ReceiveRaw_Pas(outType, outSender, outReceiver, outPayload) != 0;
    public static void ClearMailbox(uint threadId) => ClearMailbox_Pas(threadId);
    public static bool HasMessageFor(uint receiverId) => HasMessageFor_Pas(receiverId) != 0;
}
