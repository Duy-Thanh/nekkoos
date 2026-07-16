unit hal.platform;

{ Hardware Abstraction Layer: Platform Initialization Interface

  This unit defines the architecture-agnostic platform boot and initialization
  API for NekkoOS. Each architecture provides its own implementation:

  - x86_64: BIOS/UEFI boot, multiboot, GDT/IDT setup, SMP via ACPI MADT
  - ARM64: Device Tree / ACPI, GIC setup, SMP via PSCI
  - RISC-V: Device Tree, SBI (Supervisor Binary Interface), SMP via hart startup

  The kernel's Boot.cs/Kernel.cs NEVER directly calls x86-specific initialization.
  All platform setup goes through this HAL interface. }

{$MODE FPC}
{$ASMMODE Intel}

interface

type
  { Platform type identifier }
  TPlatformType = (
    ptX86_64,     { x86-64 (AMD64 / Intel 64) }
    ptARM64,      { AArch64 (ARM 64-bit) }
    ptRISCV64     { RISC-V 64-bit }
  );

  { CPU core information }
  TCoreInfo = record
    CoreId: Cardinal;        { Logical core ID (0-based, sequential) }
    PhysicalId: Cardinal;    { Physical processor ID (x86: APIC ID, ARM: MPIDR, RISC-V: hartid) }
    IsBootCore: Boolean;     { true if this is the boot processor }
    IsOnline: Boolean;       { true if core is currently running }
  end;

  { Memory region descriptor }
  TMemoryRegion = record
    BaseAddress: QWord;      { Physical start address }
    Length: QWord;           { Size in bytes }
    IsUsable: Boolean;       { true = RAM, false = reserved/MMIO }
    MemType: Cardinal;       { Platform-specific type (e.g., EFI memory type) }
  end;

{ ============================================================================
  Platform Detection & Identification
  ============================================================================ }

{ Get the current platform type.

  Returns: ptX86_64, ptARM64, or ptRISCV64 }
function HAL_GetPlatformType: TPlatformType;

{ Get a human-readable platform name string.

  Returns: e.g., "x86_64 (Intel Coffee Lake)", "ARM64 (Cortex-A76)", "RISC-V64 (SiFive U74)" }
function HAL_GetPlatformName: PChar;

{ Get CPU vendor/implementer string.

  x86_64: Returns CPUID vendor string (e.g., "GenuineIntel", "AuthenticAMD")
  ARM64: Returns MIDR_EL1 implementer (e.g., "ARM Limited", "Apple")
  RISC-V: Returns vendor ID from mvendorid CSR }
function HAL_GetCPUVendor: PChar;

{ Get CPU model/brand string.

  x86_64: Returns brand string from CPUID
  ARM64: Returns part number from MIDR_EL1
  RISC-V: Returns architecture ID from marchid CSR }
function HAL_GetCPUModel: PChar;

{ ============================================================================
  Early Boot Initialization
  ============================================================================ }

{ Perform architecture-specific early initialization.
  Called FIRST during kernel startup, before ANY other subsystems.

  x86_64: Sets up GDT, minimal IDT, enables SSE/AVX, disables legacy PIC
  ARM64: Sets up exception vectors, configures TCR_EL1, disables traps
  RISC-V: Configures stvec, enables extensions (F/D), sets up PMP

  IMPORTANT: This runs with interrupts DISABLED, MMU MAY NOT BE FULLY SET UP.
  Do NOT allocate memory. Do NOT print to console (unless using early serial). }
procedure HAL_EarlyInit;

{ Initialize platform-specific firmware interfaces.
  Called after HAL_EarlyInit, before memory manager init.

  x86_64: Parse ACPI tables (RSDP → XSDT → FADT/MADT/MCFG)
  ARM64: Parse Device Tree or ACPI tables
  RISC-V: Parse Device Tree (FDT)

  After this call, HAL_GetMemoryMap and HAL_GetCoreCount should work. }
procedure HAL_InitFirmware;

{ Get the memory map provided by firmware/bootloader.

  Parameters:
    outRegions: Pointer to array of TMemoryRegion (caller-allocated)
    maxRegions: Size of outRegions array

  Returns: Number of regions written to outRegions

  x86_64: Converts E820/EFI memory map to generic format
  ARM64: Parses Device Tree /memory nodes or EFI memory map
  RISC-V: Parses Device Tree /memory@* nodes }
function HAL_GetMemoryMap(outRegions: Pointer; maxRegions: Cardinal): Cardinal;

{ Get total usable RAM in bytes.

  Returns: Sum of all usable memory regions }
function HAL_GetTotalMemory: QWord;

{ ============================================================================
  Multi-Core / SMP Initialization
  ============================================================================ }

{ Get the number of CPU cores detected by firmware.

  x86_64: Reads ACPI MADT (Multiple APIC Description Table)
  ARM64: Reads ACPI MADT or counts Device Tree /cpus/cpu@* nodes
  RISC-V: Counts Device Tree /cpus/cpu@* nodes

  Returns: Total core count (includes boot core) }
function HAL_GetCoreCount: Cardinal;

{ Get information about a specific CPU core.

  Parameters:
    coreIndex: Logical core index (0-based, sequential)
    outInfo: Pointer to TCoreInfo structure to fill

  Returns: true on success, false if coreIndex invalid }
function HAL_GetCoreInfo(coreIndex: Cardinal; outInfo: Pointer): Boolean;

