// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

namespace NekkoOS.Kernel.Driver;
public static class Mouse {
    public static bool UseDaemon = false;
    public static uint DaemonId = 0;
}