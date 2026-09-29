{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: ioapic - IO APIC interrupt router.
  PORTED FROM: src/arch/x86_64/IOAPIC.cs (deleted).

  x86_64 ONLY. Once initialised, the IOAPIC replaces the legacy 8259 for all
  platform interrupts. It is discovered by the ring-3 ACPI daemon from the
  MADT table, so this unit does not locate it - it consumes the address the
  daemon publishes.

  INDEX/DATA PROTOCOL
  Unlike the Local APIC, the IOAPIC is NOT memory-mapped at fixed offsets.
  Every register is reached by writing a register number to offset 0x00 and
  then reading or writing the data port at 0x10. That is two dependent
  operations, so a full fence sits between them: if the data access were
  reordered ahead of the index write, the controller would fetch a stale or
  unrelated register. Accesses are serialised by a lock for the same reason.
  =========================================================================
}

unit ioapic;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

function Ioapic_GetBase: QWord;

{ Route one IRQ to a vector on a destination APIC, then unmask it. }
procedure Ioapic_SetEntry(irq, vector: Byte; destApicId: Cardinal);

procedure Ioapic_Init;
procedure Ioapic_MaskAll;

{ Locked register access. The index/data pair must not interleave with
  another core's, or both would read the wrong register. }
procedure Ioapic_Write(reg: Cardinal; value: Cardinal);
function  Ioapic_Read(reg: Cardinal): Cardinal;

implementation

uses arch_interface, vmm, spinlock, terminal, kstring, pic, apic;

{ HAL interrupt entry points (src/arch/x86_64/interrupt_impl.pas). }
procedure HAL_SetIoApicBase(base: QWord); cdecl; external name 'HAL_SetIoApicBase';
procedure HAL_RouteInterrupt(irq, coreId: Cardinal; vector: Byte); cdecl;
  external name 'HAL_RouteInterrupt';
procedure HAL_UnmaskInterrupt(irq: Cardinal); cdecl; external name 'HAL_UnmaskInterrupt';
procedure HAL_MaskInterrupt(irq: Cardinal); cdecl; external name 'HAL_MaskInterrupt';
function  HAL_GetCoreId: Cardinal; cdecl; external name 'HAL_GetCoreId';
procedure HAL_InitInterruptController; cdecl; external name 'HAL_InitInterruptController';

const
  IOAPIC_INDEX_REG = $00;   { write register number here }
  IOAPIC_DATA_REG   = $10;   { read/write the register's value here }

  { Register 0x01 holds the redirection table maximum in bits 16-23. }
  IOAPIC_REG_MAX_TABLE = $01;

  IOAPIC_MAX_REG     = $FF;

  { Lowest legal vector. 0-31 are CPU exception vectors and must never be
    reused for a hardware interrupt. }
  VECTOR_MIN        = 32;
  VECTOR_MAX        = 255;

  { PTE flags for the identity mapping: present + writable + user. }
  IOAPIC_MAP_FLAGS  = QWord($13);

  LVT_MASKED       = $10000;   { bit 16 of a redirection entry: masked }

var
  Ioapic_Base: QWord = 0;
  Ioapic_Lock: Cardinal = 0;

function Ioapic_GetBase: QWord;
begin Ioapic_GetBase := Ioapic_Base; end;

procedure Ioapic_Fatal(const msg: AnsiString); inline;
begin
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
end;

{ Unlocked index+data write. Callers that hold the lock use this directly. }
procedure WriteUnsafe(reg: Cardinal; value: Cardinal);
begin
  if Ioapic_Base = 0 then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC base address is zero!'#13#10);
    Exit;
  end;

  if reg > IOAPIC_MAX_REG then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC register number out of range!'#13#10);
    Exit;
  end;

  Arch_CompilerFence;
  Arch_WriteMmio32(Ioapic_Base, reg);

  { The controller must have consumed the index before the data write. }
  Arch_FullFence;

  Arch_WriteMmio32(Ioapic_Base + IOAPIC_DATA_REG, value);
  Arch_FullFence;
end;

procedure Ioapic_Write(reg: Cardinal; value: Cardinal);
var
  irq: Byte;
begin
  irq := Spinlock_AcquireSafe_Pas(@Ioapic_Lock);
  WriteUnsafe(reg, value);
  Spinlock_ReleaseSafe_Pas(@Ioapic_Lock, irq);
end;

function Ioapic_Read(reg: Cardinal): Cardinal;
var
  irq: Byte;
  val: Cardinal;
begin
  Ioapic_Read := 0;
  irq := Spinlock_AcquireSafe_Pas(@Ioapic_Lock);

  if Ioapic_Base = 0 then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC base address is zero!'#13#10);
    Spinlock_ReleaseSafe_Pas(@Ioapic_Lock, irq);
    Exit;
  end;

  if reg > IOAPIC_MAX_REG then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC register number out of range!'#13#10);
    Spinlock_ReleaseSafe_Pas(@Ioapic_Lock, irq);
    Exit;
  end;

  Arch_CompilerFence;
  Arch_WriteMmio32(Ioapic_Base, reg);

  { Wait for the index to be consumed before asking for the data. }
  Arch_FullFence;

  val := Arch_ReadMmio32(Ioapic_Base + IOAPIC_DATA_REG);

  Spinlock_ReleaseSafe_Pas(@Ioapic_Lock, irq);
  Ioapic_Read := val;
end;

procedure Ioapic_SetEntry(irq, vector: Byte; destApicId: Cardinal);
begin
  if irq > 255 then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC IRQ number too large!'#13#10);
    Exit;
  end;

  { Routing an IRQ onto 0-31 would collide with a CPU exception vector. }
  if (vector < VECTOR_MIN) or (vector > VECTOR_MAX) then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC vector number out of range!'#13#10);
    Exit;
  end;

  if destApicId > 255 then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC destination APIC ID too large!'#13#10);
    Exit;
  end;

  HAL_RouteInterrupt(irq, destApicId, vector);
  HAL_UnmaskInterrupt(irq);
end;

{ Map and validate the IOAPIC window, then silence the legacy PIC. }
function PrepareBase: Boolean;
begin
  PrepareBase := False;

  { The address is discovered by the ACPI daemon; it may not be there. }
  if Apic_GetIoApicBase = 0 then Exit;

  Ioapic_Base := Apic_GetIoApicBase;
  Vmm_MapPage(Ioapic_Base, Ioapic_Base, IOAPIC_MAP_FLAGS);

  if (Ioapic_Base and $F) <> 0 then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC base address is not 16-byte aligned!'#13#10);
    Exit;
  end;

  PrepareBase := True;
end;

procedure Ioapic_Init;
var
  bspApicId: Cardinal;
begin
  if not PrepareBase then Exit;

  { From here on the IOAPIC owns interrupt routing; the legacy controller
    must go quiet or both would deliver the same interrupt. }
  Pic_Disable;

  HAL_SetIoApicBase(Ioapic_Base);
  HAL_InitInterruptController;

  bspApicId := 0;
  if Apic_GetBaseVirt <> 0 then
  begin
    bspApicId := HAL_GetCoreId;
    if bspApicId > 255 then
    begin
      Ioapic_Fatal('[!] FATAL: BSP APIC ID too large!'#13#10);
      Exit;
    end;
  end;

  { IRQ 1 = keyboard, IRQ 12 = PS/2 mouse, IRQ 14/15 = primary/secondary IDE.
    Vectors must stay above 31; these are spaced out to leave room for the
    per-device handlers added later. }
  Ioapic_SetEntry(1,  33, bspApicId);
  Ioapic_SetEntry(12, 44, bspApicId);
  Ioapic_SetEntry(14, 46, bspApicId);
  Ioapic_SetEntry(15, 47, bspApicId);

  Terminal_SetColor_Pas($0000FFFF);
  Terminal_Print_Pas(W('[+] I/O APIC Armed! PCIe/Hardware Interrupts routed natively.'#13#10));
end;

procedure Ioapic_MaskAll;
var
  maxIntr, i: Cardinal;
begin
  if not PrepareBase then Exit;

  maxIntr := (Ioapic_Read(IOAPIC_REG_MAX_TABLE) shr 16) and $FF;

  if maxIntr > 255 then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC maximum interrupt too large!'#13#10);
    Exit;
  end;

  if maxIntr = 0 then
  begin
    Ioapic_Fatal('[!] FATAL: IOAPIC maximum interrupt is zero!'#13#10);
    Exit;
  end;

  { Each entry is two registers: low then high. Set the mask bit and zero
    the destination, which leaves every input acknowledged and ignored. }
  i := 0;
  while i <= maxIntr do
  begin
    WriteUnsafe($10 + (i * 2), LVT_MASKED);
    WriteUnsafe($10 + (i * 2) + 1, 0);
    Inc(i);
  end;
end;

end.
