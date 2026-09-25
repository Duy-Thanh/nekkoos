{
  =========================================================================
  NekkoOS — sudo_dispatch.pas
  Full port of Sudo.cs (Dispatch + HandleBuiltin).
  =========================================================================
}
unit sudo_dispatch;

{$mode objfpc}
{$h+}
{$inline on}
{$TYPEINFO OFF}

interface

{ Dispatch syscall 94 (sudo). Returns 0 always (RSP managed by C# wrapper).
  Parameters mirror Sudo.Dispatch(id, ctx*):
    id  — caller thread ID
    ctx — pointer to RegisterContext (opaque; we call ArchCtx helpers)
}
function Sudo_Dispatch_Pas(id: Integer; ctx: Pointer): Integer; cdecl;

{ Set global function pointers needed by sudo_dispatch.
  All pointers are C# [UnmanagedCallersOnly] exports. }
procedure Sudo_SetCallbacks_Pas(
  getArg1Fn:       Pointer;   { function(ctx): QWord }
  getArg2Fn:       Pointer;
  getArg3Fn:       Pointer;
  getArg4Fn:       Pointer;
  setRetFn:        Pointer;   { procedure(ctx, val: QWord) }
  isValidPtrFn:    Pointer;   { function(tid, addr, pml4, totPages: QWord): Byte }
  getThreadUidFn:  Pointer;   { function(tid: Integer): Cardinal }
  getThreadGidFn:  Pointer;   { function(tid: Integer): Cardinal }
  setThreadUidFn:  Pointer;   { procedure(tid: Integer; uid: Cardinal) }
  setThreadGidFn:  Pointer;   { procedure(tid: Integer; gid: Cardinal) }
  getAddrSpaceFn:  Pointer;   { function(tid: Integer): QWord }
  getTotalPagesFn: Pointer;   { function: QWord }
  heapFreeFn:      Pointer;   { procedure(ptr: Pointer) }
  enableIrqFn:     Pointer;   { procedure }
  fat16ReadFn:     Pointer;   { function(name, size*, threadId): Pointer }
  fat16CdFn:       Pointer;   { procedure(path, threadId) }
  fat16ListFn:     Pointer;   { function(buf, cap, threadId): Byte }
  fat16WriteFn:    Pointer;   { function(path, buf, len, threadId): Integer }
  fat16MkdirFn:    Pointer;   { function(path, threadId): Integer }
  fat16RmFn:       Pointer;   { function(path, threadId): Integer }
  fat16RmdirFn:    Pointer;   { function(path, threadId): Integer }
  fat16ChmodFn:    Pointer;   { function(path, mode, threadId): Integer }
  fat16ChownFn:    Pointer;   { function(path, owner, threadId): Integer }
  peLoadRunFn:     Pointer;   { procedure(raw, isFg, jailed, root, name, prio) }
  sha256Fn:        Pointer;   { procedure(input, len, out) }
  hexToBytesFn:    Pointer;   { function(hex, out, maxLen): Integer }
  bytesToHexFn:    Pointer;   { procedure(bytes, len, out) }
  constEqFn:       Pointer;   { function(a, b, len): Byte }
  zeroCharFn:      Pointer;   { procedure(buf, len) }
  zeroByteFn:      Pointer    { procedure(buf, len) }
); cdecl;

implementation

uses arch_interface, libc, passwd_parser, kerncrypto;

{ ── Terminal (external) ─────────────────────────────────────────────────── }
procedure Term_SetColor(color: Cardinal); cdecl; external name 'Terminal_SetColor_Pas';
procedure Term_Print(str: PWord); cdecl; external name 'Terminal_Print_Pas';
procedure Term_DrawChar(c: Word); cdecl; external name 'Terminal_DrawChar_Pas';

{ ── Callback function-pointer types ────────────────────────────────────── }
type
  TGetArg       = function(ctx: Pointer): QWord; cdecl;
  TSetRet       = procedure(ctx: Pointer; val: QWord); cdecl;
  TIsValidPtr   = function(tid: Integer; addr, pml4, totPages: QWord): Byte; cdecl;
  TGetTid       = function(tid: Integer): Cardinal; cdecl;
  TSetTid       = procedure(tid: Integer; val: Cardinal); cdecl;
  TGetAddrSpace = function(tid: Integer): QWord; cdecl;
  TGetTotal     = function: QWord; cdecl;
  THeapFree     = procedure(ptr: Pointer); cdecl;
  TEnableIrq    = procedure; cdecl;
  TFat16Read    = function(name: PWord; sizeOut: PCardinal; threadId: Integer): Pointer; cdecl;
  TFat16Cd      = procedure(path: PWord; threadId: Integer); cdecl;
  TFat16List    = function(buf: PWord; cap: Integer; threadId: Integer): Byte; cdecl;
  TFat16Write   = function(path: PWord; buf: PByte; len: Cardinal; threadId: Integer): Integer; cdecl;
  TFat16Mkdir   = function(path: PWord; threadId: Integer): Integer; cdecl;
  TFat16Rm      = function(path: PWord; threadId: Integer): Integer; cdecl;
  TFat16Rmdir   = function(path: PWord; threadId: Integer): Integer; cdecl;
  TFat16Chmod   = function(path: PWord; mode: Cardinal; threadId: Integer): Integer; cdecl;
  TFat16Chown   = function(path: PWord; owner: PWord; threadId: Integer): Integer; cdecl;
  TPeLoadRun    = procedure(raw: PByte; isFg, jailed, root: Byte; name: PWord; prio: Byte); cdecl;
  TSha256       = procedure(input: PByte; len: QWord; out_: PByte); cdecl;
  THexToBytes   = function(hex: PWord; out_: PByte; maxLen: Integer): Integer; cdecl;
  TBytesToHex   = procedure(bytes: PByte; len: Integer; out_: PWord); cdecl;
  TConstEq      = function(a, b: PWord; len: Integer): Byte; cdecl;
  TZeroChar     = procedure(buf: PWord; len: Integer); cdecl;
  TZeroByte     = procedure(buf: PByte; len: Integer); cdecl;

{ ── Global callbacks ────────────────────────────────────────────────────── }
var
  cb_GetArg1, cb_GetArg2, cb_GetArg3, cb_GetArg4: TGetArg;
  cb_SetRet:       TSetRet;
  cb_IsValidPtr:   TIsValidPtr;
  cb_GetUid:       TGetTid;
  cb_GetGid:       TGetTid;
  cb_SetUid:       TSetTid;
  cb_SetGid:       TSetTid;
  cb_GetAddrSpace: TGetAddrSpace;
  cb_GetTotalPages:TGetTotal;
  cb_HeapFree:     THeapFree;
  cb_EnableIrq:    TEnableIrq;
  cb_Fat16Read:    TFat16Read;
  cb_Fat16Cd:      TFat16Cd;
  cb_Fat16List:    TFat16List;
  cb_Fat16Write:   TFat16Write;
  cb_Fat16Mkdir:   TFat16Mkdir;
  cb_Fat16Rm:      TFat16Rm;
  cb_Fat16Rmdir:   TFat16Rmdir;
  cb_Fat16Chmod:   TFat16Chmod;
  cb_Fat16Chown:   TFat16Chown;
  cb_PeLoadRun:    TPeLoadRun;
  cb_Sha256:       TSha256;
  cb_HexToBytes:   THexToBytes;
  cb_BytesToHex:   TBytesToHex;
  cb_ConstEq:      TConstEq;
  cb_ZeroChar:     TZeroChar;
  cb_ZeroByte:     TZeroByte;

{ ── Sudo_SetCallbacks_Pas ───────────────────────────────────────────────── }
procedure Sudo_SetCallbacks_Pas(
  getArg1Fn, getArg2Fn, getArg3Fn, getArg4Fn,
  setRetFn, isValidPtrFn,
  getThreadUidFn, getThreadGidFn, setThreadUidFn, setThreadGidFn,
  getAddrSpaceFn, getTotalPagesFn,
  heapFreeFn, enableIrqFn,
  fat16ReadFn, fat16CdFn, fat16ListFn, fat16WriteFn,
  fat16MkdirFn, fat16RmFn, fat16RmdirFn, fat16ChmodFn, fat16ChownFn,
  peLoadRunFn, sha256Fn, hexToBytesFn, bytesToHexFn,
  constEqFn, zeroCharFn, zeroByteFn: Pointer
); cdecl; public name 'Sudo_SetCallbacks_Pas';
begin
  cb_GetArg1      := TGetArg(getArg1Fn);
  cb_GetArg2      := TGetArg(getArg2Fn);
  cb_GetArg3      := TGetArg(getArg3Fn);
  cb_GetArg4      := TGetArg(getArg4Fn);
  cb_SetRet       := TSetRet(setRetFn);
  cb_IsValidPtr   := TIsValidPtr(isValidPtrFn);
  cb_GetUid       := TGetTid(getThreadUidFn);
  cb_GetGid       := TGetTid(getThreadGidFn);
  cb_SetUid       := TSetTid(setThreadUidFn);
  cb_SetGid       := TSetTid(setThreadGidFn);
  cb_GetAddrSpace := TGetAddrSpace(getAddrSpaceFn);
  cb_GetTotalPages:= TGetTotal(getTotalPagesFn);
  cb_HeapFree     := THeapFree(heapFreeFn);
  cb_EnableIrq    := TEnableIrq(enableIrqFn);
  cb_Fat16Read    := TFat16Read(fat16ReadFn);
  cb_Fat16Cd      := TFat16Cd(fat16CdFn);
  cb_Fat16List    := TFat16List(fat16ListFn);
  cb_Fat16Write   := TFat16Write(fat16WriteFn);
  cb_Fat16Mkdir   := TFat16Mkdir(fat16MkdirFn);
  cb_Fat16Rm      := TFat16Rm(fat16RmFn);
  cb_Fat16Rmdir   := TFat16Rmdir(fat16RmdirFn);
  cb_Fat16Chmod   := TFat16Chmod(fat16ChmodFn);
  cb_Fat16Chown   := TFat16Chown(fat16ChownFn);
  cb_PeLoadRun    := TPeLoadRun(peLoadRunFn);
  cb_Sha256       := TSha256(sha256Fn);
  cb_HexToBytes   := THexToBytes(hexToBytesFn);
  cb_BytesToHex   := TBytesToHex(bytesToHexFn);
  cb_ConstEq      := TConstEq(constEqFn);
  cb_ZeroChar     := TZeroChar(zeroCharFn);
  cb_ZeroByte     := TZeroByte(zeroByteFn);
end;

{ ── Helper: wide-char print ─────────────────────────────────────────────── }
procedure WPrint(msg: PChar);
var buf: array[0..127] of Word; i: Integer;
begin
  i := 0;
  while (msg[i] <> #0) and (i < 127) do begin buf[i] := Ord(msg[i]); Inc(i); end;
  buf[i] := 0;
  Term_Print(@buf[0]);
end;

{ ── HandleBuiltin ───────────────────────────────────────────────────────── }
procedure HandleBuiltin(id, callerThreadId: Integer; appName: PWord;
    sudoWriteContent: PByte; sudoWriteContentLen: Cardinal);
var
  listBuf:  array[0..2047] of Word;
  modeStr:  array[0..15]   of Word;
  pathBuf:  array[0..255]  of Word;
  ownerBuf: array[0..31]   of Word;
  catBuf:   PByte;
  catSize:  Cardinal;
  p: PWord;
  rest: PWord;
  k: Cardinal;
  c: Word;
  r, wr: Integer;
  mode: Cardinal;
  ok: Byte;

  vLs:    array[0..2]  of Word;
  vLl:    array[0..2]  of Word;
  vCd:    array[0..3]  of Word;
  vCat:   array[0..4]  of Word;
  vWrite: array[0..6]  of Word;
  vRm:    array[0..3]  of Word;
  vMkdir: array[0..6]  of Word;
  vRmdir: array[0..6]  of Word;
  vChmod: array[0..6]  of Word;
  vChown: array[0..6]  of Word;
begin
  { Build prefix strings (UTF-16 LE) }
  vLs[0]:=$006C; vLs[1]:=$0073; vLs[2]:=0;
  vLl[0]:=$006C; vLl[1]:=$006C; vLl[2]:=0;
  vCd[0]:=$0063; vCd[1]:=$0064; vCd[2]:=$0020; vCd[3]:=0;
  vCat[0]:=$0063; vCat[1]:=$0061; vCat[2]:=$0074; vCat[3]:=$0020; vCat[4]:=0;
  vWrite[0]:=$0077; vWrite[1]:=$0072; vWrite[2]:=$0069; vWrite[3]:=$0074;
  vWrite[4]:=$0065; vWrite[5]:=$0020; vWrite[6]:=0;
  vRm[0]:=$0072; vRm[1]:=$006D; vRm[2]:=$0020; vRm[3]:=0;
  vMkdir[0]:=$006D; vMkdir[1]:=$006B; vMkdir[2]:=$0064; vMkdir[3]:=$0069;
  vMkdir[4]:=$0072; vMkdir[5]:=$0020; vMkdir[6]:=0;
  vRmdir[0]:=$0072; vRmdir[1]:=$006D; vRmdir[2]:=$0064; vRmdir[3]:=$0069;
  vRmdir[4]:=$0072; vRmdir[5]:=$0020; vRmdir[6]:=0;
  vChmod[0]:=$0063; vChmod[1]:=$0068; vChmod[2]:=$006D; vChmod[3]:=$006F;
  vChmod[4]:=$0064; vChmod[5]:=$0020; vChmod[6]:=0;
  vChown[0]:=$0063; vChown[1]:=$0068; vChown[2]:=$006F; vChown[3]:=$0077;
  vChown[4]:=$006E; vChown[5]:=$0020; vChown[6]:=0;

  if (StrCmp(@vLs[0], appName) <> 0) or (StrCmp(@vLl[0], appName) <> 0) then
  begin
    ok := cb_Fat16List(@listBuf[0], 2048, callerThreadId);
    if ok <> 0 then
    begin
      Term_SetColor($00FFFFFF);
      Term_Print(@listBuf[0]);
    end
    else
    begin
      Term_SetColor($00FF0000);
      WPrint('[!] sudo ls: Failed to list directory.'#13#10);
    end;
  end
  else if StrStartsWith(appName, @vCd[0]) <> 0 then
  begin
    p := appName; Inc(p, 3);
    if p^ = 0 then
    begin
      Term_SetColor($00FF0000); WPrint('[!] Usage: sudo cd <path>'#13#10);
    end
    else cb_Fat16Cd(p, callerThreadId);
  end
  else if StrStartsWith(appName, @vWrite[0]) <> 0 then
  begin
    p := appName; Inc(p, 6);
    if p^ = 0 then
    begin Term_SetColor($00FF0000); WPrint('[!] Usage: sudo write <path>'#13#10); end
    else if sudoWriteContent = nil then
    begin Term_SetColor($00FF0000); WPrint('[!] sudo write: No content buffer.'#13#10); end
    else
    begin
      wr := cb_Fat16Write(p, sudoWriteContent, sudoWriteContentLen, callerThreadId);
      if wr = 1 then begin Term_SetColor($0000FF00); WPrint('[+] File written successfully!'#13#10); end
      else begin Term_SetColor($00FF0000); WPrint('[!] Failed! Disk Full, Access Denied or Directory.'#13#10); end;
    end;
  end
  else if StrStartsWith(appName, @vCat[0]) <> 0 then
  begin
    p := appName; Inc(p, 4);
    if p^ = 0 then
    begin Term_SetColor($00FF0000); WPrint('[!] Usage: sudo cat <path>'#13#10); end
    else
    begin
      catSize := 0;
      catBuf := cb_Fat16Read(p, @catSize, callerThreadId);
      if catBuf <> nil then
      begin
        if catSize > 16384 then
        begin Term_SetColor($00FF0000); WPrint('[!] File too large (>16KB). Refusing to print.'#13#10); end
        else
        begin
          Term_SetColor($00FFFFFF);
          for k := 0 to catSize - 1 do
          begin
            c := catBuf[k];
            if c = 13 then Continue;
            if IsPrintableChar(c) <> 0 then Term_DrawChar(c)
            else Term_DrawChar(Ord('.'));
          end;
          WPrint(#13#10);
        end;
        cb_HeapFree(catBuf);
      end
      else begin Term_SetColor($00FF0000); WPrint('[!] sudo cat: File not found.'#13#10); end;
    end;
  end
  else if StrStartsWith(appName, @vMkdir[0]) <> 0 then
  begin
    p := appName; Inc(p, 6);
    if p^ = 0 then begin Term_SetColor($00FF0000); WPrint('[!] Usage: sudo mkdir <path>'#13#10); end
    else
    begin
      r := cb_Fat16Mkdir(p, callerThreadId);
      if r = 1 then begin Term_SetColor($0000FF00); WPrint('[+] Directory Created Successfully!'#13#10); end
      else begin Term_SetColor($00FF0000); WPrint('[!] Failed! Already exists or Disk Full.'#13#10); end;
    end;
  end
  else if StrStartsWith(appName, @vRm[0]) <> 0 then
  begin
    p := appName; Inc(p, 3);
    if p^ = 0 then begin Term_SetColor($00FF0000); WPrint('[!] Usage: sudo rm <path>'#13#10); end
    else
    begin
      r := cb_Fat16Rm(p, callerThreadId);
      if r = 1 then begin Term_SetColor($0000FF00); WPrint('[+] File Removed!'#13#10); end
      else if r = 2 then begin Term_SetColor($00FF0000); WPrint('[!] Cannot use RM on a Directory!'#13#10); end
      else begin Term_SetColor($00FF0000); WPrint('[!] File Not Found.'#13#10); end;
    end;
  end
  else if StrStartsWith(appName, @vRmdir[0]) <> 0 then
  begin
    p := appName; Inc(p, 6);
    if p^ = 0 then begin Term_SetColor($00FF0000); WPrint('[!] Usage: sudo rmdir <path>'#13#10); end
    else
    begin
      r := cb_Fat16Rmdir(p, callerThreadId);
      if r = 1 then begin Term_SetColor($0000FF00); WPrint('[+] Directory obliterated!'#13#10); end
      else if r = 2 then begin Term_SetColor($00FF0000); WPrint('[!] Target is a File. Use sudo rm.'#13#10); end
      else begin Term_SetColor($00FF0000); WPrint('[!] Directory Not Found.'#13#10); end;
    end;
  end
  else if StrStartsWith(appName, @vChmod[0]) <> 0 then
  begin
    rest := appName; Inc(rest, 6);
    if SplitTwoArgs(rest, @modeStr[0], 16, @pathBuf[0], 256) = 0 then
    begin Term_SetColor($00FF0000); WPrint('[!] Usage: sudo chmod <mode> <path>'#13#10); end
    else
    begin
      mode := OctalStrToUInt(@modeStr[0]);
      r := cb_Fat16Chmod(@pathBuf[0], mode, callerThreadId);
      if r = 1 then begin Term_SetColor($0000FF00); WPrint('[+] Permissions Changed!'#13#10); end
      else begin Term_SetColor($00FF0000); WPrint('[!] Failed! Not Found.'#13#10); end;
    end;
  end
  else if StrStartsWith(appName, @vChown[0]) <> 0 then
  begin
    rest := appName; Inc(rest, 6);
    if SplitTwoArgs(rest, @ownerBuf[0], 32, @pathBuf[0], 256) = 0 then
    begin Term_SetColor($00FF0000); WPrint('[!] Usage: sudo chown <uid>:<gid> <path>'#13#10); end
    else
    begin
      r := cb_Fat16Chown(@pathBuf[0], @ownerBuf[0], callerThreadId);
      if r = 1 then begin Term_SetColor($0000FF00); WPrint('[+] Ownership Changed!'#13#10); end
      else begin Term_SetColor($00FF0000); WPrint('[!] Failed! Not Found.'#13#10); end;
    end;
  end;
end;

{ ── Sudo_Dispatch_Pas ───────────────────────────────────────────────────── }
function Sudo_Dispatch_Pas(id: Integer; ctx: Pointer): Integer; cdecl;
  public name 'Sudo_Dispatch_Pas';
const
  PASSWD_DBG_ADDR = $8000;
var
  arg1, arg2, arg3, arg4: QWord;
  pml4Phys, totalPages: QWord;
  appName:   PWord;
  inputPass: PWord;
  sudoWriteContent: PByte;
  sudoWriteContentLen: Cardinal;
  callerThreadForSudo: Integer;
  callerUidForSudo: Cardinal;
  passBuf: PByte;
  passSize: Cardinal;
  i: Integer;
  lineUser: array[0..31] of Word;
  lineSalt: array[0..63] of Word;
  lineHash: array[0..79] of Word;
  lineUID:  array[0..15] of Word;
  saltBytes: array[0..31] of Byte;
  hashInput: array[0..63] of Byte;
  computedHash: array[0..31] of Byte;
  computedHashHex: array[0..79] of Word;
  matchedUser: array[0..31] of Word;
  lineUidVal: Cardinal;
  saltLen, passLen, hashInputLen: Integer;
  passOk: Byte;
  sudoBuf: PByte;
  sudoSize: Cardinal;
  inSudoers: Byte;
  sudoOrigUid, sudoOrigGid: Cardinal;
  appFileSize: Cardinal;
  rawData: PByte;
  foundAccount: Boolean;
  ret: Integer;
  isBuiltin: Boolean;

  { UTF-16 constants for FAT16 paths }
  dirRoot:      array[0..1]  of Word;
  dirEtc:       array[0..3]  of Word;
  passFileName: array[0..6]  of Word;
  sudoersFile:  array[0..7]  of Word;

  vLs:    array[0..2]  of Word;
  vLl:    array[0..2]  of Word;
  vCd:    array[0..3]  of Word;
  vCat:   array[0..4]  of Word;
  vWrite: array[0..6]  of Word;
  vRm:    array[0..3]  of Word;
  vMkdir: array[0..6]  of Word;
  vRmdir: array[0..6]  of Word;
  vChmod: array[0..6]  of Word;
  vChown: array[0..6]  of Word;
begin
  Result := 0;

  arg1 := cb_GetArg1(ctx);
  arg2 := cb_GetArg2(ctx);
  pml4Phys   := cb_GetAddrSpace(id);
  totalPages := cb_GetTotalPages();

  if (arg1 = 0) or (cb_IsValidPtr(id, arg1, pml4Phys, totalPages) = 0)
  or (arg2 = 0) or (cb_IsValidPtr(id, arg2, pml4Phys, totalPages) = 0) then
  begin
    cb_SetRet(ctx, 0);
    Exit;
  end;

  appName   := PWord(arg1);
  inputPass := PWord(arg2);

  arg3 := cb_GetArg3(ctx);
  arg4 := cb_GetArg4(ctx);

  if (arg3 <> 0) and (cb_IsValidPtr(id, arg3, pml4Phys, totalPages) <> 0) then
    sudoWriteContent := PByte(arg3)
  else
    sudoWriteContent := nil;
  sudoWriteContentLen := Cardinal(arg4);

  callerThreadForSudo := id;
  callerUidForSudo    := cb_GetUid(id);

  PCardinal(PASSWD_DBG_ADDR)^ := 1;
  cb_EnableIrq();

  { UTF-16 path constants }
  dirRoot[0] := Ord('\'); dirRoot[1] := 0;
  dirEtc[0] := Ord('E'); dirEtc[1] := Ord('T'); dirEtc[2] := Ord('C'); dirEtc[3] := 0;
  passFileName[0]:=Ord('P'); passFileName[1]:=Ord('A'); passFileName[2]:=Ord('S');
  passFileName[3]:=Ord('S'); passFileName[4]:=Ord('W'); passFileName[5]:=Ord('D');
  passFileName[6]:=0;
  sudoersFile[0]:=Ord('S'); sudoersFile[1]:=Ord('U'); sudoersFile[2]:=Ord('D');
  sudoersFile[3]:=Ord('O'); sudoersFile[4]:=Ord('E'); sudoersFile[5]:=Ord('R');
  sudoersFile[6]:=Ord('S'); sudoersFile[7]:=0;

  { Builtin prefix strings }
  vLs[0]:=$006C; vLs[1]:=$0073; vLs[2]:=0;
  vLl[0]:=$006C; vLl[1]:=$006C; vLl[2]:=0;
  vCd[0]:=$0063; vCd[1]:=$0064; vCd[2]:=$0020; vCd[3]:=0;
  vCat[0]:=$0063; vCat[1]:=$0061; vCat[2]:=$0074; vCat[3]:=$0020; vCat[4]:=0;
  vWrite[0]:=$0077; vWrite[1]:=$0072; vWrite[2]:=$0069; vWrite[3]:=$0074;
  vWrite[4]:=$0065; vWrite[5]:=$0020; vWrite[6]:=0;
  vRm[0]:=$0072; vRm[1]:=$006D; vRm[2]:=$0020; vRm[3]:=0;
  vMkdir[0]:=$006D; vMkdir[1]:=$006B; vMkdir[2]:=$0064; vMkdir[3]:=$0069;
  vMkdir[4]:=$0072; vMkdir[5]:=$0020; vMkdir[6]:=0;
  vRmdir[0]:=$0072; vRmdir[1]:=$006D; vRmdir[2]:=$0064; vRmdir[3]:=$0069;
  vRmdir[4]:=$0072; vRmdir[5]:=$0020; vRmdir[6]:=0;
  vChmod[0]:=$0063; vChmod[1]:=$0068; vChmod[2]:=$006D; vChmod[3]:=$006F;
  vChmod[4]:=$0064; vChmod[5]:=$0020; vChmod[6]:=0;
  vChown[0]:=$0063; vChown[1]:=$0068; vChown[2]:=$006F; vChown[3]:=$0077;
  vChown[4]:=$006E; vChown[5]:=$0020; vChown[6]:=0;

  cb_Fat16Cd(@dirRoot[0], 0);
  cb_Fat16Cd(@dirEtc[0], 0);
  passSize := 0;
  passBuf  := cb_Fat16Read(@passFileName[0], @passSize, 0);
  cb_Fat16Cd(@dirRoot[0], 0);
  PCardinal(PASSWD_DBG_ADDR)^ := 2;

  ret := 0;
  foundAccount := False;

  if (passBuf <> nil) and (passSize > 0) then
  begin
    i := 0;
    while i < Integer(passSize) do
    begin
      ParsePasswdLine_Pas(PWord(@passBuf[i]), @lineUser[0], 32,
        @lineSalt[0], 64, @lineHash[0], 80, @lineUID[0], 16);
      while (i < Integer(passSize)) and (passBuf[i] <> 10) and (passBuf[i] <> 13) do Inc(i);
      while (i < Integer(passSize)) and ((passBuf[i] = 10) or (passBuf[i] = 13)) do Inc(i);

      lineUidVal := Atoi(@lineUID[0]);

      if (lineUser[0] <> 0) and (lineUidVal = callerUidForSudo) then
      begin
        PCardinal(PASSWD_DBG_ADDR)^ := 3;
        StrCpyLimited(@matchedUser[0], @lineUser[0], 32);

        saltLen := cb_HexToBytes(@lineSalt[0], @saltBytes[0], 32);
        passLen := 0;
        while inputPass[passLen] <> 0 do Inc(passLen);
        PCardinal(PASSWD_DBG_ADDR)^ := 4;

        hashInputLen := 0;
        for i := 0 to saltLen - 1 do begin hashInput[hashInputLen] := saltBytes[i]; Inc(hashInputLen); end;
        for i := 0 to passLen - 1 do begin hashInput[hashInputLen] := Byte(inputPass[i]); Inc(hashInputLen); end;

        cb_Sha256(@hashInput[0], hashInputLen, @computedHash[0]);
        cb_BytesToHex(@computedHash[0], 32, @computedHashHex[0]);

        foundAccount := True;
        passOk := cb_ConstEq(@computedHashHex[0], @lineHash[0], 64);
        if passOk <> 0 then
          PCardinal(PASSWD_DBG_ADDR)^ := $105
        else
          PCardinal(PASSWD_DBG_ADDR)^ := 5;

        cb_ZeroChar(@lineSalt[0], 64); cb_ZeroChar(@lineHash[0], 80);
        cb_ZeroByte(@saltBytes[0], 32); cb_ZeroByte(@hashInput[0], 64);
        cb_ZeroByte(@computedHash[0], 32); cb_ZeroChar(@computedHashHex[0], 80);

        if passOk = 0 then
        begin
          cb_HeapFree(passBuf);
          PCardinal(PASSWD_DBG_ADDR)^ := 6;
          cb_SetRet(ctx, 0);
          Exit;
        end;

        { Check sudoers }
        cb_Fat16Cd(@dirEtc[0], 0);
        sudoSize := 0;
        sudoBuf := cb_Fat16Read(@sudoersFile[0], @sudoSize, 0);
        cb_Fat16Cd(@dirRoot[0], 0);
        inSudoers := 0;
        if (sudoBuf <> nil) and (sudoSize > 0) then
        begin
          inSudoers := SudoersContains_Pas(sudoBuf, sudoSize, @matchedUser[0]);
          cb_HeapFree(sudoBuf);
        end;
        PCardinal(PASSWD_DBG_ADDR)^ := 7;

        if inSudoers = 0 then
        begin
          cb_HeapFree(passBuf);
          cb_SetRet(ctx, 2);
          Exit;
        end;

        { Check builtin }
        isBuiltin :=
          (StrStartsWith(appName, @vCat[0])   <> 0) or
          (StrStartsWith(appName, @vRm[0])    <> 0) or
          (StrStartsWith(appName, @vMkdir[0]) <> 0) or
          (StrStartsWith(appName, @vRmdir[0]) <> 0) or
          (StrStartsWith(appName, @vChmod[0]) <> 0) or
          (StrStartsWith(appName, @vChown[0]) <> 0) or
          (StrCmp(appName, @vLs[0])           <> 0) or
          (StrCmp(appName, @vLl[0])           <> 0) or
          (StrStartsWith(appName, @vCd[0])    <> 0) or
          (StrStartsWith(appName, @vWrite[0]) <> 0);

        if isBuiltin then
        begin
          PCardinal(PASSWD_DBG_ADDR)^ := 9;
          sudoOrigUid := cb_GetUid(id);
          sudoOrigGid := cb_GetGid(id);
          cb_SetUid(id, 0); cb_SetGid(id, 0);

          HandleBuiltin(id, callerThreadForSudo, appName,
            sudoWriteContent, sudoWriteContentLen);

          cb_SetUid(id, sudoOrigUid); cb_SetGid(id, sudoOrigGid);
          Term_SetColor($00FFFFFF);
          PCardinal(PASSWD_DBG_ADDR)^ := 12;
          cb_HeapFree(passBuf);
          PCardinal(PASSWD_DBG_ADDR)^ := 13;
          cb_SetRet(ctx, 1);
          Exit;
        end;

        { Run external app }
        appFileSize := 0;
        rawData := cb_Fat16Read(appName, @appFileSize, callerThreadForSudo);
        if (rawData = nil) or (rawData[0] <> Ord('M')) or (rawData[1] <> Ord('Z')) then
        begin
          if rawData <> nil then cb_HeapFree(rawData);
          cb_HeapFree(passBuf);
          cb_SetRet(ctx, 3);
          Exit;
        end;

        cb_PeLoadRun(rawData, 0, 0, 1, appName, 1);
        cb_HeapFree(passBuf);
        cb_SetRet(ctx, 1);
        Exit;
      end; { lineUidVal match }
    end; { while i }

    if not foundAccount then cb_HeapFree(passBuf);
  end;

  cb_SetRet(ctx, 0);
end;

end.
