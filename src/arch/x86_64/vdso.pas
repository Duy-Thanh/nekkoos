{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: vdso - vDSO gateway: hand-written syscall stubs in RAM.
  PORTED FROM: src/arch/x86_64/vDSO.cs (deleted).

  Userland apps never call into the kernel directly. Instead they read a
  table of offsets from a fixed vDSO page and jump to the stub at that
  offset. Each stub is a few bytes of hand-assembled machine code that sets
  RAX to the syscall number and traps with INT 0x80.

  This is what makes KASLR work: the kernel base is randomised every boot,
  so no absolute kernel address is ever baked into an app. The vDSO page is
  the only fixed rendezvous point.

  LAYOUT (one 4 KiB page):
      +0    .. +4095  table of QWord offsets into the code region (slot n)
      +512           first stub
  The table stores (512 + (code - (page + 512))), i.e. the stub's offset
  from the page base, because userland adds the vDSO physical base itself.

  SLOT ORDER IS AN ABI: apps index this table by slot number, and the
  mapping is documented in AGENTS.md §4.1. Changing the order silently
  redirects every app's syscalls. Append only, never reorder.
  =========================================================================
}

unit vdso;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

interface

{ Base of the vDSO page; userland adds its table offsets to this. }
function Vdso_GetPhysPage: QWord;

{ Number of published slots, i.e. how far userland may index the table. }
function Vdso_GetSlotCount: Cardinal;

{ Address of the Nth stub relative to the vDSO page base. }
function Vdso_GetSlotOffset(index: Cardinal): QWord;

procedure Vdso_Init;

implementation

uses pmm, libc, terminal, kstring;

const
  VDSO_CODE_OFFSET = 512;      { where the stub region starts }
  VDSO_PAGE_SIZE   = 4096;
  VDSO_MAX_SLOTS   = 64;

var
  Vdso_PhysPage: QWord = 0;
  Vdso_Table: PQWord = nil;
  Vdso_Code: PByte = nil;
  Vdso_FuncIndex: Cardinal = 0;

function Vdso_GetPhysPage: QWord;
begin
  Vdso_GetPhysPage := Vdso_PhysPage;
end;

function Vdso_GetSlotCount: Cardinal;
begin
  Vdso_GetSlotCount := Vdso_FuncIndex;
end;

function Vdso_GetSlotOffset(index: Cardinal): QWord;
begin
  if (index >= Vdso_FuncIndex) or (Vdso_Table = nil) then
  begin
    Vdso_GetSlotOffset := 0;
    Exit;
  end;
  Vdso_GetSlotOffset := Vdso_Table[index];
end;

{ Publish the stub that is about to be written: the table entry records the
  offset of the current code pointer, so it must be taken BEFORE emitting
  the bytes. }
function BeginStub: QWord; inline;
begin
  Vdso_Table[Vdso_FuncIndex] := QWord(VDSO_CODE_OFFSET) + QWord(PByte(Vdso_Code) - PByte(Vdso_PhysPage + VDSO_CODE_OFFSET));
  Inc(Vdso_FuncIndex);
  BeginStub := 0;
end;

procedure Emit(b: Byte); inline;
begin
  Vdso_Code^ := b;
  Inc(Vdso_Code);
end;

procedure EmitDword(v: Cardinal); inline;
begin
  PCardinal(Vdso_Code)^ := v;
  Inc(Vdso_Code, 4);
end;

{ mov rax, <id> ; int 0x80 ; ret }
procedure AddSyscall(raxId: Cardinal);
begin
  BeginStub;
  Emit($48); Emit($C7); Emit($C0);        { mov rax, imm32 }
  EmitDword(raxId);
  Emit($CD); Emit($80);                   { int 0x80 }
  Emit($C3);                              { ret }
end;

{ Same, but preserves RBX (callee-saved) and returns it: the syscall ABI
  uses RBX as the secondary return value. }
procedure AddSyscallRbx(raxId: Cardinal);
begin
  BeginStub;
  Emit($53);                              { push rbx }
  Emit($48); Emit($C7); Emit($C0);        { mov rax, imm32 }
  EmitDword(raxId);
  Emit($48); Emit($89); Emit($CB);        { mov rbx, rax }
  Emit($CD); Emit($80);                   { int 0x80 }
  Emit($5B);                              { pop rbx }
  Emit($C3);                              { ret }
end;

{ Syscall 101 returns a shared-memory address in RBX, which the caller then
  stores through R8. RBX must survive the trap, hence push/pop r12 around
  the sequence. }
procedure AddSyscallWithRbxReturn(raxId: Cardinal);
begin
  BeginStub;
  Emit($41); Emit($54);                   { push r12 }
  Emit($48); Emit($C7); Emit($C0);        { mov rax, imm32 }
  EmitDword(raxId);
  Emit($CD); Emit($80);                   { int 0x80 }
  Emit($49); Emit($89); Emit($18);        { mov [r8], rbx }
  Emit($41); Emit($5C);                   { pop r12 }
  Emit($C3);                              { ret }
