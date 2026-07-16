unit interrupt_impl;

{ x86_64 Implementation of HAL Interrupt Controller Interface

  Implements the generic interrupt controller HAL for x86_64
  using APIC (Advanced Programmable Interrupt Controller) + IOAPIC.

  Architecture mapping:
  - Local APIC: Per-core interrupt controller (EOI, IPI, local timer)
  - IOAPIC: System-wide interrupt routing (maps IRQs to vectors)
  - Legacy PIC (8259): Disabled during init (APIC mode)

  Documented in src/arch/hal/interrupt.pas }

{$MODE FPC}
{$ASMMODE Intel}

interface

const
  IRQ_TIMER       = 0;
  IRQ_KEYBOARD    = 1;
  IRQ_SERIAL1     = 4;
  IRQ_MOUSE       = 12;
  IRQ_ATA_PRIMARY = 14;

procedure HAL_InitInterruptController; cdecl; public name 'HAL_InitInterruptController';
function  HAL_GetInterruptCount: Cardinal; cdecl; public name 'HAL_GetInterruptCount';
procedure HAL_RouteInterrupt(irq, coreId: Cardinal; vector: Byte); cdecl; public name 'HAL_RouteInterrupt';
procedure HAL_MaskInterrupt(irq: Cardinal); cdecl; public name 'HAL_MaskInterrupt';
procedure HAL_UnmaskInterrupt(irq: Cardinal); cdecl; public name 'HAL_UnmaskInterrupt';
procedure HAL_SendEOI(vector: Byte); cdecl; public name 'HAL_SendEOI';
procedure HAL_SendIPI(targetCore: Cardinal; vector: Byte); cdecl; public name 'HAL_SendIPI';
procedure HAL_BroadcastIPI(vector: Byte); cdecl; public name 'HAL_BroadcastIPI';
procedure HAL_SetInterruptPriority(irq: Cardinal; priority: Byte); cdecl; public name 'HAL_SetInterruptPriority';
procedure HAL_SetTriggerMode(irq: Cardinal; isEdgeTriggered: Boolean); cdecl; public name 'HAL_SetTriggerMode';
procedure HAL_StartLocalTimer(frequencyHz: Cardinal); cdecl; public name 'HAL_StartLocalTimer';
procedure HAL_StopLocalTimer; cdecl; public name 'HAL_StopLocalTimer';
function  HAL_GetCoreId: Cardinal; cdecl; public name 'HAL_GetCoreId';
procedure HAL_DumpInterruptState; cdecl; public name 'HAL_DumpInterruptState';
procedure HAL_SetLocalApicBase(base: QWord); cdecl; public name 'HAL_SetLocalApicBase';
procedure HAL_SetIoApicBase(base: QWord); cdecl; public name 'HAL_SetIoApicBase';

implementation

{ AAL Layer 1 primitives from Hardware.asm }
procedure Arch_WriteMmio32(addr: QWord; value: Cardinal); cdecl; external name 'Arch_WriteMmio32';
function  Arch_ReadMmio32(addr: QWord): Cardinal; cdecl; external name 'Arch_ReadMmio32';
procedure Arch_WritePort8(port: Word; value: Byte); cdecl; external name 'Arch_WritePort8';
procedure Arch_CompilerFence; cdecl; external name 'Arch_CompilerFence';

{ APIC register offsets }
const
  APIC_REG_ID        = $020;
  APIC_REG_EOI       = $0B0;
  APIC_REG_SPURIOUS  = $0F0;
  APIC_REG_ICR_LOW   = $300;
  APIC_REG_ICR_HIGH  = $310;
  APIC_REG_TIMER_LVT = $320;
  APIC_REG_TIMER_INIT = $380;
  APIC_REG_TIMER_DIV = $3E0;

  IOAPIC_REG_VER     = $01;
  IOAPIC_REDTBL_BASE = $10;

  ICR_DELIVERY_FIXED     = $000;
  ICR_DEST_ALL_EXCL_SELF = $C0000;

var
  LocalApicBase: QWord = 0;
  IoApicBase:    QWord = 0;
  IoApicMaxRedirEntry: Cardinal = 0;

{ Low-level access helpers }

function ReadApic(offset: Cardinal): Cardinal; inline;
begin
  ReadApic := Arch_ReadMmio32(LocalApicBase + offset);
end;

procedure WriteApic(offset: Cardinal; value: Cardinal); inline;
begin
  Arch_WriteMmio32(LocalApicBase + offset, value);
end;

function ReadIoApic(reg: Byte): Cardinal;
begin
  Arch_WriteMmio32(IoApicBase, reg);
  ReadIoApic := Arch_ReadMmio32(IoApicBase + $10);
end;

procedure WriteIoApic(reg: Byte; value: Cardinal);
begin
  Arch_WriteMmio32(IoApicBase, reg);
  Arch_WriteMmio32(IoApicBase + $10, value);
end;

procedure ReadIoApicRedirect(irq: Cardinal; var low, high: Cardinal);
var reg: Byte;
begin
  reg := IOAPIC_REDTBL_BASE + (irq * 2);
  low  := ReadIoApic(reg);
  high := ReadIoApic(reg + 1);
