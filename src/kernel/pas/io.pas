{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: io - Port I/O and interrupt-flag helpers.
  PORTED FROM: src/kernel/IO.cs (deleted).

  Thin, dependency-free wrapper over arch_interface. Exists so that kernel
  code never imports Hardware.asm symbols directly: I/O and HLT/CLI/STI go
  through this unit, which is the single place to retarget for a new
  architecture.
  =========================================================================
}

unit io;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

uses arch_interface;

procedure Io_Out8(port: Word; value: Byte); inline;
function  Io_In8(port: Word): Byte; inline;
procedure Io_Out16(port: Word; value: Word); inline;
function  Io_In16(port: Word): Word; inline;
procedure Io_Out32(port: Word; value: Cardinal); inline;
function  Io_In32(port: Word): Cardinal; inline;

procedure Io_EnableInterrupts; inline;
procedure Io_DisableInterrupts; inline;
procedure Io_Cli; inline;
procedure Io_Sti; inline;

{ HLT is a full pipeline stop, not a NOP. Callers use it to actually let the
  timer ISR run, e.g. in the BSP idle loop (AGENTS.md notes IO.Hlt() is
  required there under KVM, not just Scheduler.Yield()). }
procedure Io_Hlt; inline;
procedure Io_Wait; inline;

implementation

procedure Io_Out8(port: Word; value: Byte); inline;
begin Arch_WritePort8(port, value); end;

function Io_In8(port: Word): Byte; inline;
begin Io_In8 := Arch_ReadPort8(port); end;

procedure Io_Out16(port: Word; value: Word); inline;
begin Arch_WritePort16(port, value); end;

function Io_In16(port: Word): Word; inline;
begin Io_In16 := Arch_ReadPort16(port); end;

procedure Io_Out32(port: Word; value: Cardinal); inline;
begin Arch_WritePort32(port, value); end;

function Io_In32(port: Word): Cardinal; inline;
begin Io_In32 := Arch_ReadPort32(port); end;

procedure Io_EnableInterrupts; inline;
begin Arch_EnableInterrupts; end;

procedure Io_DisableInterrupts; inline;
begin Arch_DisableInterrupts; end;

procedure Io_Cli; inline;
begin Arch_DisableInterrupts; end;

procedure Io_Sti; inline;
begin Arch_EnableInterrupts; end;

procedure Io_Hlt; inline;
begin Arch_Halt; end;

procedure Io_Wait; inline;
begin Arch_IoWait; end;

end.
