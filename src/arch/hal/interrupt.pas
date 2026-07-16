unit hal.interrupt;

{ Hardware Abstraction Layer: Interrupt Controller Interface

  This unit defines the architecture-agnostic interrupt controller API that
  NekkoOS kernel code uses. Each architecture provides its own implementation:

  - x86_64: APIC + IOAPIC
  - ARM64: GIC (Generic Interrupt Controller)
  - RISC-V: PLIC (Platform-Level Interrupt Controller) + CLINT (Core-Local Interruptor)

  The kernel NEVER directly calls APIC/IOAPIC/GIC/PLIC-specific code.
  All interrupt operations go through this HAL interface. }

{$MODE FPC}
{$ASMMODE Intel}

interface

const
  { Generic IRQ numbers (architecture-agnostic mapping) }
  IRQ_TIMER       = 0;   { System timer interrupt }
  IRQ_KEYBOARD    = 1;   { Keyboard input }
  IRQ_CASCADE     = 2;   { Cascade (x86 legacy, unused on modern platforms) }
  IRQ_SERIAL2     = 3;   { Serial port 2 }
  IRQ_SERIAL1     = 4;   { Serial port 1 }
  IRQ_PARALLEL2   = 5;   { Parallel port 2 }
  IRQ_FLOPPY      = 6;   { Floppy disk (legacy) }
  IRQ_PARALLEL1   = 7;   { Parallel port 1 }
  IRQ_RTC         = 8;   { Real-Time Clock }
  IRQ_ACPI        = 9;   { ACPI }
  IRQ_AVAILABLE1  = 10;  { Available }
  IRQ_AVAILABLE2  = 11;  { Available }
  IRQ_MOUSE       = 12;  { PS/2 Mouse }
  IRQ_FPU         = 13;  { FPU / Coprocessor }
  IRQ_ATA_PRIMARY = 14;  { Primary ATA }
  IRQ_ATA_SECONDARY = 15; { Secondary ATA }

type
  { Interrupt handler callback type }
  TInterruptHandler = procedure; cdecl;

{ ============================================================================
  Interrupt Controller Initialization
  ============================================================================ }

{ Initialize the platform's interrupt controller(s).
  Must be called early in boot, before any interrupts are enabled.

  x86_64: Initializes APIC + IOAPIC, disables legacy PIC
  ARM64: Initializes GIC distributor and CPU interface
  RISC-V: Initializes PLIC contexts and enables machine interrupts }
procedure HAL_InitInterruptController;

{ Get the number of available interrupt lines supported by this platform.
  Used for dynamic IRQ allocation.

  x86_64: Returns IOAPIC redirection entry count (typically 24)
  ARM64: Returns GIC SPI (Shared Peripheral Interrupt) count
  RISC-V: Returns PLIC source count }
function HAL_GetInterruptCount: Cardinal;

{ ============================================================================
  Interrupt Routing & Masking
  ============================================================================ }

{ Route a hardware interrupt (IRQ) to a specific CPU core.

  Parameters:
    irq: Generic IRQ number (see IRQ_* constants)
    coreId: Target CPU core ID (0-based)
    vector: Interrupt vector number to deliver (architecture-specific range)

  x86_64: Programs IOAPIC redirection entry with APIC ID
  ARM64: Sets GIC ITARGETSR (Interrupt Target Register)
  RISC-V: PLIC context configuration }
procedure HAL_RouteInterrupt(irq: Cardinal; coreId: Cardinal; vector: Byte);

{ Mask (disable) a specific IRQ line.
  The interrupt will not fire until unmasked.

  x86_64: Sets IOAPIC redirection entry mask bit
  ARM64: Clears GIC ISENABLER (Interrupt Set-Enable Register)
  RISC-V: Clears PLIC enable bit for context }
procedure HAL_MaskInterrupt(irq: Cardinal);

{ Unmask (enable) a specific IRQ line.

  x86_64: Clears IOAPIC redirection entry mask bit
  ARM64: Sets GIC ISENABLER
  RISC-V: Sets PLIC enable bit for context }
procedure HAL_UnmaskInterrupt(irq: Cardinal);

{ ============================================================================
  End-of-Interrupt (EOI) Signaling
  ============================================================================ }

