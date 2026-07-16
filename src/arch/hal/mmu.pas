unit hal.mmu;

{ Hardware Abstraction Layer: Memory Management Unit Interface

  This unit defines the architecture-agnostic MMU/paging API for NekkoOS.
  Each architecture provides its own implementation:

  - x86_64: 4-level paging (PML4 → PDPT → PD → PT), CR3 register, INVLPG
  - ARM64: 4-level paging (L0 → L1 → L2 → L3), TTBR0/TTBR1, TLBI
  - RISC-V: Sv39/Sv48 paging (3/4 levels), satp CSR, SFENCE.VMA

  The kernel NEVER directly manipulates CR3/TTBR/satp or page table formats.
  All MMU operations go through this HAL interface. }

{$MODE FPC}
{$ASMMODE Intel}

interface

type
  { Page protection flags (architecture-agnostic) }
  TPageFlags = set of (
    pfPresent,      { Page is mapped and accessible }
    pfWritable,     { Page allows writes (otherwise read-only) }
    pfUser,         { Page accessible from user mode (Ring 3) }
    pfWriteThrough, { Write-through caching (not write-back) }
    pfCacheDisable, { Disable caching for this page (MMIO) }
    pfAccessed,     { Page has been read/written (hardware-set) }
    pfDirty,        { Page has been written (hardware-set) }
    pfHugePage,     { 2MB/1GB huge page (if supported) }
    pfGlobal,       { TLB entry persists across CR3/TTBR/satp changes }
    pfNoExecute     { Page disallows instruction fetch (NX/XN) }
  );

  { Page size enumeration }
  TPageSize = (
    ps4KB,     { 4 KB standard page }
    ps2MB,     { 2 MB huge page (x86: PD entry, ARM: L2 block, RISC-V: megapage) }
    ps1GB      { 1 GB huge page (x86: PDPT entry, ARM: L1 block, RISC-V: gigapage) }
  );

  { Page table handle (opaque pointer to root page table) }
  PPageTable = Pointer;

{ ============================================================================
  MMU Initialization
  ============================================================================ }

{ Initialize the MMU subsystem.
  Must be called early in boot, before paging is fully enabled.

  x86_64: Enables NX bit via EFER.NXE, sets up identity mapping
  ARM64: Configures TCR_EL1 (page table control), MAIR_EL1 (memory attributes)
  RISC-V: Enables SV39/SV48 mode via satp }
procedure HAL_InitMMU;

{ Get the physical address mask for this platform.
  Used to extract physical addresses from page table entries.

  x86_64: Returns 0x000F_FFFF_FFFF_F000 (52-bit physical address space)
  ARM64: Returns mask based on ID_AA64MMFR0_EL1.PARange
  RISC-V: Returns 0x003F_FFFF_FFFF_F000 (Sv39: 56-bit physical, Sv48: 56-bit) }
function HAL_GetPhysicalAddressMask: QWord;

{ Get the maximum supported page size for this platform.

  x86_64: Returns ps1GB (if CPU supports 1GB pages via CPUID)
  ARM64: Returns ps1GB (if TCR allows L1 blocks)
  RISC-V: Returns ps1GB (if mode is Sv48) or ps2MB (Sv39) }
function HAL_GetMaxPageSize: TPageSize;

{ ============================================================================
  Page Table Management
  ============================================================================ }

{ Create a new page table (root).
  Allocates and initializes a top-level page table structure.

  Returns: Handle to new page table (can be passed to HAL_LoadPageTable)

  x86_64: Allocates PML4, clears to zero
  ARM64: Allocates L0 table, clears to zero
  RISC-V: Allocates root page table, clears to zero }
function HAL_CreatePageTable: PPageTable;

{ Destroy a page table and free all associated memory.
  Recursively walks and frees all page table levels.

  WARNING: Do NOT destroy the currently active page table! }
procedure HAL_DestroyPageTable(pageTable: PPageTable);

{ Clone a page table (deep copy).
  Creates a new page table with identical mappings.
  Used for process fork().

  Parameters:
    source: Page table to clone

  Returns: New page table with same mappings }
function HAL_ClonePageTable(source: PPageTable): PPageTable;

{ Load (activate) a page table on the current CPU core.
  Switches to the new address space.

  Parameters:
    pageTable: Page table to activate (handle from HAL_CreatePageTable)

  x86_64: Writes pageTable physical address to CR3
  ARM64: Writes to TTBR0_EL1 or TTBR1_EL1
  RISC-V: Writes to satp CSR with mode bits }
