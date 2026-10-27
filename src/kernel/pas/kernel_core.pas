{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: kernel_core - the architecture-independent part of kernel boot.

  Every architecture's entry code (x86: kernel_main, ARM64: boot_arm64) does
  its own early bring-up (console, memory map, interrupts, timer) and then
  calls Kernel_InitServices for what is common: IPC, PRNG, the strand engine
  and the scheduler, with Kernel_IdleLoop as the idle task body.

  Platform-specific work that has to happen inside the idle loop (x86: reading
  daemon handshakes from the boot thread's mailbox) is attached with
  Kernel_SetIdleHook so this unit never names a driver.
  =========================================================================
}
unit kernel_core;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Bring up IPC, the PRNG, the strand engine and the scheduler. Needs the page
  allocator, the heap, the timer and (for Hal_Ticks) a running tick source. }
procedure Kernel_InitServices;

{ Called once per idle iteration on thread 0 and on every idle task, before the
  CPU is halted. Pass nil to remove it. }
procedure Kernel_SetIdleHook(hook: Pointer);

{ Body of the boot thread once it has nothing left to start, and of every idle
  task. Plain cdecl procedure that never returns. }
procedure Kernel_IdleLoop; cdecl;

implementation

uses arch_interface, arch_hal, ipc_kernel, prng, strandscheduler, scheduler;

type
  TIdleHook = procedure;

var
  IdleHook: Pointer = nil;

{ A strand is a tiny run-to-completion routine the idle loop cycles through.
  The slot is kept so the engine always has something registered; this one's
  body was commented out in the C# original. }
procedure StrandTask2;
begin
end;

procedure Kernel_SetIdleHook(hook: Pointer);
begin
  IdleHook := hook;
end;

procedure Kernel_InitServices;
begin
  IpcK_Init(8192);
  PRNG_Init(Hal_Ticks);
  Hal_InitUserApi;

  Strand_Init;
  Strand_Create(Pointer(@StrandTask2));

  Sched_SetIdleLoop(Pointer(@Kernel_IdleLoop));
  Sched_Init;
end;

procedure Kernel_IdleLoop; cdecl;
begin
  while True do
  begin
    Arch_CompilerFence;

    Strand_RunCycle;

    if IdleHook <> nil then TIdleHook(IdleHook)();

    { Halt rather than only yielding: under KVM a bare yield does not always
      let other threads run, whereas halting sleeps until the next timer tick
      has driven the scheduler. }
    Arch_Halt;
    Sched_Yield;
  end;
end;

end.
