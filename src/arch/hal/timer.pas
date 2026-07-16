unit hal.timer;

{ Hardware Abstraction Layer: Timer Interface

  This unit defines the architecture-agnostic timer API for NekkoOS.
  Each architecture provides its own implementation:

  - x86_64: Local APIC Timer (per-core) + TSC (timestamp counter) + legacy PIT (boot-time calibration)
  - ARM64: Generic Timer (per-core via CNTV_*) + CNTPCT_EL0 (timestamp)
  - RISC-V: mtime/mtimecmp (per-hart via CLINT) + rdcycle (timestamp)

  The kernel NEVER directly calls PIT/APIC Timer/Generic Timer-specific code.
  All timer operations go through this HAL interface. }

{$MODE FPC}
{$ASMMODE Intel}

interface

type
  { Timer callback type — invoked when timer expires }
  TTimerCallback = procedure(contextPtr: Pointer); cdecl;

  { Timer mode }
  TTimerMode = (
    tmOneShot,     { Fire once, then stop }
    tmPeriodic     { Fire repeatedly at fixed interval }
  );

{ ============================================================================
  Platform Timer Initialization
  ============================================================================ }

{ Initialize the platform's timer subsystem.
  Must be called early in boot, after interrupt controller init.

  x86_64: Calibrates TSC frequency using PIT, then disables PIT
  ARM64: Reads CNTFRQ_EL0 for timer frequency
  RISC-V: Reads platform-provided timebase frequency from device tree }
procedure HAL_InitTimer;

{ Get the timer's base frequency in Hz.
  Used for calculating timeout values.

  x86_64: Returns TSC frequency (e.g., 2.4 GHz)
  ARM64: Returns Generic Timer frequency (typically 19.2 MHz or 24 MHz)
  RISC-V: Returns mtime frequency (typically 10 MHz) }
function HAL_GetTimerFrequency: QWord;

{ ============================================================================
  High-Resolution Timestamp Counter
  ============================================================================ }

{ Read the platform's high-resolution timestamp counter.
  Monotonically increasing, never wraps (or wraps after centuries).
  Used for fine-grained timing, profiling, entropy.

  x86_64: RDTSC instruction (CPU cycles since reset)
  ARM64: CNTPCT_EL0 (Generic Timer Physical Count)
  RISC-V: rdtime pseudo-instruction (reads mtime CSR)

  Returns: Current timestamp value (unit depends on frequency) }
function HAL_ReadTimestamp: QWord;

{ Convert timestamp counter ticks to microseconds.

  Parameters:
    ticks: Timestamp difference (e.g., HAL_ReadTimestamp() - startTime)

  Returns: Time elapsed in microseconds }
function HAL_TicksToMicroseconds(ticks: QWord): QWord;

{ Convert microseconds to timestamp counter ticks.

  Parameters:
    microseconds: Time duration in µs

  Returns: Equivalent tick count }
function HAL_MicrosecondsToTicks(microseconds: QWord): QWord;

{ ============================================================================
  Per-Core Periodic Timer (System Tick)
  ============================================================================ }

{ Start the per-core periodic timer for the current CPU.
  Each core gets its own independent timer that fires at the specified rate.
  Used for preemptive multitasking, time-slicing, profiling.

  Parameters:
    frequencyHz: Desired tick rate (e.g., 250 for 250Hz = 4ms per tick)
    callback: Optional callback invoked on each tick (can be nil)
    context: User data passed to callback

  x86_64: Programs Local APIC timer in periodic mode
  ARM64: Sets CNTV_TVAL_EL0 + auto-reload via interrupt handler
  RISC-V: Sets mtimecmp = mtime + interval, interrupt handler reloads

  IMPORTANT: Callback runs in interrupt context (IRQ disabled).
  Keep it SHORT. Do NOT call blocking functions or acquire locks. }
procedure HAL_StartPeriodicTimer(frequencyHz: Cardinal; callback: TTimerCallback; context: Pointer);

{ Stop the per-core periodic timer on the current CPU.

  x86_64: Masks Local APIC timer interrupt
  ARM64: Clears CNTV_CTL_EL0.ENABLE
  RISC-V: Sets mtimecmp to max QWord }
