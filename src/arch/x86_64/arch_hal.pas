{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: arch_hal - the platform contract the generic kernel codes against.

  Generic kernel units (scheduler, pe_loader, power, kernel_main, ...) must
  not name apic, gdt, vmm or any other architecture unit. They `uses arch_hal`
  and call Hal_* only. Each architecture supplies its own unit called
  `arch_hal` with the SAME interface section (src/arch/<arch>/arch_hal.pas);
  the build picks the implementation by directory.

  The interface below is the contract. Keep it free of x86 concepts: an
  "address space" is an opaque handle (a PML4 physical address here, a TTBR0
  value on ARM64, a satp value on RISC-V); a "core id" is whatever number the
  interrupt controller uses to name a CPU.

  This x86_64 implementation only forwards to the existing arch units.
  =========================================================================
}
unit arch_hal;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

const
  { Mapping permission sets for Hal_MapPageIn. The numeric values are the
    architecture's own page-table bits; generic code only uses the names. }
  HAL_MAP_KERNEL_RW = QWord($03);   { present + writable, supervisor only }
  HAL_MAP_USER_RW   = QWord($07);   { present + writable + user }

{ ── Cores ─────────────────────────────────────────────────────────────────── }

{ True once more than the boot CPU's interrupt controller is live, i.e. once
  Hal_CurrentCoreId can return something other than 0. }
function Hal_MultiCoreActive: Boolean;

{ Id of the CPU executing this call (0 on the boot CPU, and always 0 before
  Hal_MultiCoreActive). Not range-checked: callers bound it themselves. }
function Hal_CurrentCoreId: Cardinal;

{ ── Address spaces ────────────────────────────────────────────────────────── }

{ Handle of the kernel's own address space; every user space is a copy of it. }
function Hal_KernelAddressSpace: QWord;

{ Can this be a valid virtual address on this architecture? }
function Hal_IsCanonical(addr: QWord): Boolean;

{ Map one 4 KiB page into the address space `space` (not necessarily the
  loaded one). `perms` is HAL_MAP_*. }
procedure Hal_MapPageIn(phys, virt, perms: QWord; space: QWord);

{ Free every page and table reachable from a user address space, then the
  root itself. The kernel space must never be passed. }
procedure Hal_DestroyAddressSpace(space: QWord);

{ ── Kernel stacks ─────────────────────────────────────────────────────────── }

{ Top of the stack the boot CPU enters the kernel on from user mode. }
function Hal_BootKernelStackTop: QWord;

{ Make `core` enter the kernel on `stackTop` the next time it leaves user mode
  (x86: the TSS ring-0 stack pointer). No-op for an unknown core. }
procedure Hal_SetKernelStack(core: Cardinal; stackTop: QWord);

implementation

uses apic, gdt, vmm;

function Hal_MultiCoreActive: Boolean;
begin
  Hal_MultiCoreActive := Apic_IsAwake;
end;

function Hal_CurrentCoreId: Cardinal;
begin
  if Apic_IsAwake then Hal_CurrentCoreId := Apic_Read($020) shr 24
  else Hal_CurrentCoreId := 0;
end;

function Hal_KernelAddressSpace: QWord;
begin
  Hal_KernelAddressSpace := QWord(Vmm_GetPml4);
end;

function Hal_IsCanonical(addr: QWord): Boolean;
begin
  Hal_IsCanonical := Vmm_IsCanonical(addr);
end;

procedure Hal_MapPageIn(phys, virt, perms: QWord; space: QWord);
begin
  Vmm_MapPageIn(phys, virt, perms, Pointer(space));
end;

procedure Hal_DestroyAddressSpace(space: QWord);
begin
  Vmm_DestroyUserSpace(space);
end;

function Hal_BootKernelStackTop: QWord;
begin
  Hal_BootKernelStackTop := Gdt_GetTssRsp0;
end;

procedure Hal_SetKernelStack(core: Cardinal; stackTop: QWord);
var
  tss: Pointer;
begin
  if core = 0 then tss := Gdt_GetTss
  else tss := Gdt_GetCoreTss(core);
  { Rsp0 sits at byte offset 4 of the TSS (a 4-byte reserved field first). }
  if tss <> nil then PQWord(PByte(tss) + 4)^ := stackTop;
end;

end.
