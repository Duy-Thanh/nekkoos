{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: boot_arm64 - first Pascal code on ARM64 (called from start.S).

  Bring-up milestone 1: prove the toolchain, the link and the HAL by
  printing on the PL011 UART and reading the counter. This grows into
  KernelMain one HAL phase at a time.
  =========================================================================
}
unit boot_arm64;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

procedure Arm64Main; cdecl;

implementation

uses arch_interface, arch_hal, pmm, fdt, scheduler, heap, kernel_core, ipc_kernel, elf_loader, ata_kernel, fat16_kernel, kstring;

var
  UserHelloStart: Byte; external name 'user_hello_start';
  UserHelloEnd: Byte; external name 'user_hello_end';
  UserCrashStart: Byte; external name 'user_crash_start';
  UserCrashEnd: Byte; external name 'user_crash_end';
  UserMmioStart: Byte; external name 'user_mmio_start';
  UserMmioEnd: Byte; external name 'user_mmio_end';
  UserVblkStart: Byte; external name 'user_vblk_start';
  UserVblkEnd: Byte; external name 'user_vblk_end';
  UserFat16Start: Byte; external name 'user_fat16_start';
  UserFat16End: Byte; external name 'user_fat16_end';
  UserSnoopStart: Byte; external name 'user_snoop_start';
  UserSnoopEnd: Byte; external name 'user_snoop_end';

var
  Arm64_DtbPhys: QWord; external name 'Arm64_DtbPhys';
  KernelEndMarker: Byte; external name '__stack_top';

var
  { One EFI_MEMORY_DESCRIPTOR (48 bytes) describing the free RAM; this is the
    format the generic Pmm_Init consumes. }
  MemMap: array[0..5] of QWord;

procedure Puts(s: PChar);
begin
  while s^ <> #0 do
  begin
    if s^ = #10 then Arch_WriteMmio32(QWord($09000000), 13);
    Arch_WriteMmio32(QWord($09000000), Ord(s^));
    Inc(s);
  end;
end;

procedure PutDec(v: QWord);
var
  buf: array[0..19] of Byte;
  n: Integer;
begin
  n := 0;
  repeat
    buf[n] := Ord('0') + (v mod 10);
    v := v div 10;
    Inc(n);
  until v = 0;
  while n > 0 do
  begin
    Dec(n);
    Arch_WriteMmio32(QWord($09000000), buf[n]);
  end;
end;

{ Create a user space, map a page in it, write through the mapping, switch
  back and tear it down; the free page count must return to what it was. }
procedure CheckAddressSpaces;
const
  VA = QWord($100000000);          { 4 GiB: a slot the kernel does not use }
var
  space, page, before: QWord;
  p: PCardinal;