end;

{ Raw stub slot for a port I/O helper. The bytes are passed in by the
  caller, which is how the fixed-length IN/OUT stubs below are written. }
procedure AddRawStub(const bytes: PByte; len: Cardinal);
var
  i: Cardinal;
begin
  BeginStub;
  for i := 0 to len - 1 do
  begin
    Emit(bytes[i]);
  end;
end;

procedure Vdso_Init;
const
  { mov dx, cx; xor rax, rax; in al, dx; ret }
  StubInByte: array[0..7] of Byte = ($66, $8B, $D1, $48, $31, $C0, $EC, $C3);
  { mov al, dl; mov dx, cx; out dx, al; ret }
  StubOutByte: array[0..6] of Byte = ($88, $D0, $66, $8B, $D1, $EE, $C3);
  { mov dx, cx; xor rax, rax; in ax, dx; ret }
  StubInWord: array[0..8] of Byte = ($66, $8B, $D1, $48, $31, $C0, $66, $ED, $C3);
  { mov dx, dx; mov dx, cx; out dx, ax; ret }
  StubOutWord: array[0..8] of Byte = ($66, $8B, $C2, $66, $8B, $D1, $66, $EF, $C3);
  { mov ax, dx; mov dx, cx; out dx, ax; ret }
  StubOutDword: array[0..6] of Byte = ($89, $D0, $66, $8B, $D1, $EF, $C3);
begin
  Vdso_PhysPage := QWord(Pmm_AllocatePage);
  if Vdso_PhysPage = 0 then Exit;

  { Zero the whole page. Without this a warm reboot leaves stale stub bytes
    and table entries behind, and an app can jump into garbage. }
  MemSet(Pointer(Vdso_PhysPage), 0, VDSO_PAGE_SIZE);

  Vdso_Table := PQWord(Pointer(Vdso_PhysPage));
  Vdso_Code := PByte(Pointer(Vdso_PhysPage + VDSO_CODE_OFFSET));
  Vdso_FuncIndex := 0;

  { Slot order is an ABI - see AGENTS.md §4.1. Append only. }
  AddSyscall(1);                    { 0  Print }
  AddSyscall(0);                    { 1  Exit }
  AddSyscall(5);                    { 2  SendIPC }
  AddSyscall(6);                    { 3  AllocMem }
  AddSyscall(7);                    { 4  GrantPort }
  AddSyscall(8);                    { 5  ReceiveIPC }
  AddSyscall(99);                   { 6  GetSharedMem }
  AddSyscall(4);                    { 7  GetChar }
  AddSyscall(88);                   { 8  RunCmd }
  AddSyscallRbx(90);                { 9  GetThreadUID }
  AddSyscallRbx(91);                { 10 SetUID }
  AddSyscall(89);                   { 11 GetUID }
  AddSyscall(98);                   { 12 Yield }
  AddSyscall(100);                  { 13 WaitIPC }
  AddSyscallRbx(92);                { 14 GetThreadGID }
  AddSyscallRbx(93);                { 15 SetGID }
  AddSyscall(10);                   { 16 GetProcessInfo }
  AddSyscall(3);                    { 17 Clear }
  AddSyscall(97);                   { 18 Sleep }
  AddSyscall(96);                   { 19 GetUptime }
  AddSyscall(11);                   { 20 GetRsdp }
  AddSyscall(12);                   { 21 MapPhys }
  AddSyscall(13);                   { 22 ReportHardware }
  AddSyscall(14);                   { 23 GetPIDByName }
  AddSyscall(399);                  { 24 ResetCursor }
  AddSyscall(50);                   { 25 RequestFramebuffer }
  AddSyscall(51);                   { 26 GetScreenInfo }
  AddSyscallWithRbxReturn(101);     { 27 CreateSharedBuffer }
  AddSyscall(52);                   { 28 RedirectTerminal }

  { 29-33: inline port I/O helpers. These do not trap into the kernel, they
    execute the access in ring 3 against a port the IOPB has granted. Each
    still consumes a table slot. }
  AddRawStub(@StubInByte[0], 8);    { 29 InByte }
  AddRawStub(@StubOutByte[0], 7);   { 30 OutByte }
  AddRawStub(@StubInWord[0], 9);    { 31 InWord }
  AddRawStub(@StubOutWord[0], 9);   { 32 OutWord }
  AddRawStub(@StubOutDword[0], 7);  { 33 OutDword }

  { ATA hardware lock. ATA.EXE and the kernel both touch IDE ports
    0x1F0-0x1F7; without mutual exclusion they race and fault. }
  AddSyscall(60);                   { 34 AcquireAtaHw }
  AddSyscall(61);                   { 35 ReleaseAtaHw }
  AddSyscall(94);                   { 36 SudoRun }

  Terminal_SetColor_Pas($00FF00FF);
  Terminal_Print_Pas(W('[+] vDSO Gateway forged in RAM! Absolute KASLR Ready.'#13#10));
end;

end.
