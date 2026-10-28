{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: vblk_daemon - the ARM64 disk daemon (EL0), virtio-blk over MMIO.

  Plays the role ATA.EXE plays on x86 and speaks its IPC protocol, so the
  filesystem daemon and the kernel need not know which controller is behind
  the disk:
    in  10/12/14  read / write / flush one sector, payload = LBA
    out 11/13/15  success (read/write carry the shared window address)
    out 111       failure
    out 9         handshake to thread 0, sent FIRST (AGENTS.md 12.4)
  The sector travels through the global shared window at offset 16384
  (AtaRawBuffer in the x86 layout).

  The kernel only provides mechanism: MapPhys for the device registers and
  AllocDma for memory the device reads and writes. Modern (version 2)
  transport only; polled, one request in flight.
  =========================================================================
}
unit vblk_daemon;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

procedure AppMain; cdecl;

implementation

uses uapi, kstring;

const
  IPC_READY = 9;
  IPC_READ = 10;  IPC_READ_DONE = 11;
  IPC_WRITE = 12; IPC_WRITE_DONE = 13;
  IPC_FLUSH = 14; IPC_FLUSH_DONE = 15;
  IPC_ERROR = 111;
  IPC_SIGTERM = $DEAD;

  RAW_OFFSET = 4096 + 4096 + 8192;    { AtaRawBuffer in the shared window }
  SECTOR = 512;

  MMIO_PHYS = QWord($0A000000);
  MMIO_PAGES = 4;                     { 32 slots x 0x200 }
  MMIO_STRIDE = $200;
  MMIO_SLOTS = 32;

  R_MAGIC = $000;  R_VERSION = $004;  R_DEVICE = $008;
  R_DEV_FEATURES = $010;  R_DEV_FEATURES_SEL = $014;
  R_DRV_FEATURES = $020;  R_DRV_FEATURES_SEL = $024;
  R_QUEUE_SEL = $030;  R_QUEUE_NUM_MAX = $034;  R_QUEUE_NUM = $038;
  R_QUEUE_READY = $044;  R_QUEUE_NOTIFY = $050;  R_STATUS = $070;
  R_DESC_LO = $080;  R_DESC_HI = $084;  R_AVAIL_LO = $090;  R_AVAIL_HI = $094;
  R_USED_LO = $0A0;  R_USED_HI = $0A4;  R_CONFIG = $100;

  ST_ACK = 1;  ST_DRIVER = 2;  ST_DRIVER_OK = 4;  ST_FEATURES_OK = 8;  ST_FAILED = $80;

  QUEUE_SIZE = 8;
  OFF_AVAIL = 256;  OFF_USED = 512;  OFF_REQ = 1024;   { inside the ring page }
  DESC_F_NEXT = 1;  DESC_F_WRITE = 2;
  T_IN = 0;  T_OUT = 1;
  POLL_LIMIT = 50000000;

