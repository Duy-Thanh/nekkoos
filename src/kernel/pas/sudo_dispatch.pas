{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: sudo_dispatch - syscall 94, run one command as root.
  PORTED FROM: src/kernel/Sudo.cs.

  The caller proves who it is by password. The kernel looks the caller up in
  ETC/PASSWD by UID, checks sha256(salt || password) against the stored hash
  in constant time, then checks the user is listed in ETC/SUDOERS. Only then
  is the command run: either one of the filesystem builtins (relayed to the
  ring-3 FAT16 daemon with the caller's UID/GID lifted to 0 for the one round
  trip and restored right after), or an executable launched as root.

  Argument registers (see syscall_impl): 1 = command, 2 = password,
  3 = write payload (optional), 4 = payload length.
  Return codes written to the caller's RAX:
    0 bad arguments / unknown account / wrong password
    1 done
    2 password right, but the user is not in SUDOERS
    3 executable not found or not a PE image
  =========================================================================
}
unit sudo_dispatch;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Dispatch syscall 94. Sets the return value and returns 0; the dispatcher
  must ignore the result (it is not an RSP). }
function Sudo_Handle(id: Integer; ctx: PQWord): Integer;

function Sudo_Dispatch_Pas(id: Integer; ctx: Pointer): Integer; cdecl;
  public name 'Sudo_Dispatch_Pas';

implementation

uses arch_interface, libc, kstring, console, heap, kerncrypto, passwd_parser,
  syscall_security, syscall_impl, pmm, scheduler, fat16_kernel, pe_loader;

const
  RET_DENIED     = 0;
  RET_OK         = 1;
  RET_NOT_SUDOER = 2;
  RET_NO_EXE     = 3;

procedure SayRed(const msg: AnsiString);
begin
  Con_SetColor($00FF0000);
  Con_Print(W(msg));
end;

procedure SayGreen(const msg: AnsiString);
begin
  Con_SetColor($0000FF00);
  Con_Print(W(msg));
end;

function ValidUser(id: Integer; ptr: QWord): Boolean;
begin
  ValidUser := (ptr <> 0) and
    (IsValidUserPtr_Pas(id, ptr, Sched_GetThreadAddrSpaceRaw(id), Pmm_GetTotalPages) <> 0);
end;

{ Wide-character copies of the verb prefixes, built once per call. }
function IsVerb(cmd: PWord; const verb: AnsiString): Boolean;
begin
  IsVerb := StrStartsWith(cmd, W(verb)) <> 0;
end;

function IsExact(cmd: PWord; const verb: AnsiString): Boolean;
begin
  IsExact := StrCmp(cmd, W(verb)) <> 0;
end;

function IsBuiltin(appName: PWord): Boolean;
begin
  IsBuiltin := IsVerb(appName, 'cat ') or IsVerb(appName, 'rm ') or
               IsVerb(appName, 'mkdir ') or IsVerb(appName, 'rmdir ') or
               IsVerb(appName, 'chmod ') or IsVerb(appName, 'chown ') or
               IsExact(appName, 'ls') or IsExact(appName, 'll') or
               IsVerb(appName, 'cd ') or IsVerb(appName, 'write ');
end;

