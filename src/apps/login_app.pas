{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: login_app - Ring-3 security gateway (username + password).
  PORTED FROM: src/apps/Login.cs + src/apps/Crypto.cs (both deleted).

  Runs before anything else in userland. It reads the username, reads the
  password, looks the account up in /ETC/PASSWD, and on a match drops
  privileges to that account's UID/GID before starting SHELL.EXE.

  WHAT Crypto.cs WAS
  Only one thing: a DllImport shim onto SHA256_Compute_Pas so Login.cs could
  hash the password. kerncrypto.pas already exports that symbol and the
  kernel links the very same object, so the shim folded away completely -
  login_app now calls kerncrypto directly and there is no crypto logic of
  its own to keep in sync. The hex helpers, the constant-time compare and
  the buffer wipes come from the same unit.

  PASSWD FORMAT
  user:salt:hash:UID:GID:HOMEDIR, salt and hash as lowercase hex. The
  digest is SHA-256 over the RAW salt bytes (hex-decoded) followed by the
  typed password - not over the hex text. Getting that wrong is a silent
  "ACCESS DENIED" on a file that looks perfectly normal.

  The hash comparison uses ConstantTimeEq, and every sensitive buffer is
  wiped before the attempt is scored. Both of those are deliberate, and both
  survived the port unchanged.
  =========================================================================
}

unit login_app;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{ C# `a && b` short-circuits; the IPC loops below depend on it to avoid
  inspecting a message whose receive failed. }
{$B-}

interface

{ PE entry point. The loader looks for this symbol by name. }
procedure AppMain; cdecl; public name 'AppMain';

implementation

uses app_api, libc, kstring, kerncrypto;

