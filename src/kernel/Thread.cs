// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// (No deferred mapping table; keep scheduler/thread layout unchanged.)

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct Thread
{
    public ulong Rsp;           
    public byte Active; // 0 = Dead (can't be choose) 
                        // 1 = Runnable (can be choose)
                        // 2 = Sleeping (can't be choose)
                        // 3 = Being Created (can't be choose) 
                        // 4 = Zombie (can't be choose)     
    public byte IsJailed;       
    public byte IsPhantomDead;  
    public byte Padding1;       
    public int ParentId;        
    
    public int ExecutingOnCore; // Where process running on? (Core 0, 1, 2, etc.)
    public uint PaddingNew;     
    
    public ulong PaddingAlign;  
    
    public ulong AppHeapBase;   
    public ulong KernelStackTop;
    public ulong AddrSpace; // [ARCH] handle address-space mờ (x86_64: PML4 phys)          
    public uint UID;            
    public uint GID;            
    public ulong SharedMemPhys; 
    public ulong SharedMemVirt; 
    public fixed byte Name[16];
    
    public ulong CpuTicks; // CPU Usage - for top.exe usage only
    public uint PhysPages;      
    public uint VirtPages;      
    public ulong WakeUpTick;    
    public ulong VRuntime; // Virtual Runtime
    public byte Priority;
    public uint TextColor; // [FIX MÀU CHỮ] Màu chữ hiện tại của RIÊNG tiến trình này -
                            // trước đây dùng 1 biến global chung (Terminal.fgColor), khiến
                            // các luồng/core chạy song song ghi đè màu của nhau vô tội vạ.
    public fixed byte Padding3[11];
    public fixed byte FpuState[512];
}

// [PASCAL PORT] The scheduler lives in scheduler.pas. This class only forwards,
// and the Thread record above stays here because C# callers still index the
// table by field (scheduler.pas declares the identical layout privately).
public static unsafe class Scheduler
{
    [DllImport("*", EntryPoint = "Sched_GetThreads_Pas")] private static extern Thread* GetThreads_Pas();
    [DllImport("*", EntryPoint = "Sched_GetThreadCount_Pas")] private static extern int GetThreadCount_Pas();
    [DllImport("*", EntryPoint = "Sched_IsReady_Pas")] private static extern byte IsReady_Pas();
    [DllImport("*", EntryPoint = "Sched_SetReady_Pas")] private static extern void SetReady_Pas(byte v);
    [DllImport("*", EntryPoint = "Sched_GetForegroundTask_Pas")] private static extern int GetForegroundTask_Pas();
    [DllImport("*", EntryPoint = "Sched_SetForegroundTask_Pas")] private static extern void SetForegroundTask_Pas(int v);
    [DllImport("*", EntryPoint = "Sched_GetCurrentThreadIds_Pas")] private static extern int* GetCurrentThreadIds_Pas();
    [DllImport("*", EntryPoint = "Sched_GetIdleThreadIds_Pas")] private static extern int* GetIdleThreadIds_Pas();
    [DllImport("*", EntryPoint = "Sched_GetDyingThreadPerCore_Pas")] private static extern int* GetDyingThreadPerCore_Pas();
    [DllImport("*", EntryPoint = "Sched_GetSystemTicks_Pas")] private static extern ulong GetSystemTicks_Pas();
    [DllImport("*", EntryPoint = "Sched_SetSystemTicks_Pas")] private static extern void SetSystemTicks_Pas(ulong v);
    [DllImport("*", EntryPoint = "Sched_BumpSystemTicks_Pas")] private static extern ulong BumpSystemTicks_Pas(ulong delta);
    [DllImport("*", EntryPoint = "Sched_GetCurrentThreadId_Pas")] private static extern int GetCurrentThreadId_Pas();
    [DllImport("*", EntryPoint = "Sched_Init_Pas")] private static extern void Init_Pas();
    [DllImport("*", EntryPoint = "Sched_SetIdleLoop_Pas")] private static extern void SetIdleLoop_Pas(void* idleLoop);
    [DllImport("*", EntryPoint = "Sched_SetIpcQueue_Pas")] private static extern void SetIpcQueue_Pas(void* queue, int maxMessages);
    [DllImport("*", EntryPoint = "Sched_CreateIdleTaskForCore_Pas")] private static extern void CreateIdleTaskForCore_Pas(uint coreId);
    [DllImport("*", EntryPoint = "Sched_SwitchTask_Pas")] private static extern ulong SwitchTask_Pas(ulong currentRsp);
    [DllImport("*", EntryPoint = "Sched_GetFreeThreadSlot_Pas")] private static extern int GetFreeThreadSlot_Pas();
    [DllImport("*", EntryPoint = "Sched_CreateTask_Pas")] private static extern void CreateTask_Pas(ulong entryPoint);
    [DllImport("*", EntryPoint = "Sched_CreateUserTask_Pas")] private static extern int CreateUserTask_Pas(ulong entryPoint, ulong appPml4, byte isForeground, byte isJailed, byte forceRoot, char* processName, uint imagePages, byte priority);
    [DllImport("*", EntryPoint = "Sched_TerminateTask_Pas")] private static extern void TerminateTask_Pas(int id);
    [DllImport("*", EntryPoint = "Sched_AcquireSchedLockSafe_Pas")] private static extern byte AcquireSchedLockSafe_Pas();
    [DllImport("*", EntryPoint = "Sched_ReleaseSchedLockSafe_Pas")] private static extern void ReleaseSchedLockSafe_Pas(byte irq);

