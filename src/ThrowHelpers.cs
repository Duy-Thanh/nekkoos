namespace Internal.Runtime.CompilerHelpers
{
    /// <summary>
    /// Throw helpers for zero-stdlib compilation with bflat
    /// </summary>
    public static unsafe class ThrowHelpers
    {
        public static void ThrowOverflowException()
        {
            // In a kernel/bare-metal environment, halt CPU
            CauseHalt();
        }

        public static void ThrowIndexOutOfRangeException()
        {
            CauseHalt();
        }

        public static void ThrowArgumentException()
        {
            CauseHalt();
        }

        public static void ThrowArgumentNullException()
        {
            CauseHalt();
        }

        public static void ThrowDivideByZeroException()
        {
            CauseHalt();
        }

        private static void CauseHalt()
        {
            // Dereference null to cause a fault
            byte* bad = (byte*)0;
            *bad = 0;
            
            // If that somehow doesn't halt, spin forever
            while (true) { }
        }
    }
}
