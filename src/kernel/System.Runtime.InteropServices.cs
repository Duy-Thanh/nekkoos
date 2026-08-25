// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

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