{ ── Filesystem builtins, run with the caller's identity lifted to root ───── }

procedure HandleBuiltin(callerThread: Integer; appName: PWord;
  writeContent: PByte; writeLen: Cardinal);
var
  listBuf: array[0..2047] of Word;
  modeStr: array[0..15] of Word;
  ownerStr: array[0..31] of Word;
  pathBuf: array[0..255] of Word;
  p, rest: PWord;
  catBuf: PByte;
  catSize, k, mode: Cardinal;
  c: Word;
  r, wr: Integer;
begin
  if IsExact(appName, 'ls') or IsExact(appName, 'll') then
  begin
    if Fat16K_ListDir(@listBuf[0], 2048, callerThread) then
    begin
      Con_SetColor($00FFFFFF);
      Con_Print(@listBuf[0]);
    end
    else
      SayRed('[!] sudo ls: Failed to list directory.'#13#10);
  end
  else if IsVerb(appName, 'cd ') then
  begin
    p := appName + 3;
    if p^ = 0 then SayRed('[!] Usage: sudo cd <path>'#13#10)
    else Fat16K_Cd(p, callerThread);
  end
  else if IsVerb(appName, 'write ') then
  begin
    p := appName + 6;
    if p^ = 0 then SayRed('[!] Usage: sudo write <path>'#13#10)
    else if writeContent = nil then SayRed('[!] sudo write: No content buffer provided.'#13#10)
    else
    begin
      wr := Fat16K_WriteFileRelay(p, writeContent, writeLen, callerThread);
      if wr = 1 then SayGreen('[+] File written successfully!'#13#10)
      else SayRed('[!] Failed! Disk Full, Access Denied or File is a Directory!'#13#10);
    end;
  end
  else if IsVerb(appName, 'cat ') then
  begin
    p := appName + 4;
    if p^ = 0 then SayRed('[!] Usage: sudo cat <path>'#13#10)
    else
    begin
      catSize := 0;
      catBuf := Fat16K_ReadFile(p, @catSize, callerThread);
      if catBuf <> nil then
      begin
        if catSize > 16384 then
          SayRed('[!] File too large (>16KB). Refusing to print to prevent Terminal freeze.'#13#10)
        else
        begin
          Con_SetColor($00FFFFFF);
          for k := 0 to catSize - 1 do
          begin
            c := catBuf[k];
            if c = 13 then Continue;
            if IsPrintableChar(c) <> 0 then Con_DrawChar(c)
            else Con_DrawChar(Ord('.'));
          end;
          Con_Print(W(#13#10));
        end;
        Heap_Free(catBuf);
      end
      else
        SayRed('[!] sudo cat: File not found or Access Denied.'#13#10);
    end;
  end
  else if IsVerb(appName, 'mkdir ') then
  begin
    p := appName + 6;
    if p^ = 0 then SayRed('[!] Usage: sudo mkdir <path>'#13#10)
    else
    begin
      r := Fat16K_MakeDir(p, callerThread);
      if r = 1 then SayGreen('[+] Directory Created Successfully!'#13#10)
      else SayRed('[!] Failed! Directory already exists or Disk Full.'#13#10);
    end;
  end
  else if IsVerb(appName, 'rm ') then
  begin
    p := appName + 3;
    if p^ = 0 then SayRed('[!] Usage: sudo rm <path>'#13#10)
    else
    begin
      r := Fat16K_RemoveFile(p, callerThread);
      if r = 1 then SayGreen('[+] File Removed and Clusters Recycled!'#13#10)
      else if r = 2 then SayRed('[!] Cannot use RM on a Directory!'#13#10)
      else SayRed('[!] File Not Found.'#13#10);
    end;
  end
  else if IsVerb(appName, 'rmdir ') then
  begin
    p := appName + 6;
    if p^ = 0 then SayRed('[!] Usage: sudo rmdir <path>'#13#10)
    else
    begin
      r := Fat16K_RemoveDir(p, callerThread);
      if r = 1 then SayGreen('[+] Directory and ALL its contents obliterated recursively!'#13#10)
      else if r = 2 then SayRed('[!] Target is a File. Use ''sudo rm'' instead.'#13#10)
      else SayRed('[!] Directory Not Found.'#13#10);
    end;
  end
  else if IsVerb(appName, 'chmod ') then
  begin
    rest := appName + 6;
    if SplitTwoArgs(rest, @modeStr[0], 16, @pathBuf[0], 256) = 0 then
      SayRed('[!] Usage: sudo chmod <mode> <path>'#13#10)
    else
    begin
      mode := OctalStrToUInt(@modeStr[0]);
      r := Fat16K_Chmod(@pathBuf[0], mode, callerThread);
      if r = 1 then SayGreen('[+] Permissions Changed Successfully!'#13#10)
      else SayRed('[!] Failed! Not Found.'#13#10);
    end;
  end
  else if IsVerb(appName, 'chown ') then
  begin
    rest := appName + 6;
    if SplitTwoArgs(rest, @ownerStr[0], 32, @pathBuf[0], 256) = 0 then
      SayRed('[!] Usage: sudo chown <uid>:<gid> <path>'#13#10)
    else
    begin
      r := Fat16K_Chown(@pathBuf[0], @ownerStr[0], callerThread);
      if r = 1 then SayGreen('[+] Ownership Changed Successfully!'#13#10)
      else SayRed('[!] Failed! Not Found.'#13#10);
    end;
  end;
end;

{ Copy one line of a byte buffer, widened to UTF-16, into `dest`. The PASSWD
  file is bytes but the line parser works on wide characters. The C# version
  handed the byte pointer straight to the parser, which then read two bytes
  per character, so no account ever matched. }
procedure WidenLine(src: PByte; avail: Integer; dest: PWord; cap: Integer);
var
  n: Integer;
begin
  n := 0;
  while (n < avail) and (n < cap - 1) and (src[n] <> 10) and (src[n] <> 13) do
  begin
    dest[n] := src[n];
    Inc(n);
  end;
  dest[n] := 0;
end;

function Sudo_Handle(id: Integer; ctx: PQWord): Integer;
var
  appName, inputPass: PWord;
  writeContent: PByte;
  writeLen: Cardinal;
  callerUid: Cardinal;

  lineWide: array[0..255] of Word;
  lineUser: array[0..31] of Word;
  { 64 hex digits plus the terminator. The C# buffer held exactly 64 and the
    parser keeps cap-1, so the last digit was dropped and every salt decoded
    to 31 bytes; no sudo password could ever verify. }
  lineSalt: array[0..71] of Word;
  lineHash: array[0..79] of Word;
  lineUID: array[0..15] of Word;
  matchedUser: array[0..31] of Word;
  saltBytes: array[0..31] of Byte;
  hashInput: array[0..255] of Byte;
  computed: array[0..31] of Byte;
  computedHex: array[0..79] of Word;

  passBuf, sudoBuf, rawData: PByte;
  passSize, sudoSize, appFileSize: Cardinal;
  i, saltLen, passLen, hashInputLen, k: Integer;
  lineUidVal: Cardinal;
  passOk, inSudoers, foundAccount: Boolean;
  ret: Integer;
  origUid, origGid: Cardinal;
begin
  Sudo_Handle := 0;

  if (not ValidUser(id, Ctx_GetArg(ctx, 1))) or (not ValidUser(id, Ctx_GetArg(ctx, 2))) then
  begin
    Ctx_SetRet(ctx, 0);
    Exit;
  end;

  appName := PWord(Ctx_GetArg(ctx, 1));
  inputPass := PWord(Ctx_GetArg(ctx, 2));

  writeContent := nil;
  if ValidUser(id, Ctx_GetArg(ctx, 3)) then writeContent := PByte(Ctx_GetArg(ctx, 3));
  writeLen := Cardinal(Ctx_GetArg(ctx, 4));

  callerUid := Sched_GetThreadUID(id);
  Arch_EnableInterrupts;

  ret := RET_DENIED;
  foundAccount := False;

  { The kernel keeps its own working directory (override 0 = raw path), so
    reading ETC does not disturb the daemon's idea of the caller's cwd. }
  Fat16K_Cd(W('\'), 0);
  Fat16K_Cd(W('ETC'), 0);
  passSize := 0;
  passBuf := Fat16K_ReadFile(W('PASSWD'), @passSize, 0);
  Fat16K_Cd(W('\'), 0);

  if (passBuf = nil) or (passSize = 0) then
  begin
    Ctx_SetRet(ctx, RET_DENIED);
    Exit;
  end;

  i := 0;
  while i < Integer(passSize) do
  begin
    WidenLine(@passBuf[i], Integer(passSize) - i, @lineWide[0], 256);
    ParsePasswdLine_Pas(@lineWide[0], @lineUser[0], 32, @lineSalt[0], 72,
      @lineHash[0], 80, @lineUID[0], 16);

    while (i < Integer(passSize)) and (passBuf[i] <> 10) and (passBuf[i] <> 13) do Inc(i);
    while (i < Integer(passSize)) and ((passBuf[i] = 10) or (passBuf[i] = 13)) do Inc(i);

    lineUidVal := Atoi(@lineUID[0]);
    if (lineUser[0] = 0) or (lineUidVal <> callerUid) then Continue;

    StrCpyLimited(@matchedUser[0], @lineUser[0], 32);

    { hash = sha256(salt_bytes || password). The salt is stored as hex, but the
      hash covers the decoded bytes, not the hex text. }
    saltLen := HexToBytes(@lineSalt[0], @saltBytes[0], 32);
    passLen := 0;
    while inputPass[passLen] <> 0 do Inc(passLen);
    { 32 bytes of salt plus the password must fit hashInput. }
    if passLen > 200 then passLen := 200;

    hashInputLen := 0;
    for k := 0 to saltLen - 1 do
    begin
      hashInput[hashInputLen] := saltBytes[k];
      Inc(hashInputLen);
    end;
    for k := 0 to passLen - 1 do
    begin
      hashInput[hashInputLen] := Byte(inputPass[k]);
      Inc(hashInputLen);
    end;

    SHA256_Compute(@hashInput[0], QWord(hashInputLen), @computed[0]);
    BytesToHex(@computed[0], 32, @computedHex[0]);

    foundAccount := True;
    passOk := ConstantTimeEq(@computedHex[0], @lineHash[0], 64) <> 0;

    { Secrets do not stay on the stack. }
    ZeroMemChar(@lineSalt[0], 72);
    ZeroMemChar(@lineHash[0], 80);
    ZeroMemByte(@saltBytes[0], 32);
    ZeroMemByte(@hashInput[0], 256);
    ZeroMemByte(@computed[0], 32);
    ZeroMemChar(@computedHex[0], 80);

    if not passOk then
    begin
      Heap_Free(passBuf);
      Ctx_SetRet(ctx, RET_DENIED);
      Exit;
    end;

    inSudoers := False;
    Fat16K_Cd(W('ETC'), 0);
    sudoSize := 0;
    sudoBuf := Fat16K_ReadFile(W('SUDOERS'), @sudoSize, 0);
    Fat16K_Cd(W('\'), 0);
    if (sudoBuf <> nil) and (sudoSize > 0) then
    begin
      inSudoers := SudoersContains_Pas(sudoBuf, sudoSize, @matchedUser[0]) <> 0;
      Heap_Free(sudoBuf);
    end;

    if not inSudoers then
    begin
      Heap_Free(passBuf);
      Ctx_SetRet(ctx, RET_NOT_SUDOER);
      Exit;
    end;

    if IsBuiltin(appName) then
    begin
      origUid := Sched_GetThreadUID(id);
      origGid := Sched_GetThreadGID(id);
      Sched_SetThreadUID(id, 0);
      Sched_SetThreadGID(id, 0);

      HandleBuiltin(id, appName, writeContent, writeLen);

      Sched_SetThreadUID(id, origUid);
      Sched_SetThreadGID(id, origGid);
      Con_SetColor($00FFFFFF);
      Heap_Free(passBuf);
      Ctx_SetRet(ctx, RET_OK);
      Exit;
    end;

    appFileSize := 0;
    rawData := Fat16K_ReadFile(appName, @appFileSize, id);
    if (rawData = nil) or (rawData[0] <> Ord('M')) or (rawData[1] <> Ord('Z')) then
    begin
      if rawData <> nil then Heap_Free(rawData);
      Heap_Free(passBuf);
      Ctx_SetRet(ctx, RET_NO_EXE);
      Exit;
    end;

    PELoader_LoadAndRun(rawData, False, False, True, appName, 1);
    Heap_Free(passBuf);
    Ctx_SetRet(ctx, RET_OK);
    Exit;
  end;

  { No account with the caller's UID. }
  if not foundAccount then Heap_Free(passBuf);
  Ctx_SetRet(ctx, RET_DENIED);
end;

function Sudo_Dispatch_Pas(id: Integer; ctx: Pointer): Integer; cdecl;
begin
  Sudo_Dispatch_Pas := Sudo_Handle(id, PQWord(ctx));
end;

end.
