// Hack cho --stdlib zero
namespace System.Runtime.InteropServices
{
    public class DllImportAttribute : Attribute
    {
        public string Value { get; }
        public string EntryPoint;
        public DllImportAttribute(string dllName) { Value = dllName; }
    }
}