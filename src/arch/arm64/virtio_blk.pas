{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: virtio_blk - virtio block device over the MMIO transport.

  QEMU "virt" exposes 32 virtio-mmio slots from 0x0A000000, 0x200 apart. This
  driver speaks the modern (version 2) transport only, so QEMU must run with
  `-global virtio-mmio.force-legacy=false` (run_arm64.sh does). It is polled:
  one request in flight, completion found by watching the used ring. That is
  enough to read and write sectors; interrupts and a request queue come when
  a filesystem needs them.

  Memory handed to the device is identity-mapped kernel memory, so virtual and
  physical addresses are the same.
  =========================================================================
}
unit virtio_blk;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

const
  VIRTIO_SECTOR_SIZE = 512;

{ Find a block device and bring it up. False when there is none or it cannot
  be driven (legacy transport, no VERSION_1, queue too small). }
function VirtioBlk_Init: Boolean;

function VirtioBlk_Capacity: QWord;                  { in 512-byte sectors }

{ Transfer `count` whole sectors starting at `sector` between the disk and
  `buf` (kernel memory, count * 512 bytes). False on a device error. }
function VirtioBlk_Read(sector: QWord; count: Cardinal; buf: Pointer): Boolean;
function VirtioBlk_Write(sector: QWord; count: Cardinal; buf: Pointer): Boolean;

implementation

uses arch_interface, pmm;

const
  MMIO_BASE   = QWord($0A000000);
  MMIO_STRIDE = $200;
  MMIO_SLOTS  = 32;

  R_MAGIC = $000;   R_VERSION = $004;  R_DEVICE = $008;
  R_DEV_FEATURES = $010;  R_DEV_FEATURES_SEL = $014;
  R_DRV_FEATURES = $020;  R_DRV_FEATURES_SEL = $024;
  R_QUEUE_SEL = $030;  R_QUEUE_NUM_MAX = $034;  R_QUEUE_NUM = $038;
  R_QUEUE_READY = $044;  R_QUEUE_NOTIFY = $050;
  R_STATUS = $070;
  R_DESC_LO = $080;  R_DESC_HI = $084;
  R_AVAIL_LO = $090;  R_AVAIL_HI = $094;
  R_USED_LO = $0A0;  R_USED_HI = $0A4;
  R_CONFIG = $100;

  STATUS_ACK = 1;  STATUS_DRIVER = 2;  STATUS_DRIVER_OK = 4;
  STATUS_FEATURES_OK = 8;  STATUS_FAILED = $80;

  VIRTIO_MAGIC = $74726976;       { 'virt' }
  DEVICE_BLOCK = 2;

  QUEUE_SIZE = 8;
  { One page holds the rings: descriptors at 0, available ring at 256, used
    ring at 512; the request header and status byte live in the second half. }
  OFF_AVAIL = 256;
  OFF_USED  = 512;
  OFF_REQ   = 1024;               { 16-byte header, then 1 status byte at +16 }

  DESC_F_NEXT = 1;
  DESC_F_WRITE = 2;               { device writes this buffer }

  T_IN = 0;
  T_OUT = 1;

  POLL_LIMIT = 50000000;

var
  Base: QWord = 0;
  Ring: PByte = nil;
  LastUsed: Word = 0;
  AvailIdx: Word = 0;
  Capacity: QWord = 0;

function Rd(reg: Cardinal): Cardinal;
begin
  Rd := Arch_ReadMmio32(Base + reg);
end;

procedure Wr(reg, v: Cardinal);
begin
  Arch_WriteMmio32(Base + reg, v);
end;

function VirtioBlk_Capacity: QWord;
begin
  VirtioBlk_Capacity := Capacity;
end;

function VirtioBlk_Init: Boolean;
var
  slot: Integer;
  addr: QWord;
  st, feat: Cardinal;
  i: Integer;
