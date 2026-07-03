using System.Runtime.InteropServices;
namespace NekkoApp;

using static NekkoApp.API;

public static unsafe class StressTest
{
    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();

        SyscallClear(0x00110011);

        ProcessInfo info = default;
        ulong counter = 0;
        uint rand = 0xC0FFEE;

        // [VÁ TỬ HUYỆT APP STACK] Khai báo cố định một lần duy nhất!
        ulong* outV = stackalloc ulong[1]; 
        char* num = stackalloc char[32];

        while (true)
        {
            counter++;

            // scan processes and spam light IPC to active ones
            for (uint pid = 0; pid < 32; pid++)
            {
                if (SyscallGetProcessInfo(pid, &info) == 1 && (info.Active == 1 || info.Active == 2))
                {
                    if ((rand & 7) == 0)
                    {
                        SyscallSendIPC(pid, (uint)(rand & 0xFF), (ulong)rand);
                    }
                }
                // simple LCG
                rand = (uint)(((ulong)rand * 1103515245 + 12345) & 0x7FFFFFFF);
            }

            // occasionally create a small shared buffer and scribble into it
            if ((counter & 0x3F) == 0)
            {
                outV[0] = 0; // Tái sử dụng mảng tĩnh trên Stack
                ulong ret = SyscallCreateSharedBuffer(0u, 1UL, outV);
                if (ret != 0)
                {
                    byte* p = (byte*)ret;
                    for (int i = 0; i < 16; i++) p[i] = (byte)(rand & 0xFF);
                }
            }

            // heartbeat print
            if ((counter & 0x3FF) == 0)
            {
                fixed (char* s = "[STRESS] heartbeat: \0") SyscallPrint(s);
                ulong v = counter; int idx = 0;
                if (v == 0) num[idx++] = '0'; 
                else { 
                    char* rev = stackalloc char[32]; // Hàm ngắn gọn trong scope con tạm chấp nhận, hoặc dùng mảng phụ ngoài
                    int c = 0; 
                    while (v > 0) { rev[c++] = (char)('0' + (v % 10)); v /= 10; } 
                    while (c > 0) num[idx++] = rev[--c]; 
                }
                num[idx] = '\0';
                SyscallPrint(num);
                fixed (char* nl = "\n\0") SyscallPrint(nl);
            }

            byte ch = SyscallGetChar();
            if (ch == (byte)'q' || ch == (byte)'Q') { SyscallExit(); while (true) SyscallWaitIPC(); }

            SyscallSleep(5);
        }
    }

    public static void Main() { }
}