{ Bring up (start) a secondary CPU core.
  Sends startup signal to a sleeping core and waits for it to boot.

  Parameters:
    coreId: Logical core ID to start (from HAL_GetCoreInfo)
    entryPoint: Physical address of code to execute (must be identity-mapped)
    stackTop: Stack pointer value to load

  Returns: true if core started successfully

  x86_64: Sends INIT + SIPI sequence via Local APIC
  ARM64: Calls PSCI CPU_ON via SMC/HVC
  RISC-V: Writes to SBI HSM extension (HART start)

  The secondary core will execute code at entryPoint with RSP/SP = stackTop.
  The entry point must initialize its own GDT/IDT/MMU before jumping to kernel. }
function HAL_StartCore(coreId: Cardinal; entryPoint: QWord; stackTop: QWord): Boolean;

{ Check if the current CPU is the boot processor.

  x86_64: Reads IA32_APIC_BASE MSR BSP bit
  ARM64: Compares current MPIDR against boot core MPIDR
  RISC-V: Compares mhartid against boot hartid

  Returns: true if this is the boot core }
function HAL_IsBootCore: Boolean;

{ ============================================================================
  Power Management & System Control
  ============================================================================ }

{ Reboot the system (warm reset).

  x86_64: Triple-fault, ACPI reset register, or PS/2 controller reset
  ARM64: PSCI SYSTEM_RESET via SMC
  RISC-V: SBI system reset extension }
procedure HAL_Reboot;

{ Shutdown the system (power off).

  x86_64: ACPI \_S5 sleep state via PM1a/PM1b control registers
  ARM64: PSCI SYSTEM_OFF via SMC
  RISC-V: SBI system shutdown extension }
procedure HAL_Shutdown;

{ Suspend the system (sleep state).

  Parameters:
    sleepState: Platform-specific sleep state (e.g., ACPI S1/S3/S4)

  x86_64: ACPI \_S1 / \_S3 (suspend-to-RAM)
  ARM64: PSCI CPU_SUSPEND
  RISC-V: SBI hart suspend }
procedure HAL_Suspend(sleepState: Cardinal);

{ ============================================================================
  Serial / Early Debug Output
  ============================================================================ }

{ Initialize early serial console for debug output.
  Used for logging BEFORE the terminal subsystem is initialized.

  x86_64: Configures COM1 (0x3F8) UART
  ARM64: Configures PL011 UART (address from Device Tree)
  RISC-V: Configures UART (address from Device Tree) or SBI console

  After this call, HAL_DebugWrite should work. }
procedure HAL_InitEarlySerial;

{ Write a null-terminated string to early serial console.

  Parameters:
    str: Pointer to null-terminated ASCII string

  x86_64: Writes to COM1 port
  ARM64: Writes to PL011 UART
  RISC-V: Calls SBI console putchar or writes to UART }
procedure HAL_DebugWrite(str: PChar);

{ Write a single character to early serial console.

  x86_64: OUT to COM1 port
  ARM64: Writes to PL011 UARTDR
  RISC-V: SBI console putchar }
procedure HAL_DebugWriteChar(c: Char);

{ ============================================================================
  Device Enumeration & Hardware Discovery
  ============================================================================ }

{ Enumerate PCI/PCIe devices (if platform supports PCI).

  Parameters:
    callback: Function called for each device found
    context: User data passed to callback

  x86_64: Walks PCI config space (I/O or MMIO via MCFG)
  ARM64: Walks PCIe ECAM (Enhanced Configuration Access Mechanism) via MCFG
  RISC-V: Walks PCIe ECAM via Device Tree

  Callback signature: procedure(bus, device, function, vendorId, deviceId: Word; context: Pointer); cdecl; }
procedure HAL_EnumeratePCIDevices(callback: Pointer; context: Pointer);

{ Get base address of platform-specific firmware interface.

  x86_64: Returns physical address of ACPI RSDP
  ARM64: Returns physical address of Device Tree blob or ACPI RSDP
  RISC-V: Returns physical address of Device Tree blob

  Returns: Physical address, or 0 if not available }
function HAL_GetFirmwareAddress: QWord;

{ ============================================================================
  Randomness & Entropy
  ============================================================================ }

{ Get hardware random bytes (if CPU supports HWRNG).

  Parameters:
    buffer: Output buffer
    length: Number of bytes to generate

  Returns: Number of bytes actually generated (may be 0 if no HWRNG)

  x86_64: Uses RDRAND/RDSEED instructions (if CPUID reports support)
  ARM64: Uses RNDR/RNDRRS system registers (if ID_AA64ISAR0_EL1 indicates support)
  RISC-V: Uses Zkr extension (seed CSR) if available }
function HAL_GetHardwareRandom(buffer: Pointer; length: Cardinal): Cardinal;

{ ============================================================================
  Performance Monitoring & Profiling
  ============================================================================ }

{ Read CPU cycle counter (high-resolution, monotonic).

  x86_64: RDTSC instruction
  ARM64: PMCCNTR_EL0 (Performance Monitors Cycle Count Register)
  RISC-V: rdcycle pseudo-instruction

  Returns: Current CPU cycle count }
function HAL_ReadCycleCounter: QWord;

{ Get CPU frequency in Hz.

  x86_64: CPUID TSC frequency or calibrated via PIT
  ARM64: CNTFRQ_EL0 or Device Tree cpu-clock-frequency
  RISC-V: Device Tree timebase-frequency

  Returns: CPU frequency (Hz) }
function HAL_GetCPUFrequency: QWord;

{ ============================================================================
  Debug & Diagnostics
  ============================================================================ }

{ Dump platform information for debugging: CPU model, core count, memory, etc. }
procedure HAL_DumpPlatformInfo;

implementation

{ All functions are implemented by the architecture-specific backend:
  - x86_64: src/arch/x86_64/platform_impl.pas
  - ARM64: src/arch/arm64/platform_impl.pas
  - RISC-V: src/arch/riscv64/platform_impl.pas

  At link time, the appropriate implementation is selected based on
  the target architecture. No wrapper overhead — direct function calls. }

end.
