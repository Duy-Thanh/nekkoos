using System.Runtime.InteropServices;

namespace NekkoOS.Kernel
{
    public static unsafe class Serial
    {
        [DllImport("*", EntryPoint = "Out8")] static extern void Out8(ushort port, byte value);
        [DllImport("*", EntryPoint = "In8")] static extern byte In8(ushort port);

        const ushort COM1 = 0x3F8;

        public static void Init()
        {
            Out8(COM1 + 1, 0x00);    // Disable all interrupts
            Out8(COM1 + 3, 0x80);    // Enable DLAB (set baud rate divisor)
            Out8(COM1 + 0, 0x03);    // Set divisor to 3 (lo byte) 38400 baud
            Out8(COM1 + 1, 0x00);    //                  (hi byte)
            Out8(COM1 + 3, 0x03);    // 8 bits, no parity, one stop bit
            Out8(COM1 + 2, 0xC7);    // Enable FIFO, clear them, with 14-byte threshold
            Out8(COM1 + 4, 0x0B);    // IRQs enabled, RTS/DSR set
        }

        private static int IsTransmitEmpty() {
            return In8(COM1 + 5) & 0x20;
        }

        // ==========================================================
        // [VŨ KHÍ MỚI] KIỂM TRA CÓ DỮ LIỆU TỚI KHÔNG?
        // ==========================================================
        public static bool SerialReceived() {
            return (In8(COM1 + 5) & 1) != 0;
        }

        // ==========================================================
        // [VŨ KHÍ MỚI] ĐỌC 1 KÝ TỰ TỪ CỔNG COM1 (CHỜ ĐẾN KHI CÓ)
        // ==========================================================
        public static char ReadChar() {
            while (!SerialReceived()) { } // Đóng băng CPU chờ mày gõ phím!
            return (char)In8(COM1);
        }

        // ==========================================================
        // [VŨ KHÍ MỚI] ĐỌC NON-BLOCKING (DÙNG TRONG VÒNG LẶP IDLE)
        // ==========================================================
        public static char ReadCharNonBlocking() {
            if (SerialReceived()) return (char)In8(COM1);
            return '\0';
        }

        public static void WriteChar(char a)
        {
            while (IsTransmitEmpty() == 0) { } 
            Out8(COM1, (byte)a);
        }

        public static void WriteString(char* str)
        {
            int i = 0;
            while (str[i] != '\0')
            {
                if (str[i] == '\n') WriteChar('\r'); // Bọc thép tự động xuống dòng chuẩn
                WriteChar(str[i]);
                i++;
            }
        }

        public static void WriteHex(ulong number)
        {
            fixed (char* prefix = "0x\0") WriteString(prefix);
            if (number == 0) { WriteChar('0'); return; }

            char* hexChars = stackalloc char[16] { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F' };
            char* buffer = stackalloc char[16]; int index = 0; ulong temp = number;
            
            while (temp > 0 && index < 16) {
                buffer[index] = hexChars[temp % 16];
                temp /= 16;
                index++;
            }
            for (int i = index - 1; i >= 0; i--) WriteChar(buffer[i]);
        }
    }
}