const
  { --- SharedMemoryBlock layout (C#: fixed byte fields, pack = 1) --- }
  OFF_CMD_BUFFER  = 0;      { ShellCommandBuffer[4096], used as UTF-16 }
  OFF_REQ_NAME    = 4096;   { FatRequestName[4096] }
  OFF_RESP_DATA   = 8192;   { FatResponseData[8192] }

  { --- IPC message types --- }
  IPC_READ_REQ     = 30;
  IPC_READ_SIZE    = 31;    { reply: total file size in Payload }
  IPC_READ_ACK     = 311;   { ack the size reply }
  IPC_READ_CHUNK   = 38;    { request for the chunk at offset Payload }
  IPC_READ_CHUNK_OK = 39;   { ack a chunk }
  IPC_READ_EOF     = 42;    { end of file }

  IPC_CD_REQ       = 36;
  IPC_CD_REPLY     = 37;

  IPC_MKDIRAS_REQ  = 56;    { mkdir with an explicit owner }
  IPC_MKDIRAS_REPLY = 57;

  { Field widths in a PASSWD line. The C# bounded each field while copying
    and NUL-terminated at those bounds; the buffers below are one wider than
    the bound so the terminator always has a home. }
  USER_MAX = 31;
  SALT_MAX = 64;            { 32 raw bytes as hex }
  HASH_MAX = 64;            { SHA-256 as hex }
  NUM_MAX  = 15;
  HOME_MAX = 63;

  { Attempts before the session is locked for good. }
  MAX_ATTEMPTS = 3;

var
  FAT16_PID: Cardinal = 0;
  SharedMem: Pointer = nil;

  { TMessage is 24 bytes (4+4+4+4+8), so three QWords. }
  Msg: array[0..2] of QWord;

  EchoBuf: array[0..1] of Word;

  InputUser: array[0..31] of Word;
  InputPass: array[0..31] of Word;

  { The whole of /ETC/PASSWD, fetched over the FAT16 daemon. }
  PassFileBuf: array[0..4095] of Byte;

  { One parsed PASSWD record. }
  LineUser: array[0..USER_MAX] of Word;
  LineSalt: array[0..SALT_MAX] of Word;
  LineHash: array[0..HASH_MAX] of Word;
  LineUID: array[0..NUM_MAX] of Word;
  LineGID: array[0..NUM_MAX] of Word;
  LineHome: array[0..HOME_MAX] of Word;
  HomeSub: array[0..HOME_MAX] of Word;

  { Hashing scratch space. }
  SaltBytes: array[0..31] of Byte;
  HashInputBuf: array[0..63] of Byte;
  ComputedHash: array[0..31] of Byte;
  ComputedHashHex: array[0..79] of Word;

  { Prefix + decimal PID + LF, for the "daemon connected" banner. }
  NumLineBuf: array[0..127] of Word;

{ --------------------------------------------------------------------------
  Views onto the shared window - same offsets the C# struct fields had.
  -------------------------------------------------------------------------- }
function SharedCmdBuffer: PWord; inline;
begin
  SharedCmdBuffer := PWord(SharedMem);
end;

function SharedNameBuffer: PWord; inline;
begin
  SharedNameBuffer := PWord(PByte(SharedMem) + OFF_REQ_NAME);
end;

function SharedRespData: PByte; inline;
begin
  SharedRespData := PByte(PByte(SharedMem) + OFF_RESP_DATA);
end;

{ libc.StrCmp returns a Byte, not a Boolean. Case-insensitive, which is what
  the username match wants. }
function StrEq(a, b: PWord): Boolean; inline;
begin
  StrEq := libc.StrCmp(a, b) <> 0;
end;

procedure StringToSharedBuffer(source: PWord; dest: PWord); inline;
begin
  { Conservative cap: 4096 is the largest field in the shared block. }
  StrCpyLimited(dest, source, 4096);
end;

{ Read a line from the keyboard into buffer, echoing as we go. }
procedure ReadInput(buffer: PWord; maxLen: Integer; isPassword: Boolean);
var
  len: Integer;
  c: Word;
begin
  len := 0;
  while True do
  begin
    c := App_GetChar;
    { No key yet: the scheduler must idle, or login busy-spins and starves
      the thread that will deliver the key. }
    if c = 0 then
    begin
      App_WaitIPC;
      Continue;
    end;

    if (c = 10) or (c = 13) then
    begin
      App_Print(W('#10'));
      buffer[len] := 0;
      Break;
    end
    else if (c = 8) and (len > 0) then
    begin
      Dec(len);
      App_Print(W('#8#32#8'));
    end
    else if (c >= 32) and (c <= 126) and (len < maxLen) then
    begin
      buffer[len] := c;
      Inc(len);
      if isPassword then EchoBuf[0] := Ord('*') else EchoBuf[0] := c;
      App_Print(@EchoBuf[0]);
    end;
  end;
end;

{ Print prefix, then the number in decimal, then a newline. }
procedure PrintLineWithNum(prefix: PWord; num: Cardinal);
var
  idx: Integer;
begin
  idx := Integer(StrCpyLimited(@NumLineBuf[0], prefix, 128));
  AppendDecimalWide_Pas(@NumLineBuf[0], @idx, 128, num);
  NumLineBuf[idx] := 10;
  NumLineBuf[idx + 1] := 0;
  App_Print(@NumLineBuf[0]);
end;

{ Fetch a whole file through the FAT16 daemon into fileBuffer.
  Returns the size, or 0 on any failure. }
function ReadFileIPC(fileName: PWord; fileBuffer: PByte; bufferCapacity: Cardinal): Cardinal;
var
  fileSize, offset: Cardinal;
  dataChunk: PByte;
  i: Integer;
begin
  ReadFileIPC := 0;
  StringToSharedBuffer(fileName, SharedNameBuffer);
  App_SendIPC(FAT16_PID, IPC_READ_REQ, 0);

  fileSize := 0;
  dataChunk := SharedRespData;

  while True do
  begin
    if App_ReceiveIPC(@Msg[0]) = 1 then
    begin
      if App_MsgSender(@Msg[0]) = FAT16_PID then
      begin
        if App_MsgType(@Msg[0]) = IPC_READ_SIZE then
        begin
          fileSize := Cardinal(App_MsgPayload(@Msg[0]));
          if fileSize = 0 then
          begin
            ReadFileIPC := 0;
            Exit;
          end;
          { A PASSWD file larger than the real buffer must be refused, not
            truncated into - refusing is what keeps a bloated account
            database from overwriting this process's memory. }
          if fileSize > bufferCapacity then
          begin
            App_Print(W('#10[!!!] FATAL: File too large for buffer (potential overflow blocked)!'#10));
            App_SendIPC(FAT16_PID, IPC_READ_ACK, 0);
            ReadFileIPC := 0;
            Exit;
          end;
          App_SendIPC(FAT16_PID, IPC_READ_ACK, 0);
        end
        else if App_MsgType(@Msg[0]) = IPC_READ_CHUNK then
        begin
          offset := Cardinal(App_MsgPayload(@Msg[0]));
          i := 0;
          while i < 512 do
          begin
            if (Cardinal(i) + offset < fileSize) and (Cardinal(i) + offset < bufferCapacity) then
              fileBuffer[offset + i] := dataChunk[i];
            Inc(i);
          end;
          App_SendIPC(FAT16_PID, IPC_READ_CHUNK_OK, 0);
        end
        else if App_MsgType(@Msg[0]) = IPC_READ_EOF then
        begin
          ReadFileIPC := fileSize;
          Exit;
        end;
      end;
      { Junk letter: drop it and keep waiting. Falling through to WaitIPC here
        would sleep on a mailbox that already has a message in it. }
      Continue;
    end;
    App_WaitIPC;
  end;
end;

{ Change the daemon's working directory. Returns the daemon's verdict. }
function ChangeDirectoryIPC(dirName: PWord): Boolean;
begin
  StringToSharedBuffer(dirName, SharedNameBuffer);
  App_SendIPC(FAT16_PID, IPC_CD_REQ, 0);
  while True do
  begin
    if App_ReceiveIPC(@Msg[0]) = 1 then
    begin
      if App_MsgSender(@Msg[0]) = FAT16_PID then
      begin
        if App_MsgType(@Msg[0]) = IPC_CD_REPLY then
        begin
          ChangeDirectoryIPC := App_MsgPayload(@Msg[0]) = 1;
          Exit;
        end;
      end;
      Continue;
    end;
    App_WaitIPC;
  end;
end;

{ Create a directory owned by someone other than the caller. Only legal while
  the process is still root, which is why Login calls it before dropping
  privileges - it is how a user's home directory gets created without granting
  write access to /HOME or writing permission bits by hand onto the disk. }
function MkdirAsIPC(dirName: PWord; targetUID, targetGID: Cardinal): Boolean;
var
  buf: PWord;
  idx: Integer;
begin
  buf := SharedNameBuffer;
  idx := Integer(StrCpyLimited(buf, dirName, 4096));
  buf[idx] := 0;
  Inc(idx);

  AppendDecimalWide_Pas(buf, @idx, 4096, targetUID);
  buf[idx] := Ord(':');
  Inc(idx);
  AppendDecimalWide_Pas(buf, @idx, 4096, targetGID);
  buf[idx] := 0;

  App_SendIPC(FAT16_PID, IPC_MKDIRAS_REQ, 0);
  while True do
  begin
    if App_ReceiveIPC(@Msg[0]) = 1 then
    begin
      if App_MsgSender(@Msg[0]) = FAT16_PID then
      begin
        if App_MsgType(@Msg[0]) = IPC_MKDIRAS_REPLY then
        begin
          MkdirAsIPC := App_MsgPayload(@Msg[0]) = 1;
          Exit;
        end;
      end;
      Continue;
    end;
    App_WaitIPC;
  end;
end;

{ Last path component of a HOMEDIR: "/HOME/nekko" -> "nekko". }
procedure ExtractLastComponent(path: PWord; outBuf: PWord; outCap: Integer);
var
  len, lastSep, startPos, o, i: Integer;
begin
  len := 0;
  while path[len] <> 0 do Inc(len);

  lastSep := -1;
  for i := 0 to len - 1 do
    if (path[i] = Ord('/')) or (path[i] = Ord('\')) then lastSep := i;

  startPos := lastSep + 1;
  o := 0;
  i := startPos;
  while (i < len) and (o < outCap - 1) do
  begin
    outBuf[o] := path[i];
    Inc(o);
    Inc(i);
  end;
  outBuf[o] := 0;
end;

procedure AppMain; cdecl;
var
  pid: LongInt;
  attempts: Integer;
  passSize: Cardinal;
  authSuccess: Boolean;
  matchedUID, matchedGID: Cardinal;
  i, u, s, h, idv, gdv, hm, stage, saltLen, passLen, hashInputLen, k: Integer;
  c: Word;
  failedCount: Cardinal;
begin
  AppApi_Init;

  EchoBuf[1] := 0;

  SharedMem := Pointer(App_GetSharedMem);

  pid := App_GetPIDByName(W('FAT16.EXE'));
  if pid = -1 then
  begin
    App_Print(W('[!] FATAL: FAT16.EXE Daemon not found! System Locked!'#10));
    App_Exit;
    while True do App_WaitIPC;
  end;
  FAT16_PID := Cardinal(pid);

  PrintLineWithNum(W('FAT16 Daemon connected at PID: '), FAT16_PID);

  App_Print(W('#10======================================================='#10 +
               '           NEKKO OS SECURITY GATEWAY (LOGIN)'#10 +
               '======================================================='#10));

  attempts := MAX_ATTEMPTS;

  while attempts > 0 do
  begin
    App_Print(W('Username: '));
    ReadInput(@InputUser[0], 31, False);

    App_Print(W('Password: '));
    ReadInput(@InputPass[0], 31, True);

    if not ChangeDirectoryIPC(W('ETC')) then
    begin
      App_Print(W('#10[!!!] CRITICAL ERROR: /ETC DIRECTORY NOT FOUND!'#10));
      Break;
    end;
    passSize := ReadFileIPC(W('PASSWD'), @PassFileBuf[0], 4096);
    ChangeDirectoryIPC(W('\'));

    if passSize = 0 then
    begin
      App_Print(W('#10[!!!] CRITICAL ERROR: /ETC/PASSWD NOT FOUND OR EMPTY!'#10));
      Break;
    end;

    authSuccess := False;
    matchedUID := 0;
    matchedGID := 0;

    i := 0;
    while i < Integer(passSize) do
    begin
      { user:salt:hash:UID:GID:HOMEDIR - six colon-separated fields, each
        bounded so one corrupt line cannot overrun the buffers. }
      u := 0; s := 0; h := 0; idv := 0; gdv := 0; hm := 0; stage := 0;
      while (i < Integer(passSize)) and (PassFileBuf[i] <> 10) and (PassFileBuf[i] <> 13) do
      begin
        c := Word(PassFileBuf[i]);
        if c = Ord(':') then
          Inc(stage)
        else if stage = 0 then
        begin
          if u < USER_MAX then
          begin
            LineUser[u] := c;
            Inc(u);
          end;
        end
        else if stage = 1 then
        begin
          if s < SALT_MAX then
          begin
            LineSalt[s] := c;
            Inc(s);
          end;
        end
        else if stage = 2 then
        begin
          if h < HASH_MAX then
          begin
            LineHash[h] := c;
            Inc(h);
          end;
        end
        else if stage = 3 then
        begin
          if idv < NUM_MAX then
          begin
            LineUID[idv] := c;
            Inc(idv);
          end;
        end
        else if stage = 4 then
        begin
          if gdv < NUM_MAX then
          begin
            LineGID[gdv] := c;
            Inc(gdv);
          end;
        end
        else if stage = 5 then
        begin
          if hm < HOME_MAX then
          begin
            LineHome[hm] := c;
            Inc(hm);
          end;
        end;
        { A seventh field would land in stage 6 and is dropped, as in the
          original. }
        Inc(i);
      end;
      LineUser[u] := 0;
      LineSalt[s] := 0;
      LineHash[h] := 0;
      LineUID[idv] := 0;
      LineGID[gdv] := 0;
      LineHome[hm] := 0;

      { An empty username must never match: an empty typed name and an empty
        PASSWD field are both "" and compare equal, which would let a blank
        line in a corrupt file authenticate anyone. }
      if (u > 0) and (InputUser[0] <> 0) and StrEq(@InputUser[0], @LineUser[0]) then
      begin
        { The digest is over the RAW salt bytes, not the hex text. }
        saltLen := HexToBytes(@LineSalt[0], @SaltBytes[0], 32);
        passLen := 0;
        while InputPass[passLen] <> 0 do Inc(passLen);

        hashInputLen := 0;
        for k := 0 to saltLen - 1 do
        begin
          HashInputBuf[hashInputLen] := SaltBytes[k];
          Inc(hashInputLen);
        end;
        for k := 0 to passLen - 1 do
        begin
          HashInputBuf[hashInputLen] := Byte(InputPass[k]);
          Inc(hashInputLen);
        end;

        { This is what Crypto.cs shimmed onto. The implementation is the same
          kerncrypto.pas the kernel links. }
        SHA256_Compute(@HashInputBuf[0], QWord(hashInputLen), @ComputedHash[0]);
        BytesToHex(@ComputedHash[0], 32, @ComputedHashHex[0]);

        { Constant-time, so a wrong hash cannot be discovered a character at a
          time by watching how long the answer takes. }
        if ConstantTimeEq(@ComputedHashHex[0], @LineHash[0], 64) <> 0 then
        begin
          authSuccess := True;
          matchedUID := Atoi(@LineUID[0]);
          matchedGID := Atoi(@LineGID[0]);
          Break;
        end;
      end;

      while (i < Integer(passSize)) and ((PassFileBuf[i] = 10) or (PassFileBuf[i] = 13)) do
        Inc(i);
    end;

    { Wipe everything sensitive this attempt touched, pass or fail, so it is
      not readable back out of the process image later. }
    ZeroMemChar(@InputPass[0], 32);
    ZeroMemChar(@LineSalt[0], 80);
    ZeroMemChar(@LineHash[0], 80);
    ZeroMemByte(@SaltBytes[0], 32);
    ZeroMemByte(@HashInputBuf[0], 64);
    ZeroMemByte(@ComputedHash[0], 32);
    ZeroMemChar(@ComputedHashHex[0], 80);

    if authSuccess then
    begin
      App_Print(W('#10[+] AUTHENTICATED! Welcome to the Multiverse!'#10));

      { Still root at this point, so make sure /HOME and the account's own
        home directory exist and are owned by that account - not by root. }
      ExtractLastComponent(@LineHome[0], @HomeSub[0], 64);
      if HomeSub[0] <> 0 then
      begin
        ChangeDirectoryIPC(W('\'));
        if not ChangeDirectoryIPC(W('HOME')) then
        begin
          MkdirAsIPC(W('HOME'), 0, 0);
          ChangeDirectoryIPC(W('HOME'));
        end;
        if not ChangeDirectoryIPC(@HomeSub[0]) then
          MkdirAsIPC(@HomeSub[0], matchedUID, matchedGID);
      end;
      ChangeDirectoryIPC(W('\'));

      App_SetUID(matchedUID);
      App_SetGID(matchedGID);

      { SHELL.EXE lives in "/", so the daemon's cwd must be root when
        RunCmd loads it - otherwise it looks in /HOME/<user> and reports the
        file missing. The daemon's current directory is global, not
        per-client, so this cd has to happen AFTER RunCmd has loaded the
        image: a shell that started in the user's home directory would then
        be working in a directory the user may not be able to read. }
      ChangeDirectoryIPC(W('\'));

      StringToSharedBuffer(W('run SHELL.EXE'), SharedCmdBuffer);
      App_RunCmd(SharedCmdBuffer, 0);

      { Privileges are gone; now actually enter the home directory, so the
        rights are proven rather than assumed. A failure here is not fatal. }
      if HomeSub[0] <> 0 then
      begin
        if not ChangeDirectoryIPC(W('HOME')) or not ChangeDirectoryIPC(@HomeSub[0]) then
        begin
          ChangeDirectoryIPC(W('\'));
          App_Print(W('[!] Warning: Could not enter home directory, staying at /.'#10));
        end;
      end;

      App_Exit;
      while True do App_WaitIPC;
    end
    else
    begin
      Dec(attempts);
      App_Print(W('#10[!] ACCESS DENIED! Incorrect Username or Password.'#10));
      if attempts > 0 then
      begin
        App_Print(W('[!] Invalid credentials. Try again.'#10#10));
        { Back off after each failure (1s, then 2s). Slows an automated
          password sweep to a crawl without inconveniencing a human. }
        failedCount := Cardinal(MAX_ATTEMPTS - attempts);
        App_Sleep(QWord(1000) * QWord(failedCount));
      end;
    end;
  end;

  { Out of attempts. This session is finished for good - restarting the login
    process is the only way to try again, which combined with the backoff
    above spreads a brute force across many sessions. }
  App_Print(W('#10[!!!] SYSTEM LOCKDOWN INITIATED [!!!]'#10));
  App_Exit;
  while True do App_WaitIPC;
end;

end.
