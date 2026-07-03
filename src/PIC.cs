namespace NekkoOS.Kernel;

public static unsafe class PIC
{
    public static void Remap()
    {
        IO.Out8(0x20, 0x11); IO.Wait(); IO.Out8(0xA0, 0x11); IO.Wait();
        IO.Out8(0x21, 0x20); IO.Wait(); IO.Out8(0xA1, 0x28); IO.Wait();
        IO.Out8(0x21, 0x04); IO.Wait(); IO.Out8(0xA1, 0x02); IO.Wait();
        IO.Out8(0x21, 0x01); IO.Wait(); IO.Out8(0xA1, 0x01); IO.Wait();
        
        // Bật ngắt Bàn phím (Bit 1) và Timer (Bit 0)
        IO.Out8(0x21, 0xFC); IO.Wait(); IO.Out8(0xA1, 0xFF); IO.Wait();
    }
    public static void SendEOI() => IO.Out8(0x20, 0x20);
    
    // ==========================================================
    // BỨC TỬ 8259 PIC - NHƯỜNG NGÔI CHO I/O APIC
    // ==========================================================
    public static void Disable()
    {
        // Ghi 0xFF vào thanh ghi Data của cả 2 chip Master và Slave 
        // để mask (che) TOÀN BỘ ngắt phần cứng Legacy!
        IO.Out8(0xA1, 0xFF);
        IO.Out8(0x21, 0xFF);
        
        Terminal.SetColor(0x00FF00FF);
        fixed (char* m = "[-] Legacy 8259 PIC has been completely silenced & disabled.\n\0") Terminal.Print(m);
    }
}