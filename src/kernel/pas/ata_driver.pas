{
  =========================================================================
  NekkoOS — ata_driver.pas
  Kernel-side ATA PIO driver (Ring-0 fallback + daemon bridge).
  Ported from ATA.cs.
  =========================================================================
}
unit ata_driver;

{$mode objfpc}
{$h+}
{$inline on}
{$TYPEINFO OFF}

interface

uses arch_interface;

{ One-time init: pass pointers to C# statics. }
procedure ATA_SetGlobals_Pas(useDaemonPtr: PByte; daemonIdPtr: PCardinal;
    sharedRamPtr: PQWord; totalPagesPtr: PQWord); cdecl;

{ Acquire/release software-level async lock (spin + yield). }
procedure ATA_AcquireAsync_Pas; cdecl;
procedure ATA_ReleaseAsync_Pas; cdecl;

{ Acquire/release HW spinlock (raw, no interrupt management). }
procedure ATA_HwLockAcquire_Pas(lockVar: PCardinal); cdecl;
procedure ATA_HwLockRelease_Pas(lockVar: PCardinal); cdecl;

{ Ring-0 PIO operations (caller must hold HW lock). }
procedure ATA_ReadSectorRaw_Pas(lba: Cardinal; buffer: PByte); cdecl;
procedure ATA_WriteSectorRaw_Pas(lba: Cardinal; buffer: PByte); cdecl;
procedure ATA_FlushCacheRaw_Pas; cdecl;

{ Disk geometry detection + LBA range check. }
procedure ATA_DetectDiskSize_Pas; cdecl;
function  ATA_IsLbaInRange_Pas(lba: Cardinal; hwLockVar: PCardinal): Byte; cdecl;

implementation

{ ── Forward declarations for Terminal (external from terminal.pas) ────── }
procedure Term_SetColor(color: Cardinal); cdecl; external name 'Terminal_SetColor_Pas';
procedure Term_Print(str: PWord); cdecl; external name 'Terminal_Print_Pas';

{ ── Global pointers ─────────────────────────────────────────────────────── }
var
  g_useDaemon:  PByte     = nil;
  g_daemonId:   PCardinal = nil;
  g_sharedRam:  PQWord    = nil;
  g_totalPages: PQWord    = nil;

  g_detectedSectors: Cardinal = 0;
  g_asyncBusy: Byte     = 0;
  g_asyncLock: Cardinal = 0;

{ ── Spinlock helpers ────────────────────────────────────────────────────── }
function LockAcquireSafe(lockVar: PCardinal): Byte; inline;
var flags: QWord;
begin
  flags := Arch_GetFlags();
  Arch_DisableInterrupts();
  Arch_SpinlockAcquire(lockVar);
  Arch_CompilerFence();
  if (flags and $200) <> 0 then Result := 1 else Result := 0;
end;

procedure LockReleaseSafe(lockVar: PCardinal; wasEnabled: Byte); inline;
begin
  Arch_CompilerFence();
  Arch_StoreFence();
  Arch_SpinlockRelease(lockVar);
  if wasEnabled <> 0 then Arch_EnableInterrupts();
end;

{ ── IO helpers ──────────────────────────────────────────────────────────── }
function  InByte(port: Word): Byte; inline; begin Result := Arch_ReadPort8(port);  end;
procedure OutByte(port: Word; val: Byte); inline; begin Arch_WritePort8(port, val); end;
function  InWord(port: Word): Word; inline; begin Result := Arch_ReadPort16(port); end;
procedure OutWord(port: Word; val: Word); inline; begin Arch_WritePort16(port, val);end;

{ ── Inline print helpers using fixed string literals ────────────────────── }
{ We can't use fixed() in Pascal, so we use static string constants.
  Since these are error paths only, we store them as Word arrays (UTF-16 LE). }

procedure PrintMsg(msg: PChar);
{ Simple helper: print a plain ASCII string via terminal }
var
  tmp: array[0..127] of Word;
  i: Integer;
begin
  i := 0;
  while (msg[i] <> #0) and (i < 127) do
  begin
    tmp[i] := Ord(msg[i]);
    Inc(i);
  end;
  tmp[i] := 0;
  Term_Print(@tmp[0]);
end;

{ ── WaitAtaHardware ─────────────────────────────────────────────────────── }
function WaitAtaHardware: Boolean;
var timeout: Integer;
begin
  timeout := 1000000;
  while timeout > 0 do
  begin
    if (InByte($1F7) and $80) = 0 then begin Result := True; Exit; end;
    Dec(timeout);
  end;
  Result := False;
end;

{ ── ATA_SetGlobals_Pas ──────────────────────────────────────────────────── }
procedure ATA_SetGlobals_Pas(useDaemonPtr: PByte; daemonIdPtr: PCardinal;
    sharedRamPtr: PQWord; totalPagesPtr: PQWord); cdecl;
    public name 'ATA_SetGlobals_Pas';
begin
  g_useDaemon  := useDaemonPtr;
  g_daemonId   := daemonIdPtr;
  g_sharedRam  := sharedRamPtr;
  g_totalPages := totalPagesPtr;
end;

{ ── ATA_AcquireAsync_Pas ────────────────────────────────────────────────── }
procedure ATA_AcquireAsync_Pas; cdecl; public name 'ATA_AcquireAsync_Pas';
var irq: Byte;
begin
  while True do
  begin
    irq := LockAcquireSafe(@g_asyncLock);
    if g_asyncBusy = 0 then
    begin
      g_asyncBusy := 1;
      LockReleaseSafe(@g_asyncLock, irq);
      Exit;
    end;
    LockReleaseSafe(@g_asyncLock, irq);
    Arch_ForceYield();
  end;
end;

{ ── ATA_ReleaseAsync_Pas ────────────────────────────────────────────────── }
procedure ATA_ReleaseAsync_Pas; cdecl; public name 'ATA_ReleaseAsync_Pas';
var irq: Byte;
begin
  irq := LockAcquireSafe(@g_asyncLock);
  g_asyncBusy := 0;
  LockReleaseSafe(@g_asyncLock, irq);
end;

{ ── ATA_HwLockAcquire/Release ───────────────────────────────────────────── }
procedure ATA_HwLockAcquire_Pas(lockVar: PCardinal); cdecl;
    public name 'ATA_HwLockAcquire_Pas';
begin
  Arch_DisableInterrupts();
  Arch_SpinlockAcquire(lockVar);
  Arch_CompilerFence();
end;

procedure ATA_HwLockRelease_Pas(lockVar: PCardinal); cdecl;
    public name 'ATA_HwLockRelease_Pas';
begin
  Arch_CompilerFence();
  Arch_StoreFence();
  Arch_SpinlockRelease(lockVar);
  Arch_EnableInterrupts();
end;

{ ── ATA_DetectDiskSize_Pas ──────────────────────────────────────────────── }
procedure ATA_DetectDiskSize_Pas; cdecl; public name 'ATA_DetectDiskSize_Pas';
var
  status: Byte;
  timeout: Integer;
  identify: array[0..255] of Word;
  total: Cardinal;
  i: Integer;
begin
  if not WaitAtaHardware() then Exit;

  OutByte($1F6, $A0);
  OutByte($1F2, 0); OutByte($1F3, 0); OutByte($1F4, 0); OutByte($1F5, 0);
  OutByte($1F7, $EC);

  status := InByte($1F7);
  if status = 0 then Exit;

  timeout := 1000000;
  while timeout > 0 do
  begin
    status := InByte($1F7);
    if (status and $80) = 0 then Break;
    Dec(timeout);
  end;
  if (timeout <= 0) or ((status and $01) <> 0) then Exit;

  while True do
  begin
    status := InByte($1F7);
    if (status and $01) <> 0 then Exit;
    if (status and $08) <> 0 then Break;
  end;

  for i := 0 to 255 do identify[i] := InWord($1F0);

  total := Cardinal(identify[60]) or (Cardinal(identify[61]) shl 16);
  if total > 0 then g_detectedSectors := total;
end;

{ ── ATA_IsLbaInRange_Pas ────────────────────────────────────────────────── }
function ATA_IsLbaInRange_Pas(lba: Cardinal; hwLockVar: PCardinal): Byte; cdecl;
    public name 'ATA_IsLbaInRange_Pas';
var irq: Byte;
begin
  irq := LockAcquireSafe(hwLockVar);
  if g_detectedSectors = 0 then ATA_DetectDiskSize_Pas();
  LockReleaseSafe(hwLockVar, irq);

  if g_detectedSectors <> 0 then
  begin
    if lba < g_detectedSectors then Result := 1 else Result := 0;
  end
  else
  begin
    if lba <= $FFFFFF then Result := 1 else Result := 0;
  end;
end;

{ ── ATA_ReadSectorRaw_Pas ───────────────────────────────────────────────── }
procedure ATA_ReadSectorRaw_Pas(lba: Cardinal; buffer: PByte); cdecl;
    public name 'ATA_ReadSectorRaw_Pas';
var
  status: Byte;
  ptr: PWord;
  i: Integer;
begin
  OutByte($1F6, Byte($E0 or ((lba shr 24) and $0F)));

  if not WaitAtaHardware() then
  begin
    Term_SetColor($00FF0000);
    PrintMsg('[!] ATA HW Read Error: Drive Select Timeout!'#13#10);
    Term_SetColor($00FFFFFF);
    Exit;
  end;

  OutByte($1F2, 1);
  OutByte($1F3, Byte(lba and $FF));
  OutByte($1F4, Byte((lba shr 8) and $FF));
  OutByte($1F5, Byte((lba shr 16) and $FF));
  OutByte($1F7, $20);

  while True do
  begin
    status := InByte($1F7);
    if (status and $80) <> 0 then Continue;
    if ((status and $01) <> 0) or ((status and $20) <> 0) then
    begin
      Term_SetColor($00FF0000);
      PrintMsg('[!] ATA HW Read Error!'#13#10);
      Term_SetColor($00FFFFFF);
      Exit;
    end;
    if (status and $08) <> 0 then Break;
  end;

  ptr := PWord(buffer);
  for i := 0 to 255 do begin ptr^ := InWord($1F0); Inc(ptr); end;
end;

{ ── ATA_WriteSectorRaw_Pas ──────────────────────────────────────────────── }
procedure ATA_WriteSectorRaw_Pas(lba: Cardinal; buffer: PByte); cdecl;
    public name 'ATA_WriteSectorRaw_Pas';
var
  status: Byte;
  ptr: PWord;
  i: Integer;
begin
  if not WaitAtaHardware() then Exit;

  OutByte($1F6, Byte($E0 or ((lba shr 24) and $0F)));

  if not WaitAtaHardware() then
  begin
    Term_SetColor($00FF0000);
    PrintMsg('[!] ATA HW Write Error: Drive Select Timeout!'#13#10);
    Term_SetColor($00FFFFFF);
    Exit;
  end;

  OutByte($1F2, 1);
  OutByte($1F3, Byte(lba and $FF));
  OutByte($1F4, Byte((lba shr 8) and $FF));
  OutByte($1F5, Byte((lba shr 16) and $FF));
  OutByte($1F7, $30);

  while True do
  begin
    status := InByte($1F7);
    if (status and $80) <> 0 then Continue;
    if ((status and $01) <> 0) or ((status and $20) <> 0) then
    begin
      Term_SetColor($00FF0000);
      PrintMsg('[!] ATA HW Write error: DRQ Timeout!'#13#10);
      Term_SetColor($00FFFFFF);
      Exit;
    end;
    if (status and $08) <> 0 then Break;
  end;

  ptr := PWord(buffer);
  for i := 0 to 255 do begin OutWord($1F0, ptr^); Inc(ptr); end;

  OutByte($1F7, $E7);

  while True do
  begin
    status := InByte($1F7);
    if (status and $80) <> 0 then Continue;
    if ((status and $01) <> 0) or ((status and $20) <> 0) then
    begin
      Term_SetColor($00FF0000);
      PrintMsg('[!] ATA HW Write error: Platter write/flush failed!'#13#10);
      Term_SetColor($00FFFFFF);
      Exit;
    end;
    Break;
  end;
end;

{ ── ATA_FlushCacheRaw_Pas ───────────────────────────────────────────────── }
procedure ATA_FlushCacheRaw_Pas; cdecl; public name 'ATA_FlushCacheRaw_Pas';
var status: Byte;
begin
  OutByte($1F7, $E7);
  while True do
  begin
    status := InByte($1F7);
    if (status and $80) = 0 then Break;
    if (status and $01) <> 0 then
    begin
      Term_SetColor($00FF0000);
      PrintMsg('[!] ATA HW Write error: Cache flush failed!'#13#10);
      Term_SetColor($00FFFFFF);
      Exit;
    end;
  end;
end;

end.