procedure HAL_LoadPageTable(pageTable: PPageTable);

{ Get the currently active page table on this CPU core.

  Returns: Handle to current page table

  x86_64: Reads CR3
  ARM64: Reads TTBR0_EL1
  RISC-V: Reads satp }
function HAL_GetCurrentPageTable: PPageTable;

{ ============================================================================
  Page Mapping
  ============================================================================ }

{ Map a virtual address to a physical address in a page table.

  Parameters:
    pageTable: Target page table (nil = current page table)
    virtualAddr: Virtual address to map (will be page-aligned)
    physicalAddr: Physical address to map to (will be page-aligned)
    flags: Page protection flags
    pageSize: Page size (ps4KB, ps2MB, ps1GB)

  Returns: true on success, false if mapping failed

  x86_64: Creates PML4 → PDPT → PD → PT entries as needed
  ARM64: Creates L0 → L1 → L2 → L3 entries as needed
  RISC-V: Creates page table hierarchy as needed

  NOTE: This function allocates intermediate page tables if needed.
  It does NOT flush TLB — caller must call HAL_FlushTLB afterward. }
function HAL_MapPage(pageTable: PPageTable; virtualAddr, physicalAddr: QWord; flags: TPageFlags; pageSize: TPageSize): Boolean;

{ Unmap a virtual address from a page table.

  Parameters:
    pageTable: Target page table (nil = current page table)
    virtualAddr: Virtual address to unmap

  Returns: true if page was mapped and is now unmapped, false if not mapped

  NOTE: This does NOT free intermediate page tables (even if empty).
  It does NOT flush TLB — caller must call HAL_FlushTLB afterward. }
function HAL_UnmapPage(pageTable: PPageTable; virtualAddr: QWord): Boolean;

{ Translate a virtual address to a physical address.

  Parameters:
    pageTable: Target page table (nil = current page table)
    virtualAddr: Virtual address to translate

  Returns: Physical address, or 0 if not mapped

  x86_64: Walks PML4 → PDPT → PD → PT
  ARM64: Walks L0 → L1 → L2 → L3
  RISC-V: Walks page table hierarchy }
function HAL_VirtualToPhysical(pageTable: PPageTable; virtualAddr: QWord): QWord;

{ Check if a virtual address is mapped.

  Parameters:
    pageTable: Target page table (nil = current page table)
    virtualAddr: Virtual address to check

  Returns: true if mapped, false otherwise }
function HAL_IsPageMapped(pageTable: PPageTable; virtualAddr: QWord): Boolean;

{ Get page flags for a virtual address.

  Parameters:
    pageTable: Target page table (nil = current page table)
    virtualAddr: Virtual address to query

  Returns: Page flags, or empty set if not mapped }
function HAL_GetPageFlags(pageTable: PPageTable; virtualAddr: QWord): TPageFlags;

{ Update page flags for a virtual address.

  Parameters:
    pageTable: Target page table (nil = current page table)
    virtualAddr: Virtual address to modify
    flags: New flags

  Returns: true on success, false if page not mapped

  NOTE: Does NOT flush TLB — caller must call HAL_FlushTLB afterward. }
function HAL_SetPageFlags(pageTable: PPageTable; virtualAddr: QWord; flags: TPageFlags): Boolean;

{ ============================================================================
  TLB Management
  ============================================================================ }

{ Flush the entire Translation Lookaside Buffer (TLB) on the current CPU.
  Forces all virtual → physical translations to be reloaded from page tables.

  x86_64: Reloads CR3 (or uses INVLPG if available)
  ARM64: Issues TLBI VMALLE1
  RISC-V: Issues SFENCE.VMA with no arguments }
procedure HAL_FlushTLB;

{ Flush TLB entry for a specific virtual address on the current CPU.

  Parameters:
    virtualAddr: Virtual address to flush

  x86_64: Issues INVLPG instruction
  ARM64: Issues TLBI VAE1, virtualAddr
  RISC-V: Issues SFENCE.VMA with address argument }
procedure HAL_FlushTLBAddress(virtualAddr: QWord);

