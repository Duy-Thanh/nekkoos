{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: kstate - Cross-module kernel globals.

  PURPOSE: Some state is genuinely shared between modules that must not
  depend on each other. The prime example is the shared-memory window: the
  syscall layer allocates it, but VMM.DestroyUserSpace must know its address
           so it does not free the very pages an app is still using.

  A direct Pascal unit cycle (syscall uses vmm, vmm uses syscall) will not
  compile, and the alternative - passing the value through every call site -
  spreads a kernel-wide invariant across dozens of functions. This unit is
  the single owner of such state, depended on by everyone, depending on
  nobody. It must therefore stay free of dependencies: no uses clause, no
  hardware access, no allocation.

  Keep this list short. If a value has exactly one owner, it belongs in that
  owner's unit instead.
  =========================================================================
}

unit kstate;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

var
  { Physical base of the shared-memory window handed out by syscall 101.
    VMM skips these pages when tearing down a process's address space, so
    freeing them would corrupt a live mapping. 0 = not allocated. }
  kstate_SharedRAM_Phys: QWord = 0;

  { Physical address of the MPU trap page. Also protected from teardown: the
    kernel maps it deliberately and expects it to outlive any process. }
  kstate_MpuTrapPage_Phys: QWord = 0;

  { Number of pages in the shared window. 0 = not allocated. }
  kstate_SharedRAM_Pages: QWord = 0;

implementation

end.
