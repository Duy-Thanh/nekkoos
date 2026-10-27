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

uses arch_interface, arch_hal, pmm, fdt, scheduler, heap, kernel_core, ipc_kernel;

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

{ Each thread prints its letter once per timer tick it observes; the output
  alternating AB proves the timer interrupt really switches between them. }
procedure Spin(letter: Byte);
var
  last, now: QWord;
begin
  last := Hal_Ticks;
  while True do
  begin
    now := Hal_Ticks;
    if now <> last then
    begin
      Arch_WriteMmio32(QWord($09000000), letter);
      last := now;
    end;
  end;
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

procedure Arm64Main; cdecl; public name 'Arm64Main';
var
  t0, ramBase, ramSize, freeStart, ramEnd: QWord;
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
  Sched_CreateTask(QWord(@ThreadA));
  Sched_CreateTask(QWord(@ThreadB));
  Puts('arm64: scheduler started'#10);
  Arch_EnableInterrupts;
  Kernel_IdleLoop;
end;

end.
