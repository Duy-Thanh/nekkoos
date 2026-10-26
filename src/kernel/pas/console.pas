{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: console - locked front end of the framebuffer terminal.
  PORTED FROM: src/kernel/Terminal.cs.

  terminal.pas draws; it cannot know about threads (the scheduler already
  depends on it). This unit supplies what it needs from above through the
  Terminal_SetCallbacks_Pas hooks: the per-thread text colour and the serial
  mirror, and adds the screen lock the C# Terminal class used to own.

  Output from the many Pascal units that call Terminal_Print_Pas directly is
  unlocked, as before. Anything that may run concurrently with other cores
  goes through Con_* instead.
  =========================================================================
}
unit console;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Describe the UEFI framebuffer and clear it. }
procedure Con_Init(fbBase: QWord; width, height, scanLine: Cardinal);

{ Back the terminal with a RAM copy of the framebuffer. }
procedure Con_EnableShadowBuffer;

{ Point output at another framebuffer (syscall 52). Rejects unaligned or empty
  descriptions. }
procedure Con_RedirectOutput(newFb: PCardinal; newWidth, newHeight, newScanLine: Cardinal);

{ The screen lock. Acquire disables interrupts on this core first, then
  spins; the returned flag says whether to turn them back on. }
function  Con_ScreenLockAcquire: Boolean;
procedure Con_ScreenLockRelease(irqWasEnabled: Boolean);

procedure Con_SetColor(fg: Cardinal);
procedure Con_Print(str: PWord);
procedure Con_PrintHex(val: QWord);
procedure Con_PrintDec(val: QWord);
procedure Con_DrawChar(c: Word);
procedure Con_Clear(color: Cardinal);

function Con_GetFb: PCardinal;
{ Physical base of the UEFI framebuffer as handed over at boot (never changes
  when output is redirected). }
function Con_GetBootFbBase: QWord;
function Con_GetWidth: Cardinal;
function Con_GetHeight: Cardinal;
function Con_GetScanLine: Cardinal;
function Con_GetBackbuffer: PCardinal;
procedure Con_SetBackbuffer(buf: PCardinal);

implementation

uses arch_interface, io, kstring, libc, pmm, serial, spinlock, terminal, scheduler;

var
  gFb: PCardinal = nil;
  gWidth, gHeight, gScanLine: Cardinal;
  gBackbuffer: PCardinal = nil;
  gBootFbBase: QWord = 0;
  gScreenLock: Cardinal = 0;

  { Colour used before the scheduler exists, or when no thread owns this core. }
  BootColor: Cardinal = $00FFFFFF;

function Con_ScreenLockAcquire: Boolean;
begin
  Con_ScreenLockAcquire := (Arch_GetFlags and $200) <> 0;
  Io_Cli;
  Spinlock_Acquire_Pas(@gScreenLock);
end;

procedure Con_ScreenLockRelease(irqWasEnabled: Boolean);
begin
  Spinlock_Release_Pas(@gScreenLock);
  if irqWasEnabled then Io_EnableInterrupts;
end;

procedure Con_SetColor(fg: Cardinal);
begin
  Terminal_SetColor_Pas(fg);
end;

procedure Con_Print(str: PWord);
var
  irq: Boolean;
begin
  irq := Con_ScreenLockAcquire;
  Terminal_Print_Pas(str);
  Con_ScreenLockRelease(irq);
end;

procedure Con_PrintHex(val: QWord);
var
  irq: Boolean;
begin
  irq := Con_ScreenLockAcquire;
  Terminal_PrintHex_Pas(val);
  Con_ScreenLockRelease(irq);
end;

procedure Con_PrintDec(val: QWord);
var
  irq: Boolean;
begin
  irq := Con_ScreenLockAcquire;
  Terminal_PrintDec_Pas(val);
  Con_ScreenLockRelease(irq);
end;

procedure Con_DrawChar(c: Word);
var
  irq: Boolean;
