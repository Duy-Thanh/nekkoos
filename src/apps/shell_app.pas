{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: shell_app - Ring-3 interactive shell.
  PORTED FROM: src/apps/Shell.cs (deleted).

  Runs as a user process. It owns a slice of the kernel's shared window,
  drives the FAT16 daemon over IPC, and turns keyboard bytes into a command
  line. Every command is dispatched by matching the raw UTF-16 line against
  a fixed table of literals; anything unrecognised falls through to
  SyscallRunCmd so the kernel's internal shell can try it.

  TWO NOTES ON THE PORT
  1. BUFFER GEOMETRY. The C# used stackalloc for every large buffer
     (content captures, temp strings) and had to be defensive about it: bflat
     AOT reserves a function's whole stackalloc frame up front, so two
     buffers in one frame cost twice the memory even when only one is live -
     that is what the "[STACK ISOLATION]" comments in Shell.cs were working
     around. A Pascal unit has no such restriction, so the equivalents here
     are unit-level statics. Identical lifetime, and the 8 KB content
     captures no longer sit on the kernel stack at all.

  2. TWO SYSCALLS HAVE NO app_api WRAPPER YET. SyscallCreateSharedBuffer and
     SyscallSudoRun are bound locally below with AppApi_Slot + a call through
     a procedural type, which is exactly how app_api builds its own wrappers.
     When the wrappers land in app_api these two functions can be deleted.
  =========================================================================
}

unit shell_app;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{ C# `a && b` short-circuits. FPC's default is short-circuit too, but the IPC
  receive loops below inspect the message only when the receive succeeded, so
  pin the mode explicitly rather than rely on a default. }
{$B-}

interface

{ PE entry point. The loader looks for this symbol by name. }
procedure AppMain; cdecl; public name 'AppMain';

implementation

uses app_api, libc, kstring;

