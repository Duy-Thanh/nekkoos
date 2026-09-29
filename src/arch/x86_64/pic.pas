{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: pic - Legacy 8259A PIC controller.
  PORTED FROM: src/arch/x86_64/PIC.cs (deleted).

  x86_64 ONLY. The 8259A predates APIC; NekkoOS remaps it once during boot,
  then hands all interrupt routing to the IOAPIC and silences the PIC for
  good. It stays here because the APIC path still needs the remap sequence
  and the cascade wiring to be correct.
  =========================================================================
}

unit pic;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Master is chip 0 (0x20-0x21), slave is chip 1 (0xA0-0xA1) on the cascade
  line at IRQ2. }
procedure Pic_Remap;
procedure Pic_Disable;
procedure Pic_MaskAllIrqs;
procedure Pic_SendEOI;

implementation

uses io, terminal, kstring;

const
  PIC1_CMD  = $20;
  PIC1_DATA = $21;
  PIC2_CMD  = $A0;
  PIC2_DATA = $A1;

  ICW1_INIT = $11;   { edge triggered, cascade mode, expect ICW4 }
  ICW4_8086 = $01;   { 8086/88 mode }

  { Master gets vectors 0x20-0x27, slave 0x28-0x2F, leaving the CPU's own
    exception vectors 0-31 free. }
  PIC1_VECTOR_BASE = $20;
  PIC2_VECTOR_BASE = $28;

  { IRQ2 on the master is the slave's cascade line, so it must stay unmasked
    or the slave can never deliver an interrupt. }
  PIC1_ALL_BUT_CASCADE = $FC;
  PIC1_ONLY_CASCADE   = $FE;
  PIC2_ALL_MASKED     = $FF;

procedure Pic_Remap;
begin
  Io_Out8(PIC1_CMD, ICW1_INIT);  Io_Wait;
  Io_Out8(PIC2_CMD, ICW1_INIT);  Io_Wait;

  { ICW2: vector offsets }
  Io_Out8(PIC1_DATA, PIC1_VECTOR_BASE); Io_Wait;
  Io_Out8(PIC2_DATA, PIC2_VECTOR_BASE); Io_Wait;

  { ICW3: cascade wiring - slave is attached to master IRQ2 }
  Io_Out8(PIC1_DATA, $04); Io_Wait;
  Io_Out8(PIC2_DATA, $02); Io_Wait;

  { ICW4: 8086 mode }
  Io_Out8(PIC1_DATA, ICW4_8086); Io_Wait;
  Io_Out8(PIC2_DATA, ICW4_8086); Io_Wait;

  { Unmask the timer and keyboard lines only. }
  Io_Out8(PIC1_DATA, PIC1_ALL_BUT_CASCADE); Io_Wait;
  Io_Out8(PIC2_DATA, PIC2_ALL_MASKED); Io_Wait;
end;

{ Mute both chips completely. Called once the IOAPIC has taken over, so the
  legacy controller can no longer generate a spurious interrupt. }
procedure Pic_Disable;
begin
  Io_Out8(PIC2_DATA, PIC2_ALL_MASKED);
  Io_Out8(PIC1_DATA, PIC2_ALL_MASKED);

  Terminal_SetColor_Pas($00FF00FF);
  Terminal_Print_Pas(W('[-] Legacy 8259 PIC has been completely silenced & disabled.'#13#10));
end;

procedure Pic_MaskAllIrqs;
begin
  Io_Out8(PIC1_DATA, PIC1_ONLY_CASCADE);
  Io_Out8(PIC2_DATA, PIC2_ALL_MASKED);
end;

procedure Pic_SendEOI;
begin
  Io_Out8(PIC1_CMD, $20);
end;

end.
