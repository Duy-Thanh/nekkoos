{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: pit - Legacy 8253/8254 programmable interval timer driver.
  PORTED FROM: src/arch/x86_64/PIT.cs (deleted).

  x86_64 ONLY.

  NekkoOS runs the system tick off the Local APIC timer; the PIT is retained
  as a fallback and as a boot-time time source, and its tick counter is used
  for the daemon handshake timeouts during early boot.

  Ticks are owned by the HAL timer (timer_impl.pas) - this unit programs the
  hardware divisor and converts milliseconds to ticks. It does not own the
  counter, so there is exactly one tick source in the system.
  =========================================================================
}

unit pit;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Current programmed frequency in Hz. Defaults to 250 before Init. }
function Pit_GetFrequency: Cardinal;
procedure Pit_SetFrequency(f: Cardinal);

{ Milliseconds -> scheduler ticks, scaled to the current frequency. }
function Pit_MsToTicks(ms: QWord): QWord;

{ Blocking sleep. Yields rather than spinning, so other threads run. }
procedure Pit_Sleep(ms: QWord);

procedure Pit_Init(frequency: Cardinal);

implementation

uses io, terminal, kstring, timer_impl, arch_interface;

const
  { Crystal frequency of the 8253/8254, 14.31818 MHz / 12. }
  PIT_BASE_FREQ = 1193182;

  PIT_CMD_PORT   = $43;
  PIT_DATA_PORT_0 = $40;

  { Channel 0, access lobyte/hibyte, mode 2 (rate generator). Mode 2 emits a
    steady pulse train rather than a one-shot, which is what the IRQ0 handler
    expects. }
  PIT_CMD_CHANNEL0_MODE2 = $34;

  PIT_FREQ_MIN = 1;
  PIT_FREQ_MAX = 10000;

  { Guard for ms * frequency overflowing a QWord. }
  MS_OVERFLOW_GUARD = QWord($0FFFFFFFFFFFF);

var
  Pit_CurrentFreq: Cardinal = 250;

function Pit_GetFrequency: Cardinal;
begin
  Pit_GetFrequency := Pit_CurrentFreq;
end;

procedure Pit_SetFrequency(f: Cardinal);
begin
  Pit_CurrentFreq := f;
end;

procedure Pit_Fatal(const msg: AnsiString); inline;
begin
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
end;

procedure Pit_Init(frequency: Cardinal);
var
  divisor: Cardinal;
begin
  { Clamp rather than reject: 0 and absurdly high values are configuration
    mistakes, and falling back to 250 Hz is more useful than refusing. }
  if frequency = 0 then frequency := 250;
  if frequency > PIT_BASE_FREQ then frequency := PIT_BASE_FREQ;

  if (frequency < PIT_FREQ_MIN) or (frequency > PIT_FREQ_MAX) then
  begin
    Pit_Fatal('[!] FATAL: PIT frequency out of range!'#13#10);
    Exit;
  end;

  Pit_CurrentFreq := frequency;

  divisor := PIT_BASE_FREQ div frequency;
  if divisor > 65535 then
  begin
    Pit_Fatal('[!] FATAL: PIT divisor too large!'#13#10);
    Exit;
  end;

  if divisor = 0 then
  begin
    Pit_Fatal('[!] FATAL: PIT divisor cannot be zero!'#13#10);
    Exit;
  end;

  { Program the divisor with interrupts off: a partially written divisor
    would produce a wildly wrong rate for a few cycles. }
  Io_Cli;
  Io_Out8(PIT_CMD_PORT, PIT_CMD_CHANNEL0_MODE2);
  Io_Wait;
  Io_Out8(PIT_DATA_PORT_0, Byte(divisor and $FF));
  Io_Wait;
  Io_Out8(PIT_DATA_PORT_0, Byte((divisor shr 8) and $FF));
  Io_Wait;
  Io_Sti;
end;

function Pit_MsToTicks(ms: QWord): QWord;
var
  ticks: QWord;
begin
  if ms = 0 then
  begin
    Pit_MsToTicks := 0;
    Exit;
  end;

  { Refuse to multiply rather than wrap: a wrapped value would produce a
    sleep of a few ticks instead of the requested duration. }
  if ms > MS_OVERFLOW_GUARD div QWord(Pit_CurrentFreq) then
  begin
    Pit_Fatal('[!] FATAL: PIT multiplication overflow!'#13#10);
    Pit_MsToTicks := $0FFFFFFFFFFFF;
    Exit;
  end;

  ticks := (ms * QWord(Pit_CurrentFreq)) div 1000;

  { Any non-zero wait must advance the clock by at least one tick, or the
    caller would spin forever against a counter that cannot advance. }
  if (ticks = 0) and (ms > 0) then ticks := 1;

  Pit_MsToTicks := ticks;
end;

procedure Pit_Sleep(ms: QWord);
var
  targetTicks: QWord;
begin
  { Yield rather than spin, so other threads make progress. Arch_ForceYield
    is what Scheduler.Yield resolves to; going through the AAL keeps the
    dependency one-directional and avoids a unit cycle. }
  targetTicks := HAL_GetTickCount + Pit_MsToTicks(ms);
  while HAL_GetTickCount < targetTicks do
    Arch_ForceYield;
end;

end.
