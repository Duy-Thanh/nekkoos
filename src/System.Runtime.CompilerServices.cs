// Hack cho --stdlib zero
namespace System.Runtime.CompilerServices 
{
    public class IsExternalInit {}
    // ==========================================================
    // [VŨ KHÍ BỌC THÉP] THỎA MÃN TỪ KHÓA VOLATILE CỦA C#!
    // Đéo cần code gì bên trong, chỉ cần cái xác để Compiler nó dán nhãn!
    // ==========================================================
    public static class IsVolatile { }
}