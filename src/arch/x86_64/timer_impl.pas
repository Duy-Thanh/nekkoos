unit timer_impl;

{ x86_64 Implementation of HAL Timer Interface

  Implements the generic timer HAL for x86_64 using:
  - TSC (Time Stamp Counter) for high-resolution timing
  - Local APIC Timer for system ticks/scheduler

  This provides the implementation for the HAL timer interface
  documented in src/arch/hal/timer.pas }

{$MODE FPC}
{$ASMMODE Intel}
{$M-}

interface

procedure HAL_InitTimer; cdecl; public name 'HAL_InitTimer';
function  HAL_GetTimerFrequency: QWord; cdecl; public name 'HAL_GetTimerFrequency';
function  HAL_ReadTimestamp: QWord; cdecl; public name 'HAL_ReadTimestamp';
function  HAL_TicksToMicroseconds(ticks: QWord): QWord; cdecl; public name 'HAL_TicksToMicroseconds';
function  HAL_MicrosecondsToTicks(microseconds: QWord): QWord; cdecl; public name 'HAL_MicrosecondsToTicks';
procedure HAL_StartPeriodicTimer(frequencyHz: Cardinal; callback: Pointer; context: Pointer); cdecl; public name 'HAL_StartPeriodicTimer';
procedure HAL_StopPeriodicTimer; cdecl; public name 'HAL_StopPeriodicTimer';
function  HAL_GetTickCount: QWord; cdecl; public name 'HAL_GetTickCount';
procedure HAL_BusyWaitMicroseconds(microseconds: Cardinal); cdecl; public name 'HAL_BusyWaitMicroseconds';
procedure HAL_BusyWaitTicks(ticks: QWord); cdecl; public name 'HAL_BusyWaitTicks';
procedure HAL_NotifyContextSwitch(newThreadId: Cardinal); cdecl; public name 'HAL_NotifyContextSwitch';
function  HAL_GetThreadCpuTime(threadId: Cardinal): QWord; cdecl; public name 'HAL_GetThreadCpuTime';
procedure HAL_RecalibrateTimer; cdecl; public name 'HAL_RecalibrateTimer';
procedure HAL_DumpTimerState; cdecl; public name 'HAL_DumpTimerState';

{ Helper to set frequencies calibrated in C# }
procedure HAL_SetTimerFrequencies(tsc: QWord; apicTicksPerMs: Cardinal); cdecl; public name 'HAL_SetTimerFrequencies';
procedure HAL_IncrementTicks; cdecl; public name 'HAL_IncrementTicks';

implementation

{ AAL Layer 1 primitives }
function  Arch_ReadTimestamp: QWord; cdecl; external name 'Arch_ReadTimestamp';
procedure Arch_CompilerFence; cdecl; external name 'Arch_CompilerFence';

const
  APIC_REG_TIMER_DIV = $3E0;
  APIC_REG_TIMER_LVT = $320;
  APIC_REG_TIMER_INIT = $380;

procedure Arch_WriteMmio32(addr: QWord; value: Cardinal); cdecl; external name 'Arch_WriteMmio32';
procedure WriteApic(offset: Cardinal; value: Cardinal); inline;
begin
  Arch_WriteMmio32($FEE00000 + offset, value);
end;

var
  TscFrequency: QWord = 2000000000; { Default 2GHz placeholder }
  ApicTimerTicksPerMs: Cardinal = 1000000;
  GlobalTicks: QWord = 0;

  { Thread CPU accounting }
  CurrentThread: Cardinal = 0;
  LastSwitchTime: QWord = 0;
  ThreadCpuTime: array[0..256] of QWord;

procedure HAL_InitTimer; cdecl;
begin
  LastSwitchTime := Arch_ReadTimestamp();
end;

function HAL_GetTimerFrequency: QWord; cdecl;
begin
  HAL_GetTimerFrequency := TscFrequency;
end;

function HAL_ReadTimestamp: QWord; cdecl;
begin
  HAL_ReadTimestamp := Arch_ReadTimestamp();
end;

function HAL_TicksToMicroseconds(ticks: QWord): QWord; cdecl;
begin
  if TscFrequency = 0 then
    HAL_TicksToMicroseconds := 0
  else
    HAL_TicksToMicroseconds := (ticks * 1000000) div TscFrequency;
end;

function HAL_MicrosecondsToTicks(microseconds: QWord): QWord; cdecl;
begin
  HAL_MicrosecondsToTicks := (microseconds * TscFrequency) div 1000000;
end;

procedure HAL_StartPeriodicTimer(frequencyHz: Cardinal; callback: Pointer; context: Pointer); cdecl;
var
  ticksPerQuantum: Cardinal;
begin
  if frequencyHz = 0 then frequencyHz := 250;
  ticksPerQuantum := (ApicTimerTicksPerMs * 1000) div frequencyHz;

  { Program Local APIC Timer }
  WriteApic(APIC_REG_TIMER_DIV, $03); { Divide by 16 }
  WriteApic(APIC_REG_TIMER_LVT, 32 or $20000); { Vector 32, Periodic }
  WriteApic(APIC_REG_TIMER_INIT, ticksPerQuantum);
end;

procedure HAL_StopPeriodicTimer; cdecl;
begin
  WriteApic(APIC_REG_TIMER_LVT, $10000); { Masked }
end;

function HAL_GetTickCount: QWord; cdecl;
begin
  HAL_GetTickCount := GlobalTicks;
end;

procedure HAL_BusyWaitMicroseconds(microseconds: Cardinal); cdecl;
var
  start, target: QWord;
begin
  start := Arch_ReadTimestamp();
  target := start + HAL_MicrosecondsToTicks(microseconds);
  while Arch_ReadTimestamp() < target do
    Arch_CompilerFence();
end;

procedure HAL_BusyWaitTicks(ticks: QWord); cdecl;
var
  start, target: QWord;
begin
  start := Arch_ReadTimestamp();
  target := start + ticks;
  while Arch_ReadTimestamp() < target do
    Arch_CompilerFence();
end;

procedure HAL_NotifyContextSwitch(newThreadId: Cardinal); cdecl;
var
  now, elapsed: QWord;
begin
  now := Arch_ReadTimestamp();
  elapsed := now - LastSwitchTime;
  LastSwitchTime := now;

  if CurrentThread < 256 then
    ThreadCpuTime[CurrentThread] := ThreadCpuTime[CurrentThread] + elapsed;

  CurrentThread := newThreadId;
end;

function HAL_GetThreadCpuTime(threadId: Cardinal): QWord; cdecl;
begin
  if threadId < 256 then
    HAL_GetThreadCpuTime := HAL_TicksToMicroseconds(ThreadCpuTime[threadId])
  else
    HAL_GetThreadCpuTime := 0;
end;

procedure HAL_RecalibrateTimer; cdecl;
begin
  { No-op on x86_64 after boot init }
end;

procedure HAL_DumpTimerState; cdecl;
begin
  { Debug dump if needed }
end;

procedure HAL_SetTimerFrequencies(tsc: QWord; apicTicksPerMs: Cardinal); cdecl;
begin
  TscFrequency := tsc;
  ApicTimerTicksPerMs := apicTicksPerMs;
end;

procedure HAL_IncrementTicks; cdecl;
begin
  GlobalTicks := GlobalTicks + 1;
end;

end.