end;

procedure WriteIoApicRedirect(irq: Cardinal; low, high: Cardinal);
var reg: Byte;
begin
  reg := IOAPIC_REDTBL_BASE + (irq * 2);
  WriteIoApic(reg + 1, high);
  WriteIoApic(reg, low);
end;

{ HAL implementations }

procedure HAL_InitInterruptController; cdecl;
var
  spurious, version, i: Cardinal;
begin
  if LocalApicBase = 0 then
    LocalApicBase := $FEE00000;

  { Enable Local APIC and set spurious vector to 0xFF }
  WriteApic(APIC_REG_SPURIOUS, $1FF);
  { Set TPR to 0 (Task Priority Register) }
  WriteApic($080, 0);

  { Initialize IOAPIC if present }
  if IoApicBase <> 0 then
  begin
    version := ReadIoApic(IOAPIC_REG_VER);
    IoApicMaxRedirEntry := ((version shr 16) and $FF) + 1;
    for i := 0 to IoApicMaxRedirEntry - 1 do
      WriteIoApicRedirect(i, $10000, 0);  { Mask all }
  end;
end;

function HAL_GetInterruptCount: Cardinal; cdecl;
begin
  HAL_GetInterruptCount := IoApicMaxRedirEntry;
end;

procedure HAL_RouteInterrupt(irq, coreId: Cardinal; vector: Byte); cdecl;
var low, high: Cardinal;
begin
  if irq >= IoApicMaxRedirEntry then Exit;
  low  := vector or (ICR_DELIVERY_FIXED shl 8);
  high := coreId shl 24;
  WriteIoApicRedirect(irq, low or $10000, high);
end;

procedure HAL_MaskInterrupt(irq: Cardinal); cdecl;
var low, high: Cardinal;
begin
  if irq >= IoApicMaxRedirEntry then Exit;
  ReadIoApicRedirect(irq, low, high);
  WriteIoApicRedirect(irq, low or $10000, high);
end;

procedure HAL_UnmaskInterrupt(irq: Cardinal); cdecl;
var low, high: Cardinal;
begin
  if irq >= IoApicMaxRedirEntry then Exit;
  ReadIoApicRedirect(irq, low, high);
  WriteIoApicRedirect(irq, low and (not $10000), high);
end;

procedure HAL_SendEOI(vector: Byte); cdecl;
begin
  WriteApic(APIC_REG_EOI, 0);
end;

procedure HAL_SendIPI(targetCore: Cardinal; vector: Byte); cdecl;
begin
  while (ReadApic(APIC_REG_ICR_LOW) and $1000) <> 0 do
    Arch_CompilerFence;
  WriteApic(APIC_REG_ICR_HIGH, targetCore shl 24);
  WriteApic(APIC_REG_ICR_LOW, vector or ICR_DELIVERY_FIXED);
end;

procedure HAL_BroadcastIPI(vector: Byte); cdecl;
begin
  while (ReadApic(APIC_REG_ICR_LOW) and $1000) <> 0 do
    Arch_CompilerFence;
  WriteApic(APIC_REG_ICR_LOW, vector or ICR_DELIVERY_FIXED or ICR_DEST_ALL_EXCL_SELF);
end;

procedure HAL_SetInterruptPriority(irq: Cardinal; priority: Byte); cdecl;
begin
  { x86 APIC: no-op (fixed priority model) }
end;

procedure HAL_SetTriggerMode(irq: Cardinal; isEdgeTriggered: Boolean); cdecl;
var low, high: Cardinal;
begin
  if irq >= IoApicMaxRedirEntry then Exit;
  ReadIoApicRedirect(irq, low, high);
  if isEdgeTriggered then
    low := low and (not $8000)
  else
    low := low or $8000;
  WriteIoApicRedirect(irq, low, high);
end;

procedure HAL_StartLocalTimer(frequencyHz: Cardinal); cdecl;
begin
  { Vector 32, periodic mode (bit 17), divide by 16 }
  WriteApic(APIC_REG_TIMER_DIV, $03);
  WriteApic(APIC_REG_TIMER_LVT, 32 or $20000);
  WriteApic(APIC_REG_TIMER_INIT, 1000000);  { Calibration placeholder }
end;

procedure HAL_StopLocalTimer; cdecl;
begin
  WriteApic(APIC_REG_TIMER_LVT, $10000);  { Masked }
end;

function HAL_GetCoreId: Cardinal; cdecl;
begin
  HAL_GetCoreId := (ReadApic(APIC_REG_ID) shr 24) and $FF;
end;

procedure HAL_DumpInterruptState; cdecl;
begin
  { TODO: Print APIC/IOAPIC state to serial }
end;

procedure HAL_SetLocalApicBase(base: QWord); cdecl;
begin
  LocalApicBase := base;
end;

procedure HAL_SetIoApicBase(base: QWord); cdecl;
begin
  IoApicBase := base;
end;

end.