{ Signal End-of-Interrupt to the interrupt controller.
  MUST be called at the end of every interrupt handler to acknowledge
  receipt and allow further interrupts.

  Parameters:
    vector: The interrupt vector number that just completed

  x86_64: Writes to Local APIC EOI register
  ARM64: Writes to GIC EOIR (End Of Interrupt Register)
  RISC-V: Writes completion to PLIC claim/complete register }
procedure HAL_SendEOI(vector: Byte);

{ ============================================================================
  Inter-Processor Interrupts (IPI)
  ============================================================================ }

{ Send an Inter-Processor Interrupt to another CPU core.
  Used for SMP synchronization, TLB shootdown, scheduler wakeup, etc.

  Parameters:
    targetCore: Target CPU core ID (0-based)
    vector: Interrupt vector to deliver

  x86_64: Writes to Local APIC ICR (Interrupt Command Register)
  ARM64: Writes to GIC GICD_SGIR (Software Generated Interrupt Register)
  RISC-V: Triggers CLINT software interrupt (MSIP) }
procedure HAL_SendIPI(targetCore: Cardinal; vector: Byte);

{ Send an Inter-Processor Interrupt to ALL other CPU cores (broadcast).

  x86_64: ICR with destination shorthand = all excluding self
  ARM64: GICD_SGIR with target list filter
  RISC-V: Loop over all cores' MSIP bits }
procedure HAL_BroadcastIPI(vector: Byte);

{ ============================================================================
  Priority & Trigger Mode Configuration
  ============================================================================ }

{ Set the priority level for an IRQ line (if supported by platform).
  Lower number = higher priority (typically 0-15 range).

  x86_64: Not used (APIC uses fixed priority)
  ARM64: Sets GIC IPRIORITYR
  RISC-V: Sets PLIC priority register }
procedure HAL_SetInterruptPriority(irq: Cardinal; priority: Byte);

{ Configure interrupt trigger mode (edge vs level).

  Parameters:
    irq: IRQ line number
    isEdgeTriggered: true = edge-triggered, false = level-triggered

  x86_64: Sets IOAPIC redirection entry trigger mode bit
  ARM64: Sets GIC ICFGR (Interrupt Configuration Register)
  RISC-V: Platform-dependent (some PLICs don't support configuration) }
procedure HAL_SetTriggerMode(irq: Cardinal; isEdgeTriggered: Boolean);

{ ============================================================================
  Multi-Core Timer Configuration
  ============================================================================ }

{ Calibrate and start the per-core timer interrupt.
  Each CPU core gets its own local timer that fires at a fixed frequency.

  Parameters:
    frequencyHz: Desired interrupt frequency (e.g., 250 for 250Hz tick rate)

  x86_64: Programs Local APIC timer (TSC-deadline or periodic mode)
  ARM64: Programs Generic Timer (CNTV_CVAL_EL0)
  RISC-V: Programs mtime comparator (mtimecmp CSR) }
procedure HAL_StartLocalTimer(frequencyHz: Cardinal);

{ Stop the per-core timer interrupt on the current CPU.

  x86_64: Masks Local APIC timer vector
  ARM64: Disables Generic Timer (CNTV_CTL_EL0)
  RISC-V: Sets mtimecmp to max value }
procedure HAL_StopLocalTimer;

{ ============================================================================
  Debug & Diagnostics
  ============================================================================ }

{ Get the ID of the current CPU core executing this code.
  Used for per-core data structures and SMP synchronization.

  x86_64: Reads Local APIC ID
  ARM64: Reads MPIDR_EL1
  RISC-V: Reads mhartid CSR }
function HAL_GetCoreId: Cardinal;

{ Dump interrupt controller state for debugging.
  Prints routing table, mask status, pending interrupts, etc. to serial/log. }
procedure HAL_DumpInterruptState;

implementation

{ All functions are implemented by the architecture-specific backend:
  - x86_64: src/arch/x86_64/apic_impl.pas + ioapic_impl.pas
  - ARM64: src/arch/arm64/gic_impl.pas
  - RISC-V: src/arch/riscv64/plic_impl.pas + clint_impl.pas

  At link time, the appropriate implementation is selected based on
  the target architecture. No wrapper overhead — direct function calls. }

end.
