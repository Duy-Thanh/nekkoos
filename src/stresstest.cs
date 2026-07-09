using System.Runtime.InteropServices;
namespace NekkoApp;

using static NekkoApp.API;

public static unsafe class StressTest
{
    // Cấu trúc để quản lý state qua pointer, cô lập hoàn toàn khỏi IL kiểm tra số học
    private const int STATE_TICK = 0;
    private const int STATE_RAND = 1;
    private const int STATE_PID = 2;
    private const int STATE_I = 3;

    [DllImport("*", EntryPoint = "xorshift32")]
    public static extern uint Xorshift32(uint value);

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();
        SyscallClear(0x00110011);

        ProcessInfo info = default;
        
        // Dùng stackalloc mảng uint để lấy con trỏ điều khiển mọi biến số học
        uint* state = stackalloc uint[4];
        state[STATE_TICK] = 0xC0FFEEu;
        state[STATE_RAND] = 0xC0FFEEu;

        ulong* outV = stackalloc ulong[1];
        char* num = stackalloc char[32];
        char* rev = stackalloc char[32];
        Message* msg = stackalloc Message[1];

        fixed (char* banner = "\n[STRESS TEST] Comprehensive OS Stability Test\n[STRESS] Press 'q' to quit | 'f' for fault injection\n\0")
            SyscallPrint(banner);