begin
  before := Pmm_GetFreePages;
  space := Hal_CreateUserAddressSpace;
  page := QWord(Pmm_AllocatePage);
  Hal_MapPageIn(page, VA, HAL_MAP_KERNEL_RW, space);
  Hal_ActivateAddressSpace(space);
  p := PCardinal(VA);
  p^ := $C0FFEE;
  Hal_ActivateAddressSpace(Hal_KernelAddressSpace);
  if (PCardinal(page)^ = $C0FFEE) and Hal_AddressSpaceValid(space) then
    Puts('arm64: address space map/switch OK, ')
  else
    Puts('arm64: address space map/switch FAILED, ');
  Hal_DestroyAddressSpace(space);
  PutDec(before - Pmm_GetFreePages);
  Puts(' pages leaked'#10);
end;

{ Each thread prints its letter once per timer tick it observes, for about two
  seconds; the output alternating AB proves the timer interrupt really switches
  between them. Then it ends, so the busy loop does not slow the daemons. }
procedure Spin(letter: Byte);
var
  last, now, stop: QWord;
begin
  last := Hal_Ticks;
  stop := last + Hal_MsToTicks(2000);
  while Hal_Ticks < stop do
  begin
    now := Hal_Ticks;
    if now <> last then
    begin
      Arch_WriteMmio32(QWord($09000000), letter);
      last := now;
    end;
  end;
  Sched_TerminateCurrentTask;
end;

procedure ThreadA;
begin
  Spin(Ord('A'));
end;

procedure ThreadB;
begin
  Spin(Ord('B'));
end;

{ Services check: allocate and free from the kernel heap, and pass one IPC
  message through the generic mailbox code. }
procedure CheckServices;
var
  a, b: PByte;
  t, snd: Cardinal;
  pay: QWord;
  ok: Boolean;
begin
  a := Heap_Alloc(100);
  b := Heap_Alloc(5000);
  ok := (a <> nil) and (b <> nil) and (a <> b);
  if ok then
  begin
    a[0] := $5A; a[99] := $A5; b[0] := $11; b[4999] := $22;
    ok := (a[0] = $5A) and (a[99] = $A5) and (b[0] = $11) and (b[4999] = $22);
  end;
  Heap_Free(a);
  Heap_Free(b);
  if ok then Puts('arm64: heap alloc/free OK'#10) else Puts('arm64: heap FAILED'#10);

  t := 0; snd := 0; pay := 0;
  ok := IpcK_Send(77, 0, 0, 1234) and IpcK_ReceiveForRaw(0, t, snd, pay) and
        (t = 77) and (pay = 1234);
  if ok then Puts('arm64: ipc send/receive OK'#10) else Puts('arm64: ipc FAILED'#10);
end;

const
  HelloName: array[0..5] of Word = (72, 69, 76, 76, 79, 0);          { HELLO }
  CrashName: array[0..5] of Word = (67, 82, 65, 83, 72, 0);          { CRASH }
  MmioName: array[0..4] of Word = (77, 77, 73, 79, 0);              { MMIO }
  { The disk and filesystem daemons run under their role names, the names the
    x86 daemons have, so FAT16.EXE finds the disk daemon by asking for ATA.EXE. }
  AtaRoleName: array[0..7] of Word = (65, 84, 65, 46, 69, 88, 69, 0);       { ATA.EXE }
  FatRoleName: array[0..9] of Word = (70, 65, 84, 49, 54, 46, 69, 88, 69, 0); { FAT16.EXE }
  LoaderName: array[0..6] of Word = (76, 79, 65, 68, 69, 82, 0);           { LOADER }
  SnoopName: array[0..5] of Word = (83, 78, 79, 79, 80, 0);         { SNOOP }

var
  SpawnedAta: Integer = -1;
  SpawnedFat: Integer = -1;

{ Kernel thread that brings the filesystem up and loads from it. It, and only
  it, reads thread 0's mailbox for the daemons' handshakes (one receiver per
  mailbox, AGENTS.md 15.0). File reads go through FAT16.EXE -> ATA.EXE over
  IPC because this thread is not thread 0 (thread 0 would take the raw path,
  which needs a kernel disk driver ARM64 does not have). }
procedure LoaderThread;
const
  DEADLINE_MS = 20000;
var
  t, snd: Cardinal;
  pay, start: QWord;
  data: PByte;
  size, i: Cardinal;
  t0: QWord;
  ok: Boolean;
begin
  start := Hal_Ticks;
  while not (Ata_GetUseDaemon and Fat16K_GetUseDaemon) do
  begin
    t := 0; snd := 0; pay := 0;
    while IpcK_ReceiveForRaw(0, t, snd, pay) do
      if (t = 9) and (Integer(snd) = SpawnedAta) then Ata_SetUseDaemon(True)
      else if (t = 39) and (Integer(snd) = SpawnedFat) then
      begin
        Fat16K_SetDaemonId(snd);
        Fat16K_SetUseDaemon(True);
      end;
    if Hal_Ticks - start > Hal_MsToTicks(DEADLINE_MS) then
    begin
      Puts('arm64: TIMEOUT waiting for the disk/filesystem daemons'#10);
      Sched_TerminateCurrentTask;
    end;
    Sched_Yield;
  end;
  Puts('arm64: ATA.EXE (virtio) and FAT16.EXE are up'#10);

  size := 0;
  data := Fat16K_ReadFile(W('HELLO.TXT'), @size, -1);
  if (data <> nil) and (size > 0) then
  begin
    Puts('arm64: HELLO.TXT from disk: ');
    for i := 0 to size - 1 do
      if data[i] >= 32 then Arch_WriteMmio32(QWord($09000000), data[i]);
    Puts(#10);
    Heap_Free(data);
  end
  else
    Puts('arm64: reading HELLO.TXT FAILED'#10);

  size := 0;
  data := Fat16K_ReadFile(W('DISKAPP.ELF'), @size, -1);
  if (data <> nil) and (size > 0) then
  begin
    if ElfLoader_Spawn(data, size, True, False, True,
       W('DISKAPP'), 5) < 0 then
      Puts('arm64: DISKAPP.ELF rejected by the loader'#10);
    Heap_Free(data);
  end
  else
    Puts('arm64: reading DISKAPP.ELF FAILED'#10);
  size := 0;
  data := Fat16K_ReadFile(W('ECHO.ELF'), @size, -1);
  if (data <> nil) and (size > 0) then
  begin
    if ElfLoader_Spawn(data, size, False, False, True,
       W('ECHO'), 5) < 0 then
      Puts('arm64: ECHO.ELF rejected by the loader'#10);
    Heap_Free(data);
  end
  else
    Puts('arm64: reading ECHO.ELF FAILED'#10);

  { Throughput: a 64 KiB file through FAT16.EXE -> ATA.EXE. }
  size := 0;
  t0 := Hal_Ticks;
  data := Fat16K_ReadFile(W('BIG.BIN'), @size, -1);
  t0 := Hal_Ticks - t0;
  if (data <> nil) and (size = 65536) then
  begin
    ok := True;
    for i := 0 to size - 1 do ok := ok and (data[i] = Byte(i mod 251));
    if ok then Puts('arm64: BIG.BIN 64 KiB read OK in ') else Puts('arm64: BIG.BIN content WRONG, ');
    PutDec(t0 * 1000 div Hal_TickFrequency);
    Puts(' ms'#10);
    Heap_Free(data);
  end
  else
    Puts('arm64: reading BIG.BIN FAILED'#10);

  { The context-switch demo runs last so its output does not interleave with
    the lines above. }
  Puts('arm64: scheduler demo'#10);
  Sched_CreateTask(QWord(@ThreadA));
  Sched_CreateTask(QWord(@ThreadB));
  Sched_TerminateCurrentTask;
end;

procedure Arm64Main; cdecl; public name 'Arm64Main';
var
  t0, ramBase, ramSize, freeStart, ramEnd: QWord;
  tid: Integer;
begin
  Hal_EarlyInit;
  if not Fdt_FindMemory(PByte(Arm64_DtbPhys), ramBase, ramSize) then
  begin
    Puts('arm64: no /memory node in the device tree, dtb at '); PutDec(Arm64_DtbPhys); Puts(' magic '); PutDec(PCardinal(Arm64_DtbPhys)^); Puts(#10);
    while True do Arch_Halt;
  end;
  ramEnd := ramBase + ramSize;
  { Free RAM starts after the kernel image and its boot stack. }
  freeStart := (QWord(@KernelEndMarker) + 4095) and not QWord(4095);
  MemMap[0] := 7;                                   { EfiConventionalMemory }
  MemMap[1] := freeStart;                           { PhysicalStart }
  MemMap[2] := 0;
  MemMap[3] := (ramEnd - freeStart) div 4096;       { NumberOfPages }
  MemMap[4] := 0;
  MemMap[5] := 0;
  Pmm_Init(PByte(@MemMap), 48, 48, freeStart);
  Puts('arm64: RAM ');
  PutDec(ramSize div (1024 * 1024));
  Puts(' MiB, ');
  PutDec(Pmm_GetFreePages);
  Puts(' free pages'#10);
  Hal_InitMemory(ramEnd);
  Heap_Init;
  Puts('arm64: MMU on, kernel address space at ');
  PutDec(Hal_KernelAddressSpace);
  Puts(#10);
  t0 := Hal_Ticks;
  while Hal_Ticks < t0 + Hal_MsToTicks(100) do ;
  CheckAddressSpaces;
  Hal_InitInterrupts;
  Hal_StartTimer(Hal_TickFrequency);
  Hal_EnableInterrupts;
  t0 := Hal_Ticks;
  while Hal_Ticks < t0 + Hal_MsToTicks(1000) do Arch_Halt;
  Puts('arm64: timer interrupts in 1 s: ');
  PutDec(Arm64_TimerInterrupts);
  Puts(#10);
  Puts('arm64: 100 ms elapsed on the generic counter, core id ');
  Arch_WriteMmio32(QWord($09000000), Ord('0') + Hal_CurrentCoreId);
  Puts(#10'arm64: bring-up milestone 1 reached'#10);
  { From here the boot thread is just thread 0, the idle task. }
  Arch_DisableInterrupts;
  Kernel_InitServices;
  CheckServices;
  Puts('arm64: scheduler started'#10);
  if ElfLoader_Spawn(@UserHelloStart, QWord(@UserHelloEnd) - QWord(@UserHelloStart), True, False, True,
       PWord(@HelloName[0]), 5) < 0 then Puts('arm64: could not start hello'#10);
  if ElfLoader_Spawn(@UserCrashStart, QWord(@UserCrashEnd) - QWord(@UserCrashStart), True, False, True,
       PWord(@CrashName[0]), 5) < 0 then Puts('arm64: could not start crash'#10);
  if ElfLoader_Spawn(@UserMmioStart, QWord(@UserMmioEnd) - QWord(@UserMmioStart), True, False, True,
       PWord(@MmioName[0]), 5) < 0 then Puts('arm64: could not start mmio'#10);
  { The disk daemon, then a client standing in for the FAT16 daemon. }
  { Both daemon ids come from the spawn, never from a handshake. }
  SpawnedAta := ElfLoader_Spawn(@UserVblkStart, QWord(@UserVblkEnd) - QWord(@UserVblkStart), True, False, True,
       PWord(@AtaRoleName[0]), 3);
  if SpawnedAta < 0 then Puts('arm64: could not start the disk daemon'#10);
  SpawnedFat := ElfLoader_Spawn(@UserFat16Start, QWord(@UserFat16End) - QWord(@UserFat16Start), True, False, True,
       PWord(@FatRoleName[0]), 3);
  if SpawnedFat < 0 then Puts('arm64: could not start the filesystem daemon'#10)
  else Fat16K_SetTrustedThreadId(SpawnedFat);
  { Enforce "only FAT16.EXE talks to the disk daemon" only now that FAT16's id
    is known: it may already be running and reading the boot sector (same
    ordering as x86 kernel_main). }
  if SpawnedAta > 0 then Ata_SetDaemonId(Cardinal(SpawnedAta));
  Sched_CreateTask(QWord(@LoaderThread));
  if ElfLoader_Spawn(@UserSnoopStart, QWord(@UserSnoopEnd) - QWord(@UserSnoopStart), True, False, True,
       PWord(@SnoopName[0]), 5) < 0 then Puts('arm64: could not start snoop'#10);
  Arch_EnableInterrupts;
  Kernel_IdleLoop;
end;

end.