var
  Regs: QWord = 0;                    { user address of the device's registers }
  Ring: PByte = nil;  RingPhys: QWord = 0;
  Data: PByte = nil;  DataPhys: QWord = 0;
  Capacity: QWord = 0;
  AvailIdx: Word = 0;
  LastUsed: Word = 0;

function Rd(reg: Cardinal): Cardinal;
begin
  Rd := PCardinal(Regs + reg)^;
end;

procedure Wr(reg, v: Cardinal);
begin
  PCardinal(Regs + reg)^ := v;
end;

function Probe(window: QWord): Boolean;
var
  slot: Integer;
begin
  Probe := False;
  for slot := 0 to MMIO_SLOTS - 1 do
  begin
    Regs := window + QWord(slot) * MMIO_STRIDE;
    if (Rd(R_MAGIC) = $74726976) and (Rd(R_DEVICE) = 2) then
    begin
      Probe := Rd(R_VERSION) = 2;
      Exit;
    end;
  end;
  Regs := 0;
end;

function InitDevice: Boolean;
begin
  InitDevice := False;
  Wr(R_STATUS, 0);
  Wr(R_STATUS, ST_ACK);
  Wr(R_STATUS, ST_ACK or ST_DRIVER);
  Wr(R_DEV_FEATURES_SEL, 1);
  if (Rd(R_DEV_FEATURES) and 1) = 0 then begin Wr(R_STATUS, ST_FAILED); Exit; end;
  Wr(R_DRV_FEATURES_SEL, 0);  Wr(R_DRV_FEATURES, 0);
  Wr(R_DRV_FEATURES_SEL, 1);  Wr(R_DRV_FEATURES, 1);      { VIRTIO_F_VERSION_1 only }
  Wr(R_STATUS, ST_ACK or ST_DRIVER or ST_FEATURES_OK);
  if (Rd(R_STATUS) and ST_FEATURES_OK) = 0 then Exit;
  Wr(R_QUEUE_SEL, 0);
  if (Rd(R_QUEUE_READY) <> 0) or (Rd(R_QUEUE_NUM_MAX) < QUEUE_SIZE) then
  begin Wr(R_STATUS, ST_FAILED); Exit; end;
  Wr(R_QUEUE_NUM, QUEUE_SIZE);
  Wr(R_DESC_LO, Cardinal(RingPhys));                Wr(R_DESC_HI, Cardinal(RingPhys shr 32));
  Wr(R_AVAIL_LO, Cardinal(RingPhys + OFF_AVAIL));   Wr(R_AVAIL_HI, Cardinal((RingPhys + OFF_AVAIL) shr 32));
  Wr(R_USED_LO, Cardinal(RingPhys + OFF_USED));     Wr(R_USED_HI, Cardinal((RingPhys + OFF_USED) shr 32));
  Wr(R_QUEUE_READY, 1);
  Wr(R_STATUS, ST_ACK or ST_DRIVER or ST_FEATURES_OK or ST_DRIVER_OK);
  Capacity := QWord(Rd(R_CONFIG)) or (QWord(Rd(R_CONFIG + 4)) shl 32);
  InitDevice := True;
end;

{ One sector between the device and Data. The device sees physical addresses;
  this program sees the same memory through Ring/Data. }
function Transfer(isWrite: Boolean; lba: QWord): Boolean;
var
  desc: PQWord;
  hdr: PCardinal;
  status: PByte;
  avail: PWord;
  spins: Cardinal;
  dflags: Word;
begin
  Transfer := False;
  if lba >= Capacity then Exit;
  hdr := PCardinal(Ring + OFF_REQ);
  status := Ring + OFF_REQ + 16;
  if isWrite then hdr[0] := T_OUT else hdr[0] := T_IN;
  hdr[1] := 0;
  hdr[2] := Cardinal(lba);
  hdr[3] := Cardinal(lba shr 32);
  status^ := $FF;

  desc := PQWord(Ring);
  desc[0] := RingPhys + OFF_REQ;
  desc[1] := QWord(16) or (QWord(DESC_F_NEXT) shl 32) or (QWord(1) shl 48);
  if isWrite then dflags := DESC_F_NEXT else dflags := DESC_F_NEXT or DESC_F_WRITE;
  desc[2] := DataPhys;
  desc[3] := QWord(SECTOR) or (QWord(dflags) shl 32) or (QWord(2) shl 48);
  desc[4] := RingPhys + OFF_REQ + 16;
  desc[5] := QWord(1) or (QWord(DESC_F_WRITE) shl 32);

  avail := PWord(Ring + OFF_AVAIL);
  avail[2 + (AvailIdx mod QUEUE_SIZE)] := 0;
  U_Fence;
  Inc(AvailIdx);
  avail[1] := AvailIdx;
  U_Fence;
  Wr(R_QUEUE_NOTIFY, 0);

  spins := 0;
  while PWord(Ring + OFF_USED + 2)^ = LastUsed do
  begin
    U_Fence;
    Inc(spins);
    if spins > POLL_LIMIT then Exit;
  end;
  Inc(LastUsed);
  U_Fence;
  Transfer := status^ = 0;
end;

procedure AppMain; cdecl; public name 'AppMain';
var
  shared, window: QWord;
  raw: PByte;
  msg: array[0..MSG_SIZE - 1] of Byte;
  client, kind: Cardinal;
  lba: QWord;
  i: Integer;
begin
  { Handshake before anything else can fail or block (AGENTS.md 12.4). }
  shared := U_GetSharedMem;
  U_SendIPC(0, IPC_READY, shared);
  if shared = 0 then
  begin
    U_Print(W('[!] VBLK: no shared window'#13#10));
    U_Exit;
  end;
  raw := PByte(shared + RAW_OFFSET);

  window := U_MapPhys(MMIO_PHYS, MMIO_PAGES);
  Ring := PByte(U_AllocDma(1, RingPhys));
  Data := PByte(U_AllocDma(1, DataPhys));
  if (window = 0) or (Ring = nil) or (Data = nil) or (not Probe(window)) or
     (not InitDevice) then
  begin
    U_Print(W('[!] VBLK: no usable virtio-blk device'#13#10));
    U_Exit;
  end;
  U_Print(W('[+] VBLK daemon (EL0) ready, sectors: '));
  U_PrintDec(Capacity);
  U_Print(W(#13#10));

  while True do
  begin
    if not U_ReceiveIPC(@msg[0]) then
    begin
      U_Yield;
      Continue;
    end;
    client := U_MsgSender(@msg[0]);
    kind := U_MsgType(@msg[0]);
    lba := U_MsgPayload(@msg[0]);

    if kind = IPC_SIGTERM then
      U_Exit
    else if kind = IPC_READ then
    begin
      if Transfer(False, lba) then
      begin
        for i := 0 to SECTOR - 1 do raw[i] := Data[i];
        U_SendIPC(client, IPC_READ_DONE, shared);
      end
      else
        U_SendIPC(client, IPC_ERROR, 0);
    end
    else if kind = IPC_WRITE then
    begin
      for i := 0 to SECTOR - 1 do Data[i] := raw[i];
      if Transfer(True, lba) then
        U_SendIPC(client, IPC_WRITE_DONE, shared)
      else
        U_SendIPC(client, IPC_ERROR, 0);
    end
    else if kind = IPC_FLUSH then
      { VIRTIO_BLK_F_FLUSH is not negotiated, so the device writes through. }
      U_SendIPC(client, IPC_FLUSH_DONE, 0)
    else
      U_SendIPC(client, IPC_ERROR, 0);
  end;
end;

end.