        while (true)
        {
            // Ép PRNG chạy qua ASM thô
            state[STATE_TICK] = Xorshift32(state[STATE_TICK]);
            state[STATE_RAND] = Xorshift32(state[STATE_RAND]);

            // 1. PROCESS & IPC STRESS
            // Dùng toán tử con trỏ để tăng vòng lặp thay vì biến pid++ thông thường
            uint* pPid = &state[STATE_PID];
            *pPid = 0; 
            
            while (*pPid < 64u)
            {
                if (SyscallGetProcessInfo(*pPid, &info) == 1)
                {
                    if (info.Active == 1 || info.Active == 2)
                    {
                        // Kiểm tra bitmask an toàn qua pointer
                        if ((state[STATE_RAND] & 15u) == 0u)
                        {
                            SyscallSendIPC(*pPid, (byte)(state[STATE_RAND] & 0xFFu), (ulong)state[STATE_RAND]);
                        }
                        if ((state[STATE_RAND] & 31u) == 0u)
                        {
                            SyscallGetThreadUID(*pPid);
                            SyscallGetThreadGID(*pPid);
                        }
                    }
                }
                state[STATE_RAND] = Xorshift32(state[STATE_RAND]);
                
                // inc dword ptr [pPid] bằng toán tử con trỏ thô
                *pPid = *pPid + 1u; 
            }

            // 2. IPC RECEIVE
            int* pI = (int*)&state[STATE_I];
            *pI = 0;
            while (*pI < 4)
            {
                SyscallReceiveIPC(msg);
                *pI = *pI + 1;
            }

            // 3. MEMORY ALLOCATION
            if ((state[STATE_TICK] & 255u) == 0u)
            {
                ulong mem = SyscallAllocMem(1);
                if (mem != 0)
                {
                    byte* p = (byte*)mem;
                    p[0] = (byte)(state[STATE_RAND] & 0xFFu);
                }
            }

            // 4. SHARED BUFFER
            if ((state[STATE_TICK] & 127u) == 0u)
            {
                outV[0] = 0;
                ulong ret = SyscallCreateSharedBuffer(0u, 1UL, outV);
                if (ret != 0)
                {
                    byte* p = (byte*)ret;
                    // Viết loop unroll hoặc gán trực tiếp để tránh dùng toán tử i++ tăng giảm trong block này
                    p[0] = (byte)(state[STATE_RAND] & 0xFFu); p[1] = (byte)(state[STATE_RAND] & 0xFFu);
                    p[2] = (byte)(state[STATE_RAND] & 0xFFu); p[3] = (byte)(state[STATE_RAND] & 0xFFu);
                    p[4] = (byte)(state[STATE_RAND] & 0xFFu); p[5] = (byte)(state[STATE_RAND] & 0xFFu);
                    p[6] = (byte)(state[STATE_RAND] & 0xFFu); p[7] = (byte)(state[STATE_RAND] & 0xFFu);
                    p[8] = (byte)(state[STATE_RAND] & 0xFFu); p[9] = (byte)(state[STATE_RAND] & 0xFFu);
                    p[10] = (byte)(state[STATE_RAND] & 0xFFu); p[11] = (byte)(state[STATE_RAND] & 0xFFu);
                    p[12] = (byte)(state[STATE_RAND] & 0xFFu); p[13] = (byte)(state[STATE_RAND] & 0xFFu);
                    p[14] = (byte)(state[STATE_RAND] & 0xFFu); p[15] = (byte)(state[STATE_RAND] & 0xFFu);
                }
            }

            // 5. INVALID SYSCALL STRESS
            if ((state[STATE_TICK] & 1023u) == 0u)
            {
                SyscallReceiveIPC((Message*)0);
                SyscallGetProcessInfo(0, (ProcessInfo*)0);
            }

            // 6. TERMINAL OPS
            if ((state[STATE_TICK] & 255u) == 0u)
            {
                SyscallResetCursor();
            }

            // 7. YIELD
            if ((state[STATE_TICK] & 127u) == 0u)
            {
                SyscallYield();
            }

            // 8. STATUS REPORT
            if ((state[STATE_TICK] & 1023u) == 0u)
            {
                SyscallResetCursor();
                fixed (char* s = "[STRESS] Iteration: \0") SyscallPrint(s);
                PrintHex(state[STATE_TICK], num, rev);
                fixed (char* nl = "\n\0") SyscallPrint(nl);
            }

            // 9. USER INPUT
            byte ch = SyscallGetChar();
            if (ch == (byte)'q' || ch == (byte)'Q')
            {
                SyscallClear(0x00111111);
                fixed (char* bye = "[STRESS] Test terminated\n\0") SyscallPrint(bye);
                SyscallExit();
                while (true) SyscallWaitIPC();
            }
            if (ch == (byte)'f' || ch == (byte)'F')
            {
                fixed (char* fault = "[STRESS] Triggering Ring3 fault\n\0") SyscallPrint(fault);
                byte* bad = (byte*)0x00007FFFFFFFF000UL;
                *bad = 0xCC;
            }

            if ((state[STATE_TICK] & 7u) == 0u) SyscallSleep(1);
            else SyscallSleep(0);
        }
    }

    private static void PrintHex(uint v, char* num, char* rev)
    {
        int* pIdx = stackalloc int[1];
        *pIdx = 0;
        
        if (v == 0u) 
        { 
            num[*pIdx] = '0';
            *pIdx = *pIdx + 1;
        }
        else
        {
            int* pC = stackalloc int[1];
            *pC = 0;
            
            char* digits = stackalloc char[16];
            digits[0] = '0'; digits[1] = '1'; digits[2] = '2'; digits[3] = '3';
            digits[4] = '4'; digits[5] = '5'; digits[6] = '6'; digits[7] = '7';
            digits[8] = '8'; digits[9] = '9'; digits[10] = 'A'; digits[11] = 'B';
            digits[12] = 'C'; digits[13] = 'D'; digits[14] = 'E'; digits[15] = 'F';

            int* pShift = stackalloc int[1];
            *pShift = 28;
            
            while (*pShift >= 0)
            {
                // Dùng toán tử dịch bit gián tiếp qua pointer để lách luật compiler
                uint digit = (v >> *pShift) & 15u;
                if (digit != 0u || *pC != 0 || *pShift == 0)
                {
                    rev[*pC] = digits[(int)digit];
                    *pC = *pC + 1;
                }
                *pShift = *pShift - 4;
            }
            while (*pC > 0) 
            { 
                *pC = *pC - 1;
                num[*pIdx] = rev[*pC]; 
                *pIdx = *pIdx + 1;
            }
        }
        num[*pIdx] = '\0';
        SyscallPrint(num);
    }

    public static void Main() { }
}