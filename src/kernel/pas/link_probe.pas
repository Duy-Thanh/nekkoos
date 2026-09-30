{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: link_probe - link-only entry point for verify_pascal_link.sh.
  =========================================================================
  THIS UNIT IS NOT PART OF THE BOOT PATH.

  It exists so the link check in verify_pascal_link.sh has a valid entry
  symbol to point -entry at while the real boot sequence still lives in
  C#. Its only job is to be linkable: if this unit and every other object in
  the tree resolve under lld with no bflat in the picture, then the C#
  removal is mechanically achievable rather than merely intended.

  It is referenced only by the -entry flag of that script. Nothing calls it,
  and the shipped kernel does not contain it.

  When Kernel.cs is ported to Pascal, delete this unit and point the script's
  LINK_ENTRY at the real exported kernel entry instead.
  =========================================================================
}

unit link_probe;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$ASMMODE Intel}

interface

{ Takes the same argument the real kernel entry receives (NekkoBootInfo*),
  so the probe cannot accidentally succeed with a mismatched signature. }
procedure Pascal_LinkProbe(bootInfo: Pointer); cdecl; public name 'Pascal_LinkProbe';

implementation

uses serial, kstring, terminal;

{ Park the CPU. Written in inline asm rather than calling Halt, because Halt
  lives in the FPC System unit and pulling that in would put the FPC runtime
  into the link - exactly the dependency this migration is removing. }
procedure ProbePark; inline;
begin
  asm
    cli
    hlt
    jmp ProbePark
  end;
end;

{ --- Placeholders for the entry points that are still C# today -----------
  Hardware.asm references these directly; they are satisfied by
  InterruptHandlers.cs and Syscall.cs. Until those are ported, a link that
  excludes C# has no definition for them, so the probe supplies inert ones.

  These are NOT implementations. They exist so the probe link resolves, and
  they carry the same signatures the real handlers use so a mismatch would
  surface here rather than at the eventual cutover. When the real handlers
  are ported, delete this block and drop the symbol list from
  verify_pascal_link.sh. }

procedure SyscallHandler(currentRsp: QWord); cdecl; public name 'SyscallHandler';
begin
  ProbePark;
end;

procedure DivideByZeroHandler(currentRsp: QWord); cdecl; public name 'DivideByZeroHandler';
begin ProbePark; end;

procedure GPFHandler(currentRsp: QWord); cdecl; public name 'GPFHandler';
begin ProbePark; end;

procedure PageFaultHandler(currentRsp: QWord); cdecl; public name 'PageFaultHandler';
begin ProbePark; end;

procedure TimerHandler; cdecl; public name 'TimerHandler';
begin ProbePark; end;

procedure KeyboardHandler; cdecl; public name 'KeyboardHandler';
begin ProbePark; end;

procedure MouseHandler; cdecl; public name 'MouseHandler';
begin ProbePark; end;

procedure YieldHandler; cdecl; public name 'YieldHandler';
begin ProbePark; end;

procedure Pascal_LinkProbe(bootInfo: Pointer); cdecl;
begin
  { Touch the units this probe is meant to prove are linkable together, so
    the linker cannot discard them as unreferenced before it resolves them. }
  Serial_Init;
  Serial_WriteString(W('[link-probe] Pascal+NASM link OK'#13#10));
  Serial_WriteHex(QWord(bootInfo));
  Serial_WriteString(W(#13#10));
  Terminal_SetColor_Pas($00FF00FF);
  Terminal_Print_Pas(W('[link-probe] all units resolved without bflat'#13#10));
end;

end.