const
  { --- SharedMemoryBlock layout (C#: fixed byte fields, pack = 1) ---
    Offsets are fixed, so the record itself is not needed: a record reachable
    from the interface would drag RTTI into the link (see PASCAL_PORTING §4),
    and these are just three addresses inside the kernel's shared page. }
  OFF_CMD_BUFFER  = 0;      { ShellCommandBuffer[4096], used as UTF-16 }
  OFF_REQ_NAME    = 4096;   { FatRequestName[4096] }
  OFF_RESP_DATA   = 8192;   { FatResponseData[8192] }

  { --- IPC message types exchanged with FAT16.EXE --- }
  IPC_READ_REQ      = 30;   { cat / read a file }
  IPC_READ_SIZE     = 31;   { reply: total file size in Payload }
  IPC_READ_ACK      = 311;  { ack the size reply }
  IPC_READ_CHUNK    = 38;   { request for the chunk at offset Payload }
  IPC_READ_CHUNK_OK = 39;   { ack a chunk }
  IPC_READ_EOF      = 42;   { end of file }

  IPC_WRITE_REQ    = 32;    { write: Payload = byte count }
  IPC_WRITE_CHUNK  = 33;    { reply: Payload = offset of the 512-byte chunk }
  IPC_WRITE_ACK    = 34;    { ack a chunk }
  IPC_WRITE_DONE   = 35;    { reply: Payload = 1 on success }

  IPC_CD_REQ       = 36;
  IPC_CD_REPLY     = 37;

  IPC_LS_REQ       = 40;
  IPC_LS_DATA      = 41;

  IPC_MKDIR_REQ    = 44;
  IPC_MKDIR_REPLY  = 45;

  IPC_MKDIRAS_REQ  = 56;    { mkdir with explicit owner }

  IPC_RM_REQ       = 46;
  IPC_RM_REPLY     = 47;

  IPC_RMDIR_REQ    = 48;
  IPC_RMDIR_REPLY  = 49;

  IPC_CHMOD_REQ    = 58;
  IPC_CHMOD_REPLY  = 59;

  IPC_CHOWN_REQ    = 60;
  IPC_CHOWN_REPLY  = 61;

  { The kernel posts this to every process when the session is torn down. }
  IPC_SIGTERM      = $DEAD;

  { DWM framebuffer geometry - matches the original Shell.cs defaults. }
  GUI_WIDTH  = 640;
  GUI_HEIGHT = 400;

  { Write-capture limits. ContentCap leaves room for the NUL in the worst
    case, and 255 is the widest command line the input loop accepts. }
  CONTENT_CAP = 8192;
  CMD_MAX     = 255;

  { WindowHeader is 256 bytes: X, Y, Width, Height (4 x uint) then
    Title[32] then Padding[208]. The pixel buffer starts right after it. }
  WIN_HDR_TITLE_OFF = 16;
  WIN_HDR_SIZE      = 256;

var
  FAT16_PID: Cardinal = 0;
  DWM_PID: LongInt = -1;
  GuiVAddr: QWord = 0;
  { Nil until the display server hands us a window, and even then the pixel
    drawing is disabled - the value survives only because it is handed to
    SyscallRunCmd as the caller's "UI context" argument. }
  GuiPixels: QWord = 0;

  SharedMem: Pointer = nil;

  { TMessage is 24 bytes (4+4+4+4+8), so three QWords, not two. }
  Msg: array[0..2] of QWord;

  { Echo buffer for a single keystroke. Static arrays are zero-filled, so the
    NUL terminator is already in place before the first key is pressed. }
  EchoBuf: array[0..1] of Word;

  { cat accumulates one 512-byte chunk here before printing it as UTF-16. }
  CatTemp: array[0..512] of Word;

  { SplitTwoArgs outputs for chmod / chown. }
  ModeStr: array[0..15] of Word;
  OwnerStr: array[0..31] of Word;
  PathBuf: array[0..255] of Word;

  { Content buffers. Two of them, exactly as the C# had two separate
    stackallocs: the `write` builtin and `sudo write` each own one, and the
    sudo path must not clobber the other command's capture. }
  WriteContent: array[0..CONTENT_CAP - 1] of Byte;
  SudoContent: array[0..CONTENT_CAP - 1] of Byte;
  WriteLineBuf: array[0..255] of Word;

{ --------------------------------------------------------------------------
  Views onto the shared window. Offsets are fixed, so these are just typed
  pointers rather than a record.
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

{ --------------------------------------------------------------------------
  The two syscalls app_api does not wrap yet. The vDSO stubs are plain
  `mov rax, imm32; int 0x80; ret` sequences, so they take arguments in the
  normal System V integer registers and a direct call through the raw stub
  address is the correct thing to do.
  -------------------------------------------------------------------------- }
{ These two used to be bound locally here because app_api had no wrapper for
  them. app_api now provides App_CreateSharedBuffer and App_SudoRun directly
  - and note the shared-buffer one was WRONG there (it passed the page count
  where the kernel expects a pid) and is now hand-loaded in asm, since the
  out-pointer must go in R8 and the target address returns in RBX. }
function Sys_CreateSharedBuffer(destPid: Cardinal; numPages: QWord; addrOut: Pointer): QWord;
var
  tgt: QWord;
begin
  tgt := QWord(addrOut);
  Sys_CreateSharedBuffer := App_CreateSharedBuffer(destPid, numPages, tgt);
  addrOut := Pointer(tgt);
end;

function Sys_SudoRun(appName, password: PWord; content: PByte; contentLen: QWord): QWord;
begin
  Sys_SudoRun := App_SudoRun(appName, password, content, contentLen);
end;

{ ShellPrint was a real function in Shell.cs only because the framebuffer
  branch was live; every call site already fell through to SyscallPrint. }
procedure ShellPrint(msg: PWord); inline;
begin
  App_Print(msg);
end;

{ libc.StrCmp / StrStartsWith return a Byte, not a Boolean. Wrapping them
  once here keeps the dispatch chain below readable and mirrors the
  `StrCmp(...)` / `StrStartsWith(...)` helpers the C# exposed. }
function StrEq(a, b: PWord): Boolean; inline;
begin
  StrEq := libc.StrCmp(a, b) <> 0;
end;

function StrStarts(a, b: PWord): Boolean; inline;
begin
  StrStarts := libc.StrStartsWith(a, b) <> 0;
end;

procedure ClearBuffer(ptr: PByte; sizeBytes: Cardinal); inline;
begin
  MemSet(ptr, 0, sizeBytes);
end;

{ Copy a wide-char path into the shared FAT16 name buffer, capped. }
procedure CopyPathToShared(src: PWord; cap: Integer); inline;
begin
  StrCpyLimited(SharedNameBuffer, src, Cardinal(cap));
  SharedNameBuffer[cap - 1] := 0;
end;

{ Drain every pending message. Used before each command so a reply left over
  from a previous command can never be mistaken for this command's reply. }
procedure SweepMailbox;
var
  trash: array[0..2] of QWord;
begin
  while App_ReceiveIPC(@trash[0]) = 1 do
    { burn it }
  ;
end;

{ Read a line from the keyboard into buffer, echoing as we go. maxLen is the
  number of characters the caller wants to store. Used by `sudo` for the
  hidden password prompt. }
procedure ReadInput(buffer: PWord; maxLen: Integer; isPassword: Boolean);
var
  len: Integer;
  c: Word;
begin
  len := 0;
  while True do
  begin
    c := App_GetChar;
    { No key yet: the scheduler must idle, or the shell busy-spins and starves
      the thread that will deliver the key. }
    if c = 0 then
    begin
      App_WaitIPC;
      Continue;
    end;

    if (c = 10) or (c = 13) then
    begin
      ShellPrint(W('#10'));
      buffer[len] := 0;
      Break;
    end
    else if (c = 8) and (len > 0) then
    begin
      Dec(len);
      ShellPrint(W('#8#32#8'));
    end
    else if (c >= 32) and (c <= 126) and (len < maxLen) then
    begin
      buffer[len] := c;
      Inc(len);
      if isPassword then EchoBuf[0] := Ord('*') else EchoBuf[0] := c;
      ShellPrint(@EchoBuf[0]);
    end;
  end;
end;

{ Capture multi-line content until a line containing a single '.'.
  Returns the byte count written into buf, with a newline after every line
  except the terminating one. }
function CaptureWriteContent(buf: PByte; bufCap: Integer): Integer;
var
  contentLen, lineLen, i: Integer;
  c: Word;
begin
  contentLen := 0;
  while True do
  begin
    lineLen := 0;
    while True do
    begin
      c := App_GetChar;
      if c = 0 then
      begin
        App_WaitIPC;
        Continue;
      end;

      { Both CR and LF end a line - accepted so a lone CR can never leak into
        the captured content or be silently swallowed. }
      if (c = 10) or (c = 13) then
      begin
        ShellPrint(W('#10'));
        Break;
      end
      else if (c = 8) and (lineLen > 0) then
      begin
        Dec(lineLen);
        ShellPrint(W('#8#32#8'));
      end
      else if (c >= 32) and (c <= 126) and (lineLen < 255) then
      begin
        WriteLineBuf[lineLen] := c;
        Inc(lineLen);
        EchoBuf[0] := c;
        ShellPrint(@EchoBuf[0]);
      end;
    end;

    if (lineLen = 1) and (WriteLineBuf[0] = Ord('.')) then Break;

    i := 0;
    while (i < lineLen) and (contentLen < bufCap - 1) do
    begin
      buf[contentLen] := Byte(WriteLineBuf[i]);
      Inc(contentLen);
      Inc(i);
    end;
    if contentLen < bufCap - 1 then
    begin
      buf[contentLen] := 10;
      Inc(contentLen);
    end;
  end;
  CaptureWriteContent := contentLen;
end;

{ `write <path>` - capture the content, then stream it to the FAT16 daemon in
  512-byte chunks. }
procedure DoWriteCmd(fileName: PWord);
var
  sharedNameBuf: PWord;
  dataChunk: PByte;
  contentLen, i: Integer;
  payloadSize: Cardinal;
  offset: Cardinal;
begin
  sharedNameBuf := SharedNameBuffer;
  WideStrToBytes(fileName, PByte(sharedNameBuf), 256);
  sharedNameBuf[255] := 0;

  ShellPrint(W('[*] Enter content. End with a single ''.'' on its own line:'#10));

  contentLen := CaptureWriteContent(@WriteContent[0], CONTENT_CAP);
  payloadSize := Cardinal(contentLen);

  App_SendIPC(FAT16_PID, IPC_WRITE_REQ, QWord(payloadSize));

  dataChunk := SharedRespData;
  while True do
  begin
    if (App_ReceiveIPC(@Msg[0]) = 1) and (App_MsgSender(@Msg[0]) = FAT16_PID) then
    begin
      if App_MsgType(@Msg[0]) = IPC_WRITE_CHUNK then
      begin
        offset := Cardinal(App_MsgPayload(@Msg[0]));
        i := 0;
        while i < 512 do
        begin
          if Cardinal(i) + offset < payloadSize then
            dataChunk[i] := WriteContent[offset + i]
          else
            dataChunk[i] := 0;
          Inc(i);
        end;
        App_SendIPC(FAT16_PID, IPC_WRITE_ACK, 0);
      end
      else if App_MsgType(@Msg[0]) = IPC_WRITE_DONE then
      begin
        if App_MsgPayload(@Msg[0]) = 1 then
          ShellPrint(W('[+] File written successfully!'#10))
        else
          ShellPrint(W('[!] Failed! Disk Full, Access Denied or File is a Directory!'#10));
        Break;
      end;
    end
    else
      App_WaitIPC;
  end;
end;

{ `sudo <app>` - re-authenticate, then let the kernel run the app with
  forceRoot. The whole body lives in its own function in the C# original to
  keep the two content captures in separate stack frames; with statics that
  concern is gone, but the structure is kept so the flow still reads top-down. }
procedure DoSudoCmd(appName: PWord);
var
  isSudoWrite: Boolean;
  sudoContentLen: Integer;
  wpath: PWord;
  passBuf: array[0..63] of Word;
  sudoResult: QWord;
  i: Integer;
begin
  isSudoWrite := StrStartsWith(appName, W('write ')) <> 0;
  sudoContentLen := 0;

  if isSudoWrite then
  begin
    wpath := appName + 6;
    if wpath[0] = 0 then
    begin
      ShellPrint(W('[!] Usage: sudo write <path>'#10));
      Exit;
    end;
    ShellPrint(W('[*] Enter content. End with a single ''.'' on its own line:'#10));
    sudoContentLen := CaptureWriteContent(@SudoContent[0], CONTENT_CAP);
  end;

  ShellPrint(W('[sudo] Password: '));
  ReadInput(@passBuf[0], 63, True);

  if isSudoWrite then
    sudoResult := Sys_SudoRun(appName, @passBuf[0], @SudoContent[0], QWord(sudoContentLen))
  else
    sudoResult := Sys_SudoRun(appName, @passBuf[0], nil, 0);

  { Wipe the password and any captured content before the frame is reused. }
  for i := 0 to High(passBuf) do passBuf[i] := 0;
  if isSudoWrite then
    for i := 0 to sudoContentLen - 1 do SudoContent[i] := 0;

  if sudoResult = 1 then
    { success - the kernel already started the app, nothing to report }
  else if sudoResult = 2 then
    ShellPrint(W('[!] User is not in the sudoers file. This incident will be reported.'#10))
  else if sudoResult = 3 then
    ShellPrint(W('[!] Target application not found or corrupted.'#10))
  else
    ShellPrint(W('[!] Sorry, try again.'#10));
end;

procedure AppMain; cdecl;
var
  myUID: Cardinal;
  cmdLen: Integer;
  c: Word;
  pid: LongInt;
  fileSize: Cardinal;
  offset, i: Integer;
  tIdx: Integer;
  dataChunk: PByte;
  sharedNameBuf: PWord;
  mode: Cardinal;
  idx: Integer;
  targetDwmVAddr: QWord;
  myBuffer: QWord;
  totalBytes, numPages: QWord;
begin
  AppApi_Init;

  EchoBuf[1] := 0;

  { --- Locate the FAT16 daemon. Without it there is no filesystem and the
    shell has nothing to do. --- }
  pid := App_GetPIDByName(W('FAT16.EXE'));
  if pid = -1 then
  begin
    ShellPrint(W('[!] FATAL: FAT16.EXE Daemon not found! Shell Locked!'#10));
    App_Exit;
    { "CÓ CHẾT CŨNG PHẢI NGỦ" - an exited thread must still yield. The loop
      below is what kept the original from wedging the scheduler. }
    while True do App_WaitIPC;
  end;
  FAT16_PID := Cardinal(pid);

  DWM_PID := App_GetPIDByName(W('DSRV.EXE'));

  { --- Optional graphical window. If the display server is running we ask it
    for a shared framebuffer and publish a WindowHeader in front of it. --- }
  if DWM_PID > 0 then
  begin
    totalBytes := QWord(GUI_WIDTH) * QWord(GUI_HEIGHT) * 4 + 256;
    numPages := (totalBytes + 4095) div 4096;
    targetDwmVAddr := 0;
    myBuffer := Sys_CreateSharedBuffer(Cardinal(DWM_PID), numPages, @targetDwmVAddr);

    if myBuffer <> 0 then
    begin
      GuiVAddr := targetDwmVAddr;
      GuiPixels := myBuffer + WIN_HDR_SIZE;

      PDWord(myBuffer)[0] := 150;                      { X }
      PDWord(myBuffer)[1] := 150;                      { Y }
      PDWord(myBuffer)[2] := GUI_WIDTH;                { Width }
      PDWord(myBuffer)[3] := GUI_HEIGHT;               { Height }
      StrCpyLimited(PWord(PByte(myBuffer) + WIN_HDR_TITLE_OFF), W('Nekko CMD'), 31);

      { Black background. }
      i := 0;
      while i < GUI_WIDTH * GUI_HEIGHT do
      begin
        PDWord(GuiPixels)[i] := 0;
        Inc(i);
      end;

      App_SendIPC(Cardinal(DWM_PID), 11, GuiVAddr);
    end;
  end;

  SharedMem := Pointer(App_GetSharedMem);

  ShellPrint(W('#10======================================================='#10 +
               '           NEKKO OS USERLAND SHELL (RING 3)'#10 +
               '======================================================='#10));

  while True do
  begin
    myUID := App_GetUID;
    if myUID = 0 then
      ShellPrint(W('root@nekkoOS# '))
    else
      ShellPrint(W('nekko@user$ '));

    cmdLen := 0;

    { Consume anything already queued. A SIGTERM here is how the kernel
      shuts the session down. }
    while App_ReceiveIPC(@Msg[0]) = 1 do
    begin
      if App_MsgType(@Msg[0]) = IPC_SIGTERM then
      begin
        ClearBuffer(SharedRespData, 8192);
        ClearBuffer(PByte(SharedNameBuffer), 512);
        ClearBuffer(PByte(SharedCmdBuffer), 512);

        ShellPrint(W('#10[*] Shell: SIGTERM received. Sweeping workspace and signing off. Goodbye!'#10));
        App_Exit;
        while True do App_WaitIPC;
      end;
    end;

    { --- Read the command line. NOTE: only LF terminates a command here, not
      CR - matching the original exactly, because the keyboard path that
      feeds this loop does not deliver a bare CR. --- }
    c := 0;
    while True do
    begin
      c := App_GetChar;
      { Waiting on the keyboard must idle the thread or the shell spins and
        starves the thread that will deliver the key. }
      if c = 0 then
      begin
        App_WaitIPC;
        Continue;
      end;

      if c = 10 then
      begin
        ShellPrint(W('#10'));
        { Trailing spaces are trimmed before the line is dispatched. }
        while (cmdLen > 0) and (SharedCmdBuffer[cmdLen - 1] = Ord(' ')) do Dec(cmdLen);
        SharedCmdBuffer[cmdLen] := 0;
        Break;
      end
      else if (c = 8) and (cmdLen > 0) then
      begin
        Dec(cmdLen);
        ShellPrint(W('#8#32#8'));
      end
      else if (c >= 32) and (c <= 126) and (cmdLen < CMD_MAX) then
      begin
        SharedCmdBuffer[cmdLen] := c;
        Inc(cmdLen);
        EchoBuf[0] := c;
        ShellPrint(@EchoBuf[0]);
      end;
    end;

    if cmdLen > 0 then
    begin
      { The dispatch order below is the original's, and it matters: the bare
        form of each command is tested before the prefix form, so `cat` is a
        usage error while `cat x` is a read. }

      if StrEq(SharedCmdBuffer, W('ls')) or StrEq(SharedCmdBuffer, W('ll')) then
      begin
        SweepMailbox;
        ClearBuffer(SharedRespData, 8192);
        App_SendIPC(FAT16_PID, IPC_LS_REQ, 0);
        while True do
        begin
          if (App_ReceiveIPC(@Msg[0]) = 1) and
             (App_MsgSender(@Msg[0]) = FAT16_PID) and
             (App_MsgType(@Msg[0]) = IPC_LS_DATA) then
          begin
            ShellPrint(PWord(SharedRespData));
            Break;
          end;
          App_WaitIPC;
        end;
      end

      else if StrEq(SharedCmdBuffer, W('cat')) then
        ShellPrint(W('[!] Usage: cat <path>'#10))

      else if StrStarts(SharedCmdBuffer, W('cat ')) then
      begin
        SweepMailbox;
        CopyPathToShared(SharedCmdBuffer + 4, 256);

        App_SendIPC(FAT16_PID, IPC_READ_REQ, 0);

        fileSize := 0;
        dataChunk := SharedRespData;

        while True do
        begin
          if (App_ReceiveIPC(@Msg[0]) = 1) and (App_MsgSender(@Msg[0]) = FAT16_PID) then
          begin
            if App_MsgType(@Msg[0]) = IPC_READ_SIZE then
            begin
              fileSize := Cardinal(App_MsgPayload(@Msg[0]));
              if fileSize = 0 then
              begin
                ShellPrint(W('[!] Shell: File not found or Access Denied!'#10));
                Break;
              end;
              App_SendIPC(FAT16_PID, IPC_READ_ACK, 0);
            end
            else if App_MsgType(@Msg[0]) = IPC_READ_CHUNK then
            begin
              offset := LongInt(Cardinal(App_MsgPayload(@Msg[0])));
              tIdx := 0;
              i := 0;
              while i < 512 do
              begin
                { Carriage returns are dropped so a CRLF file does not print
                  as a staircase. }
                if (Cardinal(offset + i) < fileSize) and (dataChunk[i] <> 13) then
                begin
                  CatTemp[tIdx] := Word(dataChunk[i]);
                  Inc(tIdx);
                end;
                Inc(i);
              end;
              CatTemp[tIdx] := 0;
              ShellPrint(@CatTemp[0]);
              App_SendIPC(FAT16_PID, IPC_READ_CHUNK_OK, 0);
            end
            else if App_MsgType(@Msg[0]) = IPC_READ_EOF then
            begin
              ShellPrint(W('#10'));
              Break;
            end;
          end
          else
            App_WaitIPC;
        end;
      end

      else if StrEq(SharedCmdBuffer, W('write')) then
        ShellPrint(W('[!] Usage: write <path>'#10))

      else if StrStarts(SharedCmdBuffer, W('write ')) then
      begin
        SweepMailbox;
        DoWriteCmd(SharedCmdBuffer + 6);
      end

      else if StrEq(SharedCmdBuffer, W('cd')) then
        ShellPrint(W('[!] Usage: cd <path>'#10))

      else if StrStarts(SharedCmdBuffer, W('cd ')) then
      begin
        SweepMailbox;
        CopyPathToShared(SharedCmdBuffer + 3, 256);

        App_SendIPC(FAT16_PID, IPC_CD_REQ, 0);
        while True do
        begin
          if (App_ReceiveIPC(@Msg[0]) = 1) and (App_MsgSender(@Msg[0]) = FAT16_PID) then
          begin
            if App_MsgType(@Msg[0]) = IPC_CD_REPLY then
            begin
              if App_MsgPayload(@Msg[0]) = 0 then
                ShellPrint(W('[!] Directory not found or Access Denied!'#10));
              Break;
            end;
          end
          else
            App_WaitIPC;
        end;
      end

      else if StrEq(SharedCmdBuffer, W('shutdown')) then
      begin
        ShellPrint(W('#10[*] Shell: Initiating System Shutdown. Sweeping workspace and signing off. Goodbye!'#10));
        ClearBuffer(SharedRespData, 8192);
        ClearBuffer(PByte(SharedNameBuffer), 512);
        App_RunCmd(SharedCmdBuffer, GuiPixels);
      end

      else if StrEq(SharedCmdBuffer, W('reboot')) then
      begin
        ShellPrint(W('#10[*] Shell: Initiating System Reboot. Sweeping workspace... See you on the other side!'#10));
        ClearBuffer(SharedRespData, 8192);
        ClearBuffer(PByte(SharedNameBuffer), 512);
        App_RunCmd(SharedCmdBuffer, GuiPixels);
      end

      else if StrEq(SharedCmdBuffer, W('mkdir')) then
        ShellPrint(W('[!] Usage: mkdir <path>'#10))

      else if StrStarts(SharedCmdBuffer, W('mkdir ')) then
      begin
        SweepMailbox;
        CopyPathToShared(SharedCmdBuffer + 6, 256);

        App_SendIPC(FAT16_PID, IPC_MKDIR_REQ, 0);
        while True do
        begin
          if (App_ReceiveIPC(@Msg[0]) = 1) and (App_MsgSender(@Msg[0]) = FAT16_PID) then
          begin
            if App_MsgType(@Msg[0]) = IPC_MKDIR_REPLY then
            begin
              if App_MsgPayload(@Msg[0]) = 1 then
                ShellPrint(W('[+] Directory Created Successfully!'#10))
              else
                ShellPrint(W('[!] Failed! Directory already exists, Access Denied or Disk Full.'#10));
              Break;
            end;
          end
          else
            App_WaitIPC;
        end;
      end

      else if StrEq(SharedCmdBuffer, W('rm')) then
        ShellPrint(W('[!] Usage: rm <path>'#10))

      else if StrStarts(SharedCmdBuffer, W('rm ')) then
      begin
        SweepMailbox;
        CopyPathToShared(SharedCmdBuffer + 3, 256);

        App_SendIPC(FAT16_PID, IPC_RM_REQ, 0);
        while True do
        begin
          if (App_ReceiveIPC(@Msg[0]) = 1) and (App_MsgSender(@Msg[0]) = FAT16_PID) then
          begin
            if App_MsgType(@Msg[0]) = IPC_RM_REPLY then
            begin
              if App_MsgPayload(@Msg[0]) = 1 then
                ShellPrint(W('[+] File Removed and Clusters Recycled!'#10))
              else if App_MsgPayload(@Msg[0]) = 2 then
                ShellPrint(W('[!] Cannot use RM on a Directory! Access Denied.'#10))
              else
                ShellPrint(W('[!] File Not Found or Access Denied.'#10));
              Break;
            end;
          end
          else
            App_WaitIPC;
        end;
      end

      else if StrEq(SharedCmdBuffer, W('rmdir')) then
        ShellPrint(W('[!] Usage: rmdir <path>'#10))

      else if StrStarts(SharedCmdBuffer, W('rmdir ')) then
      begin
        SweepMailbox;
        CopyPathToShared(SharedCmdBuffer + 6, 256);

        App_SendIPC(FAT16_PID, IPC_RMDIR_REQ, 0);
        while True do
        begin
          if (App_ReceiveIPC(@Msg[0]) = 1) and (App_MsgSender(@Msg[0]) = FAT16_PID) then
          begin
            if App_MsgType(@Msg[0]) = IPC_RMDIR_REPLY then
            begin
              if App_MsgPayload(@Msg[0]) = 1 then
                ShellPrint(W('[+] Directory and ALL its contents obliterated recursively!'#10))
              else if App_MsgPayload(@Msg[0]) = 2 then
                ShellPrint(W('[!] Target is a File. Use ''rm'' instead.'#10))
              else
                ShellPrint(W('[!] Directory Not Found or Access Denied.'#10));
              Break;
            end;
          end
          else
            App_WaitIPC;
        end;
      end

      else if StrEq(SharedCmdBuffer, W('chmod')) then
        ShellPrint(W('[!] Usage: chmod <mode> <path>'#10))

      else if StrStarts(SharedCmdBuffer, W('chmod ')) then
      begin
        SweepMailbox;
        { Split "755 /path" into mode and path. The path may itself contain
          spaces, so everything after the first token is the path. }
        if SplitTwoArgs(SharedCmdBuffer + 6, @ModeStr[0], 16, @PathBuf[0], 256) = 0 then
          ShellPrint(W('[!] Usage: chmod <mode> <path>'#10))
        else
        begin
          { UNIX semantics: the mode is octal, the daemon stores the decimal
            value, so convert here. }
          mode := OctalStrToUInt(@ModeStr[0]);
          sharedNameBuf := SharedNameBuffer;
          idx := Integer(StrCpyLimited(sharedNameBuf, @PathBuf[0], 256));
          AppendDecimal_Pas(mode, PByte(sharedNameBuf), @idx);
          sharedNameBuf[idx] := 0;

          App_SendIPC(FAT16_PID, IPC_CHMOD_REQ, 0);
          while True do
          begin
            if (App_ReceiveIPC(@Msg[0]) = 1) and (App_MsgSender(@Msg[0]) = FAT16_PID) then
            begin
              if App_MsgType(@Msg[0]) = IPC_CHMOD_REPLY then
              begin
                if App_MsgPayload(@Msg[0]) = 1 then
                  ShellPrint(W('[+] Permissions Changed Successfully!'#10))
                else
                  ShellPrint(W('[!] Failed! Not Found or Access Denied (only owner or root).'#10));
                Break;
              end;
            end
            else
              App_WaitIPC;
          end;
        end;
      end

      else if StrEq(SharedCmdBuffer, W('chown')) then
        ShellPrint(W('[!] Usage: chown <uid>:<gid> <path>'#10))

      else if StrStarts(SharedCmdBuffer, W('chown ')) then
      begin
        SweepMailbox;
        if SplitTwoArgs(SharedCmdBuffer + 6, @OwnerStr[0], 32, @PathBuf[0], 256) = 0 then
          ShellPrint(W('[!] Usage: chown <uid>:<gid> <path>'#10))
        else
        begin
          sharedNameBuf := SharedNameBuffer;
          idx := Integer(StrCpyLimited(sharedNameBuf, @PathBuf[0], 256));
          StrAppend_Pas(sharedNameBuf, @OwnerStr[0], @idx, 4096);
          sharedNameBuf[idx] := 0;

          App_SendIPC(FAT16_PID, IPC_CHOWN_REQ, 0);
          while True do
          begin
            if (App_ReceiveIPC(@Msg[0]) = 1) and (App_MsgSender(@Msg[0]) = FAT16_PID) then
            begin
              if App_MsgType(@Msg[0]) = IPC_CHOWN_REPLY then
              begin
                if App_MsgPayload(@Msg[0]) = 1 then
                  ShellPrint(W('[+] Ownership Changed Successfully!'#10))
                else
                  ShellPrint(W('[!] Failed! Not Found or Access Denied (root only).'#10));
                Break;
              end;
            end
            else
              App_WaitIPC;
          end;
        end;
      end

      else if StrEq(SharedCmdBuffer, W('sudo')) then
        ShellPrint(W('[!] Usage: sudo <app>'#10))

      else if StrStarts(SharedCmdBuffer, W('sudo ')) then
      begin
        if SharedCmdBuffer[5] = 0 then
          ShellPrint(W('[!] Usage: sudo <app>'#10))
        else
          DoSudoCmd(SharedCmdBuffer + 5);
      end

      else
        { Not a builtin: let the kernel's internal shell have it. }
        App_RunCmd(SharedCmdBuffer, GuiPixels);

      { Wipe the command line so the next prompt starts clean. }
      for i := 0 to CMD_MAX - 1 do SharedCmdBuffer[i] := 0;
    end;
  end;
end;

end.