begin
  VirtioBlk_Init := False;
  Base := 0;
  for slot := 0 to MMIO_SLOTS - 1 do
  begin
    addr := MMIO_BASE + QWord(slot) * MMIO_STRIDE;
    if (Arch_ReadMmio32(addr + R_MAGIC) = VIRTIO_MAGIC) and
       (Arch_ReadMmio32(addr + R_DEVICE) = DEVICE_BLOCK) then
    begin
      Base := addr;
      Break;
    end;
  end;
  if Base = 0 then Exit;
  if Rd(R_VERSION) <> 2 then begin Base := 0; Exit; end;       { legacy transport }

  Wr(R_STATUS, 0);                                  { reset }
  Wr(R_STATUS, STATUS_ACK);
  Wr(R_STATUS, STATUS_ACK or STATUS_DRIVER);

  { Features: only VIRTIO_F_VERSION_1 (bit 32 = bit 0 of the high word). }
  Wr(R_DEV_FEATURES_SEL, 1);
  feat := Rd(R_DEV_FEATURES);
  if (feat and 1) = 0 then begin Wr(R_STATUS, STATUS_FAILED); Base := 0; Exit; end;
  Wr(R_DRV_FEATURES_SEL, 0);  Wr(R_DRV_FEATURES, 0);
  Wr(R_DRV_FEATURES_SEL, 1);  Wr(R_DRV_FEATURES, 1);
  Wr(R_STATUS, STATUS_ACK or STATUS_DRIVER or STATUS_FEATURES_OK);
  if (Rd(R_STATUS) and STATUS_FEATURES_OK) = 0 then begin Base := 0; Exit; end;

  Wr(R_QUEUE_SEL, 0);
  if (Rd(R_QUEUE_READY) <> 0) or (Rd(R_QUEUE_NUM_MAX) < QUEUE_SIZE) then
  begin Wr(R_STATUS, STATUS_FAILED); Base := 0; Exit; end;
  Wr(R_QUEUE_NUM, QUEUE_SIZE);

  Ring := PByte(Pmm_AllocatePage);                  { zero-filled }
  if Ring = nil then begin Base := 0; Exit; end;
  Wr(R_DESC_LO, Cardinal(QWord(Ring)));                Wr(R_DESC_HI, Cardinal(QWord(Ring) shr 32));
  Wr(R_AVAIL_LO, Cardinal(QWord(Ring) + OFF_AVAIL));   Wr(R_AVAIL_HI, Cardinal((QWord(Ring) + OFF_AVAIL) shr 32));
  Wr(R_USED_LO, Cardinal(QWord(Ring) + OFF_USED));     Wr(R_USED_HI, Cardinal((QWord(Ring) + OFF_USED) shr 32));
  Wr(R_QUEUE_READY, 1);

  Wr(R_STATUS, STATUS_ACK or STATUS_DRIVER or STATUS_FEATURES_OK or STATUS_DRIVER_OK);

  { Config space: capacity in sectors (u64, little-endian). }
  Capacity := QWord(Rd(R_CONFIG)) or (QWord(Rd(R_CONFIG + 4)) shl 32);
  LastUsed := 0;
  AvailIdx := 0;
  VirtioBlk_Init := True;
end;

{ One request: header descriptor, data descriptor, status descriptor. }
function Transfer(isWrite: Boolean; sector: QWord; count: Cardinal; buf: Pointer): Boolean;
var
  desc: PQWord;
  hdr: PCardinal;
  status: PByte;
  avail, used: PWord;
  spins: Cardinal;
  dflags: Word;
begin
  Transfer := False;
  if (Base = 0) or (count = 0) or (buf = nil) then Exit;
  if (sector > Capacity) or (QWord(count) > Capacity - sector) then Exit;
  if QWord(count) * VIRTIO_SECTOR_SIZE > $FFFFFFFF then Exit;

  hdr := PCardinal(Ring + OFF_REQ);
  status := Ring + OFF_REQ + 16;
  if isWrite then hdr[0] := T_OUT else hdr[0] := T_IN;
  hdr[1] := 0;
  hdr[2] := Cardinal(sector);
  hdr[3] := Cardinal(sector shr 32);
  status^ := $FF;

  desc := PQWord(Ring);
  { Descriptor 0: request header (device reads). }
  desc[0] := QWord(hdr);
  desc[1] := QWord(16) or (QWord(DESC_F_NEXT) shl 32) or (QWord(1) shl 48);
  { Descriptor 1: the data (device writes it for a read). }
  if isWrite then dflags := DESC_F_NEXT else dflags := DESC_F_NEXT or DESC_F_WRITE;
  desc[2] := QWord(buf);
  desc[3] := QWord(count * VIRTIO_SECTOR_SIZE) or (QWord(dflags) shl 32) or (QWord(2) shl 48);
  { Descriptor 2: status byte (device writes). }
  desc[4] := QWord(status);
  desc[5] := QWord(1) or (QWord(DESC_F_WRITE) shl 32);

  avail := PWord(Ring + OFF_AVAIL);
  used := PWord(Ring + OFF_USED);
  avail[2 + (AvailIdx mod QUEUE_SIZE)] := 0;        { ring[idx] = head descriptor 0 }
  Arch_FullFence;
  Inc(AvailIdx);
  avail[1] := AvailIdx;                             { idx }
  Arch_FullFence;
  Wr(R_QUEUE_NOTIFY, 0);

  spins := 0;
  while used[1] = LastUsed do
  begin
    Arch_FullFence;
    Inc(spins);
    if spins > POLL_LIMIT then Exit;                 { device never answered }
  end;
  Inc(LastUsed);
  Arch_FullFence;
  Transfer := status^ = 0;
end;

function VirtioBlk_Read(sector: QWord; count: Cardinal; buf: Pointer): Boolean;
begin
  VirtioBlk_Read := Transfer(False, sector, count, buf);
end;

function VirtioBlk_Write(sector: QWord; count: Cardinal; buf: Pointer): Boolean;
begin
  VirtioBlk_Write := Transfer(True, sector, count, buf);
end;

end.