    public static ushort GetCS() => Arch.GetCs();
    public static ushort GetSS() => Arch.GetSs();
    public static void Yield() => Arch.ForceYield();
    public static void SaveFPU(void* buffer) => Arch.SaveFpu(buffer);
    public static void RestoreFPU(void* buffer) => Arch.RestoreFpu(buffer);
    public static ulong GetRflags() => Arch.GetFlags();

    public static void LockScheduler() => Arch.LockScheduler();
    public static void UnlockScheduler() => Arch.UnlockScheduler();

    public static bool AcquireSchedLockSafe() => AcquireSchedLockSafe_Pas() != 0;
    public static void ReleaseSchedLockSafe(bool irq) => ReleaseSchedLockSafe_Pas((byte)(irq ? 1 : 0));

    public static Thread* Threads => GetThreads_Pas();
    public static int ThreadCount => GetThreadCount_Pas();
    public static bool Ready { get => IsReady_Pas() != 0; set => SetReady_Pas((byte)(value ? 1 : 0)); }
    public static int ForegroundTask { get => GetForegroundTask_Pas(); set => SetForegroundTask_Pas(value); }
    public static int* CurrentThreadIds => GetCurrentThreadIds_Pas();
    public static int* IdleThreadIds => GetIdleThreadIds_Pas();
    public static int* DyingThreadPerCore => GetDyingThreadPerCore_Pas();
    public static ulong SystemTicks { get => GetSystemTicks_Pas(); set => SetSystemTicks_Pas(value); }
    public static ulong BumpSystemTicks(ulong delta) => BumpSystemTicks_Pas(delta);
    public static int CurrentThreadId => GetCurrentThreadId_Pas();

    public static void SetIpcQueue(void* queue, int maxMessages) => SetIpcQueue_Pas(queue, maxMessages);

    public static void Init()
    {
        SetIdleLoop_Pas((void*)(delegate*<void>)&Program.KernelIdleLoop);
        Init_Pas();
    }

    public static void CreateIdleTaskForCore(uint coreId) => CreateIdleTaskForCore_Pas(coreId);

    public static ulong SwitchTask(ulong currentRsp) => SwitchTask_Pas(currentRsp);
    public static int GetFreeThreadSlot() => GetFreeThreadSlot_Pas();
    public static void CreateTask(delegate* <void> entryPoint) => CreateTask_Pas((ulong)entryPoint);

    public static void CreateUserTask(delegate*<void> entryPoint, ulong appPml4, bool isForeground = true, bool isJailed = false, bool forceRoot = false, char* processName = null, uint imagePages = 0, byte priority = 1)
    {
        CreateUserTask_Pas((ulong)entryPoint, appPml4, (byte)(isForeground ? 1 : 0), (byte)(isJailed ? 1 : 0), (byte)(forceRoot ? 1 : 0), processName, imagePages, priority);
    }

    // Overload returning the new thread id, so Kernel.cs can record the real
    // identity of the daemons it spawns itself (not spoofable via Thread.Name).
    public static void CreateUserTask(delegate*<void> entryPoint, ulong appPml4, out int newThreadId, bool isForeground = true, bool isJailed = false, bool forceRoot = false, char* processName = null, uint imagePages = 0, byte priority = 1)
    {
        newThreadId = CreateUserTask_Pas((ulong)entryPoint, appPml4, (byte)(isForeground ? 1 : 0), (byte)(isJailed ? 1 : 0), (byte)(forceRoot ? 1 : 0), processName, imagePages, priority);
    }

    public static void TerminateTask(int id) => TerminateTask_Pas(id);
    public static void TerminateCurrentTask() { TerminateTask(CurrentThreadId); }
}