{ Flush TLB entries for an address range on the current CPU.

  Parameters:
    startAddr: Start of virtual address range
    endAddr: End of virtual address range (exclusive)

  x86_64: Issues multiple INVLPG (or full flush if range > threshold)
  ARM64: Issues TLBI VAAE1IS for range
  RISC-V: Issues multiple SFENCE.VMA (or full flush if large) }
procedure HAL_FlushTLBRange(startAddr, endAddr: QWord);

{ Flush TLB on ALL CPU cores (SMP TLB shootdown).
  Sends IPI to all other cores to flush their TLBs.

  Parameters:
    virtualAddr: Address to flush (0 = flush entire TLB)

  x86_64: Sends IPI with TLB flush vector
  ARM64: Issues TLBI with IS (Inner Shareable) suffix
  RISC-V: Sends IPI, recipients issue SFENCE.VMA }
procedure HAL_FlushTLBGlobal(virtualAddr: QWord);

{ ============================================================================
  Page Fault Handling
  ============================================================================ }

{ Get the virtual address that caused the last page fault on this CPU.

  x86_64: Reads CR2
  ARM64: Reads FAR_EL1 (Fault Address Register)
  RISC-V: Reads stval CSR

  Returns: Faulting virtual address }
function HAL_GetFaultAddress: QWord;

{ Get detailed page fault error code.
  Returns architecture-specific error code from the page fault exception.

  x86_64: Returns error code from stack (present/write/user/reserved/instr bits)
  ARM64: Returns ESR_EL1.ISS (Instruction Specific Syndrome)
  RISC-V: Returns scause CSR

  Interpretation of error code is architecture-specific.
  Use HAL_IsPageFaultWrite/HAL_IsPageFaultUser helpers instead. }
function HAL_GetFaultErrorCode: QWord;

{ Check if page fault was caused by a write access.

  Parameters:
    errorCode: Value from HAL_GetFaultErrorCode

  x86_64: Tests bit 1 (write)
  ARM64: Tests ESR_EL1.WnR (Write-not-Read)
  RISC-V: Checks scause = Store/AMO fault }
function HAL_IsPageFaultWrite(errorCode: QWord): Boolean;

{ Check if page fault occurred in user mode.

  Parameters:
    errorCode: Value from HAL_GetFaultErrorCode

  x86_64: Tests bit 2 (user)
  ARM64: Always true for EL0 faults (kernel faults are EL1)
  RISC-V: Always true for U-mode faults }
function HAL_IsPageFaultUser(errorCode: QWord): Boolean;

{ ============================================================================
  Memory Barriers & Cache Management
  ============================================================================ }

{ Issue a memory barrier to ensure page table updates are visible.
  MUST be called after modifying page tables before loading them.

  x86_64: MFENCE
  ARM64: DSB ISH (Data Synchronization Barrier, Inner Shareable)
  RISC-V: SFENCE.VMA }
procedure HAL_MemoryBarrier;

{ Flush data cache for a virtual address range.
  Used when page tables are modified in memory that might be cached.

  Parameters:
    startAddr: Start of range
    length: Length in bytes

  x86_64: No-op (x86 has coherent caches)
  ARM64: DC CVAU (Clean to Point of Unification)
  RISC-V: Platform-dependent (some have coherent caches) }
procedure HAL_FlushDataCache(startAddr: QWord; length: QWord);

{ Invalidate instruction cache for a virtual address range.
  Used when mapping executable code.

  Parameters:
    startAddr: Start of range
    length: Length in bytes

  x86_64: No-op (x86 has coherent I-cache)
  ARM64: IC IVAU (Invalidate to Point of Unification)
  RISC-V: FENCE.I }
procedure HAL_FlushInstructionCache(startAddr: QWord; length: QWord);

{ ============================================================================
  Debug & Diagnostics
  ============================================================================ }

{ Dump page table contents for debugging.
  Walks entire page table and prints mappings to serial/log.

  Parameters:
    pageTable: Page table to dump (nil = current) }
procedure HAL_DumpPageTable(pageTable: PPageTable);

{ Get MMU statistics: total mapped pages, TLB flush count, etc. }
procedure HAL_DumpMMUStats;

implementation

{ All functions are implemented by the architecture-specific backend:
  - x86_64: src/arch/x86_64/mmu_impl.pas
  - ARM64: src/arch/arm64/mmu_impl.pas
  - RISC-V: src/arch/riscv64/mmu_impl.pas

  At link time, the appropriate implementation is selected based on
  the target architecture. No wrapper overhead — direct function calls. }

end.