procedure HAL_StopPeriodicTimer;

{ Get the current tick count since system boot.
  Increments at the rate specified in HAL_StartPeriodicTimer.

  Returns: Number of ticks since boot (wraps after ~500 years at 1kHz) }
function HAL_GetTickCount: QWord;

{ ============================================================================
  One-Shot Timer (Delayed Execution)
  ============================================================================ }

{ Schedule a one-shot callback to fire after a delay.
  Used for timeouts, deferred work, watchdog timers.

  Parameters:
    delayMicroseconds: Delay before firing (µs)
    callback: Function to invoke when timer expires
    context: User data passed to callback

  Returns: Timer handle (use HAL_CancelTimer to abort)

  x86_64: Programs Local APIC timer in TSC-deadline mode
  ARM64: Sets CNTV_CVAL_EL0 to current + delay
  RISC-V: Sets mtimecmp to mtime + delay

  NOTE: If delay < 10µs, may fire immediately. Minimum granularity ~1µs. }
function HAL_ScheduleOneShotTimer(delayMicroseconds: QWord; callback: TTimerCallback; context: Pointer): Cardinal;

{ Cancel a previously scheduled one-shot timer.

  Parameters:
    timerHandle: Handle returned by HAL_ScheduleOneShotTimer

  Returns: true if canceled, false if already fired or invalid handle }
function HAL_CancelTimer(timerHandle: Cardinal): Boolean;

{ ============================================================================
  Delay & Busy-Wait
  ============================================================================ }

{ Busy-wait (spin) for a specified duration.
  Blocks the CPU until the delay elapses. NO context switch.

  Parameters:
    microseconds: Duration to wait (µs)

  WARNING: This is a SPIN LOOP. Interrupts remain enabled, but the CPU
  does NO useful work. Only use for SHORT delays (< 100µs) where sleep
  overhead would dominate, or when interrupts/scheduler are not yet initialized.

  x86_64: Polls RDTSC until target reached
  ARM64: Polls CNTPCT_EL0 until target reached
  RISC-V: Polls rdtime until target reached }
procedure HAL_BusyWaitMicroseconds(microseconds: Cardinal);

{ Busy-wait for a specified number of timestamp ticks.
  Lower-level version of HAL_BusyWaitMicroseconds for sub-microsecond delays.

  x86_64: Polls RDTSC
  ARM64: Polls CNTPCT_EL0
  RISC-V: Polls rdtime }
procedure HAL_BusyWaitTicks(ticks: QWord);

{ ============================================================================
  Scheduler Integration
  ============================================================================ }

{ Notify the timer subsystem that the scheduler is about to context switch.
  Used for accounting CPU time per thread, profiling, etc.

  Parameters:
    newThreadId: Thread ID being switched to (0 = idle)

  The timer implementation tracks per-thread CPU time by reading the
  timestamp counter on each context switch. }
procedure HAL_NotifyContextSwitch(newThreadId: Cardinal);

{ Get total CPU time consumed by a specific thread (microseconds).

  Parameters:
    threadId: Thread ID to query

  Returns: Total µs this thread has been running on any CPU core }
function HAL_GetThreadCpuTime(threadId: Cardinal): QWord;

{ ============================================================================
  Calibration & Diagnostics
  ============================================================================ }

{ Re-calibrate the timer frequency (if platform supports it).
  Used to adjust for thermal drift, power management frequency scaling.

  x86_64: Re-runs TSC calibration using HPET or ACPI PM timer
  ARM64: No-op (Generic Timer frequency is fixed)
  RISC-V: No-op (mtime frequency is fixed) }
procedure HAL_RecalibrateTimer;

{ Dump timer state for debugging: frequency, current tick count, pending timers. }
procedure HAL_DumpTimerState;

implementation

{ All functions are implemented by the architecture-specific backend:
  - x86_64: src/arch/x86_64/apic_timer_impl.pas
  - ARM64: src/arch/arm64/generic_timer_impl.pas
  - RISC-V: src/arch/riscv64/clint_timer_impl.pas

  At link time, the appropriate implementation is selected based on
  the target architecture. No wrapper overhead — direct function calls. }

end.
