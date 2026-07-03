namespace NekkoOS.Kernel;

// ==========================================================
// MODULE: BỘ ĐỌC THỜI GIAN THỰC (RTC / CMOS)
// CHUẨN THIẾT QUÂN LUẬT: KHÔNG ĐOÁN MÒ ĐỊNH DẠNG!
// ==========================================================
public static unsafe class RTC
{
    private static byte GetRTCRegister(int reg)
    {
        // Gửi địa chỉ (Bật bit 7 = 0x80 để khóa ngắt NMI, tránh nhiễu)
        IO.Out8(0x70, (byte)(reg | 0x80)); 
        return IO.In8(0x71);
    }

    private static ulong BCDToBinary(byte bcd)
    {
        return (ulong)((bcd & 0x0F) + ((bcd / 16) * 10));
    }

    public static void PrintCurrentTime()
    {
        // 1. Chờ RTC cập nhật xong (Bit 7 của Register 0x0A rớt về 0)
        while ((GetRTCRegister(0x0A) & 0x80) != 0) { }

        // 2. Đọc giá trị thô từ phần cứng
        byte secTho = GetRTCRegister(0x00);
        byte minTho = GetRTCRegister(0x02);
        byte hourTho = GetRTCRegister(0x04);
        byte dayTho = GetRTCRegister(0x07);
        byte monthTho = GetRTCRegister(0x08);
        byte yearTho = GetRTCRegister(0x09);

        // 3. [THIẾT QUÂN LUẬT] CHECK THANH GHI B ĐỂ BIẾT ĐỊNH DẠNG THỰC SỰ!
        byte registerB = GetRTCRegister(0x0B);
        bool isBinary = (registerB & 0x04) != 0; // Bit 2: 1 = Binary, 0 = BCD
        bool is24Hour = (registerB & 0x02) != 0; // Bit 1: 1 = 24h, 0 = 12h

        ulong sec, min, hour, day, month, year;

        // 4. Dịch mã một cách chắc chắn 100%
        if (isBinary)
        {
            sec = secTho; min = minTho; hour = hourTho;
            day = dayTho; month = monthTho; year = yearTho;
        }
        else
        {
            sec = BCDToBinary(secTho);
            min = BCDToBinary(minTho);
            // Xử lý cờ PM của định dạng 12h BCD (Bit 7)
            hour = BCDToBinary((byte)(hourTho & 0x7F)); 
            day = BCDToBinary(dayTho);
            month = BCDToBinary(monthTho);
            year = BCDToBinary(yearTho);
        }

        // Chuyển 12h sang 24h nếu hệ thống xài 12h
        if (!is24Hour && (hourTho & 0x80) != 0)
        {
            hour = (hour + 12) % 24;
        }

        year += 2000; 
        
        // GMT+7 (Hà Nội, Việt Nam)
        hour = (hour + 7) % 24; 

        Terminal.SetColor(0x00FFFF00); 
        fixed (char* msg = "[*] Hardware CMOS Time: \0") Terminal.Print(msg);
        
        if (day < 10) fixed (char* z = "0\0") Terminal.Print(z);
        Terminal.PrintDec(day); fixed (char* sep1 = "/\0") Terminal.Print(sep1);
        
        if (month < 10) fixed (char* z = "0\0") Terminal.Print(z);
        Terminal.PrintDec(month); fixed (char* sep2 = "/\0") Terminal.Print(sep2);
        
        Terminal.PrintDec(year); fixed (char* sep3 = "  \0") Terminal.Print(sep3);

        if (hour < 10) fixed (char* z = "0\0") Terminal.Print(z);
        Terminal.PrintDec(hour); fixed (char* sep4 = ":\0") Terminal.Print(sep4);

        if (min < 10) fixed (char* z = "0\0") Terminal.Print(z);
        Terminal.PrintDec(min); fixed (char* sep5 = ":\0") Terminal.Print(sep5);

        if (sec < 10) fixed (char* z = "0\0") Terminal.Print(z);
        Terminal.PrintDec(sec); fixed (char* nl = "\n\0") Terminal.Print(nl);
        
        Terminal.SetColor(0x00FFFFFF); 
    }

    // ==========================================================
    // [VŨ KHÍ MỚI TRONG RTC.CS] LẤY SỐ GIÂY THỰC TẾ TỪ HARDWARE
    // Bỏ qua mọi sự ảo ma của PIT QEMU!
    // ==========================================================
    public static ulong GetSeconds()
    {
        // Chờ RTC cập nhật xong
        while ((GetRTCRegister(0x0A) & 0x80) != 0) { }

        byte secTho = GetRTCRegister(0x00);
        byte registerB = GetRTCRegister(0x0B);
        bool isBinary = (registerB & 0x04) != 0;

        if (isBinary) return secTho;
        return BCDToBinary(secTho);
    }
}