begin
  irq := Con_ScreenLockAcquire;
  Terminal_DrawChar_Pas(c);
  Con_ScreenLockRelease(irq);
end;

procedure Con_Clear(color: Cardinal);
var
  irq: Boolean;
begin
  irq := Con_ScreenLockAcquire;
  Terminal_Clear_Pas(color);
  Con_ScreenLockRelease(irq);
end;

{ ── Hooks terminal.pas calls back into ──────────────────────────────────── }

{ Text colour is per thread, so parallel cores do not overwrite each other's. }
function CbGetColor: Cardinal; cdecl;
var
  cur: Integer;
begin
  if (not Sched_IsReady) or (Sched_GetCurrentThreadIds = nil) then
  begin
    CbGetColor := BootColor;
    Exit;
  end;
  cur := Sched_GetCurrentThreadId;
  if (cur < 0) or (cur >= Sched_GetThreadCount) then
  begin
    CbGetColor := BootColor;
    Exit;
  end;
  CbGetColor := Sched_GetThreadTextColor(cur);
end;

procedure CbSetColor(color: Cardinal); cdecl;
var
  cur: Integer;
begin
  if (not Sched_IsReady) or (Sched_GetCurrentThreadIds = nil) then
  begin
    BootColor := color;
    Exit;
  end;
  cur := Sched_GetCurrentThreadId;
  if (cur < 0) or (cur >= Sched_GetThreadCount) then
  begin
    BootColor := color;
    Exit;
  end;
  Sched_SetThreadTextColor(cur, color);
end;

procedure CbSerialWriteChar(c: Byte); cdecl;
begin
  Serial_WriteChar(Word(c));
end;

{ ── Setup ────────────────────────────────────────────────────────────────── }

procedure Con_Init(fbBase: QWord; width, height, scanLine: Cardinal);
begin
  gBootFbBase := fbBase;
  gFb := PCardinal(Pointer(fbBase));
  gWidth := width;
  gHeight := height;
  gScanLine := scanLine;
  gBackbuffer := nil;

  Terminal_SetFB_Pas(Pointer(gFb), gWidth, gHeight, gScanLine);
  Terminal_SetCallbacks_Pas(Pointer(@CbSerialWriteChar), Pointer(@CbGetColor),
    Pointer(@CbSetColor));
  Terminal_Clear_Pas($00111111);
end;

procedure Con_EnableShadowBuffer;
var
  irq: Boolean;
  bufferBytes, numPages: QWord;
  bb: PCardinal;
begin
  irq := Con_ScreenLockAcquire;
  bufferBytes := QWord(gScanLine) * QWord(gHeight) * 4;
  numPages := (bufferBytes + 4095) div 4096;
  bb := PCardinal(Pmm_AllocateContiguousPages(numPages));
  if bb = nil then
  begin
    Con_ScreenLockRelease(irq);
    Terminal_SetColor_Pas($00FF0000);
    Con_Print(W('[!] Terminal: Out of Contiguous RAM! Shadow Buffer failed!'#13#10));
    Exit;
  end;
  MemCopy(bb, gFb, Cardinal(bufferBytes));
  gBackbuffer := bb;
  Terminal_SetBackbuffer_Pas(bb);
  Con_ScreenLockRelease(irq);
  Terminal_SetColor_Pas($0000FF00);
  Con_Print(W('[+] Terminal Shadow Buffer Activated!'#13#10));
end;

procedure Con_RedirectOutput(newFb: PCardinal; newWidth, newHeight, newScanLine: Cardinal);
var
  irq: Boolean;
begin
  irq := Con_ScreenLockAcquire;
  if (newFb = nil) or (newWidth = 0) or (newHeight = 0) or (newScanLine = 0) or
     ((QWord(newFb) and 7) <> 0) then
  begin
    Con_ScreenLockRelease(irq);
    Exit;
  end;
  gFb := newFb;
  gWidth := newWidth;
  gHeight := newHeight;
  gScanLine := newScanLine;
  gBackbuffer := nil;
  Terminal_SetFB_Pas(Pointer(newFb), newWidth, newHeight, newScanLine);
  Terminal_SetBackbuffer_Pas(nil);
  Terminal_Clear_Pas($00000000);
  Con_ScreenLockRelease(irq);
end;

function Con_GetFb: PCardinal;
begin
  Con_GetFb := gFb;
end;

function Con_GetBootFbBase: QWord;
begin
  Con_GetBootFbBase := gBootFbBase;
end;

function Con_GetWidth: Cardinal;
begin
  Con_GetWidth := gWidth;
end;

function Con_GetHeight: Cardinal;
begin
  Con_GetHeight := gHeight;
end;

function Con_GetScanLine: Cardinal;
begin
  Con_GetScanLine := gScanLine;
end;

function Con_GetBackbuffer: PCardinal;
begin
  Con_GetBackbuffer := gBackbuffer;
end;

procedure Con_SetBackbuffer(buf: PCardinal);
begin
  gBackbuffer := buf;
end;

{ ── cdecl exports for Terminal.cs ── }

procedure Con_Init_Pas(fbBase: QWord; w, h, scan: Cardinal); cdecl; public name 'Con_Init_Pas';
begin
  Con_Init(fbBase, w, h, scan);
end;

procedure Con_EnableShadowBuffer_Pas; cdecl; public name 'Con_EnableShadowBuffer_Pas';
begin
  Con_EnableShadowBuffer;
end;

procedure Con_RedirectOutput_Pas(newFb: PCardinal; w, h, scan: Cardinal); cdecl; public name 'Con_RedirectOutput_Pas';
begin
  Con_RedirectOutput(newFb, w, h, scan);
end;

function Con_ScreenLockAcquire_Pas: Byte; cdecl; public name 'Con_ScreenLockAcquire_Pas';
begin
  Con_ScreenLockAcquire_Pas := Ord(Con_ScreenLockAcquire);
end;

procedure Con_ScreenLockRelease_Pas(irq: Byte); cdecl; public name 'Con_ScreenLockRelease_Pas';
begin
  Con_ScreenLockRelease(irq <> 0);
end;

procedure Con_Print_Pas(str: PWord); cdecl; public name 'Con_Print_Pas';
begin
  Con_Print(str);
end;

procedure Con_PrintHex_Pas(val: QWord); cdecl; public name 'Con_PrintHex_Pas';
begin
  Con_PrintHex(val);
end;

procedure Con_PrintDec_Pas(val: QWord); cdecl; public name 'Con_PrintDec_Pas';
begin
  Con_PrintDec(val);
end;

procedure Con_DrawChar_Pas(c: Word); cdecl; public name 'Con_DrawChar_Pas';
begin
  Con_DrawChar(c);
end;

procedure Con_Clear_Pas(color: Cardinal); cdecl; public name 'Con_Clear_Pas';
begin
  Con_Clear(color);
end;

function Con_GetFb_Pas: PCardinal; cdecl; public name 'Con_GetFb_Pas';
begin
  Con_GetFb_Pas := gFb;
end;

function Con_GetWidth_Pas: Cardinal; cdecl; public name 'Con_GetWidth_Pas';
begin
  Con_GetWidth_Pas := gWidth;
end;

function Con_GetHeight_Pas: Cardinal; cdecl; public name 'Con_GetHeight_Pas';
begin
  Con_GetHeight_Pas := gHeight;
end;

function Con_GetScanLine_Pas: Cardinal; cdecl; public name 'Con_GetScanLine_Pas';
begin
  Con_GetScanLine_Pas := gScanLine;
end;

function Con_GetBackbuffer_Pas: PCardinal; cdecl; public name 'Con_GetBackbuffer_Pas';
begin
  Con_GetBackbuffer_Pas := gBackbuffer;
end;

procedure Con_SetBackbuffer_Pas(buf: PCardinal); cdecl; public name 'Con_SetBackbuffer_Pas';
begin
  gBackbuffer := buf;
end;

end.
