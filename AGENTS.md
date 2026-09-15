# AGENTS.md — NekkoOS: Hướng dẫn bắt buộc cho AI agents

> **ĐỌC TOÀN BỘ FILE NÀY TRƯỚC KHI LÀM BẤT CỨ ĐIỀU GÌ.**
> Vi phạm các quy tắc dưới đây gây crash, triple fault, hoặc phá vỡ build.
> File này là nguồn sự thật duy nhất — không suy luận từ code chưa đọc.

---

## 1. Tổng quan dự án

**NekkoOS** là hệ điều hành 64-bit giáo dục, đang trong giai đoạn **chuyển toàn bộ logic sang Pascal (FPC)** để chuẩn bị mục tiêu lớn hơn: **chạy được đa kiến trúc (x86_64 → ARM64 → RISC-V)**.

### Toolchain (openSUSE Tumbleweed)
- **bflat v10** (`~/bflat`): compile C# với `--stdlib zero` (không runtime, không GC)
- **fpc 3.2.2**: compile Pascal → COFF `.o` cho Win64 target
- **NASM**: assembly phần boot + hardware primitives (`src/arch/x86_64/Hardware.asm`)
- **lld** (qua bflat): linker duy nhất

```bash
export PATH="$HOME/bflat:/usr/sbin:$PATH"
./build.sh       # build toàn bộ
./run.sh         # chạy QEMU
```

### Cấu trúc thư mục
```
src/
  boot/           # EFI bootloader (C# --stdlib zero)
  kernel/         # Kernel C# + Pascal shims
    pas/          # Tất cả Pascal modules (kernel-side)
  apps/           # Ring-3 user apps (C# --stdlib zero)
  arch/           # Architecture Abstraction Layer
    Arch.cs       # DUY NHẤT được phép có DllImport cho Arch_*/HAL_*
    arch_interface.pas  # Pascal twin của Arch.cs
    hal/          # HAL interface definitions (arch-agnostic Pascal)
      interrupt.pas
      mmu.pas
      platform.pas
      timer.pas
    x86_64/       # x86_64 implementations
      Hardware.asm        # NASM: tất cả Arch_* primitives
      interrupt_impl.pas
      timer_impl.pas
      mmu_impl.pas
      platform_impl.pas
      SyscallImpl.cs      # X86SyscallImpl static class
  drivers/        # Drivers (C# + Pascal)
```

---

## 2. GIỚI HẠN CỨNG — KHÔNG ĐƯỢC VI PHẠM

### 2.1 `--stdlib zero` constraints (C#)

**TUYỆT ĐỐI KHÔNG dùng trong C#:**
- `interface` — cần `RhpInitialDynamicInterfaceDispatch` → runtime không có → crash tại vtable 0xB0000
- `delegate` (trừ function pointer `delegate*`)
- `virtual` / `override` / `abstract` trên class (vtable dispatch cần runtime)
- `typeof()`, `is`, `as` (RTTI)
- `new T[]` (GC heap)
- `string` literals dài (rodata strings OK nếu `fixed`)
- `try/catch/finally`
- LINQ, reflection, dynamic

**Được phép:**
- `static` methods và `static` fields
- `unsafe` + pointers
- `struct` (không có virtual methods)
- `delegate*<...>` (function pointers thô)
- `fixed (char* p = "literal\0")` cho string ngắn
- `[DllImport]` đúng quy tắc (xem §2.2)

**Lý do:** Crash cũ tại `0xB0000` (commit `36634e0`) là do dùng `new X86SyscallImpl()` qua interface `IArcSyscall`. vtable pointer uninitialized → CPU nhảy vào VGA memory → triple fault. Fix: xóa interface, dùng static class.

### 2.2 Quy tắc `[DllImport]`

**Lint gate trong `build.sh` tự động reject vi phạm (build fail):**

```
[DllImport] CHỈ được phép trong:
  - src/arch/         (Arch_*, HAL_* symbols)
  - src/boot/         (boot standalone: Out8, In8)
  - Bất kỳ file nào  nếu EntryPoint kết thúc bằng _Pas
  - Bất kỳ file nào  nếu là AppMainAsm
```

Mọi `[DllImport]` trong `src/kernel/`, `src/drivers/`, `src/apps/` mà KHÔNG có suffix `_Pas` → **build fail ngay lập tức**.

**File duy nhất khai báo `Arch_*` / `HAL_*`:** `src/arch/Arch.cs`

### 2.3 SyscallHandler RSP contract — CỰC KỲ QUAN TRỌNG

`IsrSyscall` (NASM) hoạt động như sau:
```nasm
call SyscallHandler    ; RAX = return value của SyscallHandler
mov rsp, rax           ; RSP = giá trị trả về
iretq                  ; restore RIP, CS, RFLAGS, RSP, SS từ stack mới
```

**SyscallHandler PHẢI trả về RSP hợp lệ.** Nếu trả về `1` (success code) → `mov rsp, 1` → `iretq` từ địa chỉ 1 → triple fault → CPU reset.

**Quy tắc bắt buộc trong `Syscall.cs`:**

```csharp
// ✅ ĐÚNG: gọi Dispatch rồi break → SyscallHandler trả về currentRsp
case 12:
{
    X86SyscallImpl.DispatchMapPhysicalMemory(id, isKing, ctx);
    break;   // trả về currentRsp (hợp lệ)
}

// ❌ SAI: return trả về 1 (success) thay vì RSP → triple fault
case 12:
{
    return X86SyscallImpl.DispatchMapPhysicalMemory(id, isKing, ctx);
}
```

**Ngoại lệ duy nhất — `DispatchKeyboardRead`:**
```csharp
case 4:
    return X86SyscallImpl.DispatchKeyboardRead(id, isKing, ctx, currentRsp);
    // DispatchKeyboardRead trả về RSP thật (có thể context switch sang thread khác)
```

Mọi `Dispatch*` function khác trong `X86SyscallImpl` trả về `ulong` là success/error code,
KHÔNG PHẢI RSP. Gọi chúng bằng `return` trong switch → **auto-reboot/triple fault**.

**Lịch sử bug:** commit `f2d002f` fix cases 12 và 50 vì lý do này. Kiểm tra mọi case mới.

### 2.4 FPC / Pascal constraints

**KHÔNG dùng:**
- Record types với RTTI → FPC sinh `RTTI_$SYSTEM_*$indirect` → lld không resolve
- `interface` trong Pascal (khác C# nhưng cũng tránh để nhất quán)
- `{$TYPEINFO ON}` (default OFF là đúng)

**Bắt buộc dùng:**
- `{$TYPEINFO OFF}` ở đầu mỗi unit
- Flag `-CD` trong FPC compile command (xem compile_pascal.sh)
- Built-in types (`Pointer`, `PByte`, `QWord`, `Cardinal`) trong cdecl exports, không dùng type aliases

**FPC compile flags bắt buộc:**
```bash
fpc -Twin64 -O1 -CX -Ur -g- -Si -CD @.fpc/fpc.cfg -FUbuild/ <file.pas>
```

**Lý do `-CD`:** Disable RTTI generation. Thiếu flag này → link error với lld.

### 2.5 Pascal cdecl export naming

Mọi function Pascal export sang C# **phải** có suffix `_Pas`:
```pascal
procedure MemSet_Pas(dest: Pointer; value: Byte; size: QWord); cdecl; public name 'MemSet_Pas';
```

C# shim:
```csharp
[DllImport("*", EntryPoint = "MemSet_Pas")]
static extern void MemSet_Pas(void* dest, byte value, ulong size);
```

Signature phải khớp HOÀN TOÀN (số tham số, kiểu, thứ tự). Sai một tham số → stack corruption → crash không có thông báo rõ ràng.

---

## 3. Kiến trúc Pascal migration

### 3.1 Trạng thái hiện tại (2026-09-15)

**Pascal modules đã port (PASCAL_MODULES trong compile_pascal.sh):**
```
libc            prng            kerncrypto      pmm
heap            strandscheduler ipc             terminal
arch_interface  rtc             fat16           fpc_runtime
pe_loader       syscall_security memmap_scan    scheduler_dispatch
acpi_parse      passwd_parser
```

**x86_64 HAL implementations (ARCH_X86_64_MODULES):**
```
interrupt_impl  timer_impl      mmu_impl        platform_impl
```

**Còn lại trong C# (chưa port):**
- `Syscall.cs` — dispatcher chính (giữ nguyên, chỉ là thin switch)
- `Kernel.cs` — kernel main (giữ nguyên)
- `Scheduler.cs` — C# wrapper (logic đã sang Pascal)
- `src/apps/*.cs` — user apps Ring-3

### 3.2 Roadmap port C# → Pascal

**Mục tiêu:** 100% logic kernel sang Pascal. C# chỉ là thin glue.

**Thứ tự ưu tiên:**
1. Port từng subsystem một, không port nhiều cùng lúc
2. Mỗi port phải pass smoke test trước khi commit
3. Không port app Ring-3 cho đến khi kernel Pascal ổn định hoàn toàn

**Quy trình port (bắt buộc):**
```
1. Đọc C# file cần port → hiểu logic
2. Tạo/mở .pas unit tương ứng trong src/kernel/pas/
3. Export cdecl function với tên *_Pas
4. Thêm module vào PASCAL_MODULES trong compile_pascal.sh
5. Thêm [DllImport] shim mỏng vào C# (chỉ forward call)
6. ./build.sh → kiểm tra không có link error
7. ./run.sh → smoke test boot thành công
8. Commit ngắn gọn: "Port X sang Pascal"
```

### 3.3 HAL (Hardware Abstraction Layer) — cấu trúc

HAL là cầu nối giữa kernel Pascal (arch-agnostic) và hardware x86_64.

**Interface files (src/arch/hal/):**
- `interrupt.pas` — IRQ routing, EOI, IPI, masking
- `mmu.pas` — page table, TLB, memory mapping
- `platform.pas` — CPU info, NUMA, power management
- `timer.pas` — local timer, frequency calibration

**x86_64 implementations (src/arch/x86_64/):**
- `interrupt_impl.pas` → dùng APIC + IOAPIC
- `timer_impl.pas` → dùng Local APIC timer / PIT
- `mmu_impl.pas` → dùng x86_64 4-level paging
- `platform_impl.pas` → dùng CPUID, ACPI

**ARM64 (tương lai):**
- `interrupt_impl.pas` → GIC (Generic Interrupt Controller)
- `timer_impl.pas` → Generic Timer (CNTV_CVAL_EL0)
- `mmu_impl.pas` → ARMv8 4-level paging
- `platform_impl.pas` → PSCI, device tree

**RISC-V (tương lai):**
- `interrupt_impl.pas` → PLIC + CLINT
- `timer_impl.pas` → mtime/mtimecmp CSR
- `mmu_impl.pas` → Sv39/Sv48 paging
- `platform_impl.pas` → SBI (Supervisor Binary Interface)

**Quy tắc:** Kernel Pascal code KHÔNG BAO GIỜ gọi APIC/IOAPIC trực tiếp. Luôn qua HAL interface.

### 3.4 arch_interface.pas — AAL primitives

`src/arch/arch_interface.pas` khai báo tất cả `Arch_*` primitives được implement trong `Hardware.asm`:

**I/O Ports:** `Arch_WritePort8/16/32`, `Arch_ReadPort8/16/32`, `Arch_IoWait`
**MMIO:** `Arch_WriteMmio32`, `Arch_ReadMmio32`
**CPU Control:** `Arch_EnableInterrupts`, `Arch_DisableInterrupts`, `Arch_Halt`
**Atomics:** `Arch_AtomicExchange`, `Arch_AtomicAdd64`, `Arch_CmpXchg`
**Fences:** `Arch_CompilerFence`, `Arch_StoreFence`, `Arch_LoadFence`, `Arch_FullFence`
**Spinlocks:** `Arch_SpinlockAcquire`, `Arch_SpinlockRelease`
**Paging:** `Arch_LoadPageTable`, `Arch_ReadPageTable`, `Arch_GetFaultAddress`, `Arch_FlushTLB`
**GDT/IDT/TSS:** `Arch_LoadGDT`, `Arch_LoadIDT`, `Arch_LoadTSS`
**ISR entry points:** `Arch_GetIsrDiv0`, `Arch_GetIsrGPF`, `Arch_GetIsrPageFault`, `Arch_GetIsrTimer`, `Arch_GetIsrKeyboard`, `Arch_GetIsrMouse`, `Arch_GetIsrSyscall`, `Arch_GetIsrYield`
**Scheduler:** `Arch_LockScheduler`, `Arch_UnlockScheduler`, `Arch_ForceYield`

Khi port sang ARM64: thêm `src/arch/arm64/arch_interface_arm64.pas` với cùng API, implement bằng ARM64 instructions. Không sửa file x86_64.

---

## 4. Syscall ABI

### 4.1 Bảng syscall (vDSO table slots [0]-[36])

| Slot | Tên | Syscall ID | Ghi chú |
|------|-----|-----------|---------|
| [0] | Print | 1 | |
| [1] | Exit | 0 | |
| [2] | SendIPC | 5 | |
| [3] | AllocMem | 6 | |
| [4] | GrantPort | 7 | Privileged |
| [5] | ReceiveIPC | 8 | |
| [6] | GetSharedMem | 99 | |
| [7] | GetChar | 4 | Keyboard read |
| [8] | RunCmd | 88 | Internal shell |
| [9] | GetThreadUID | 9 | |
| [10] | SetUID | 91 | |
| [11] | GetUID | 92 | |
| [12] | Yield/YieldApp | 100 | |
| [13] | WaitIPC | 93 | |
| [14] | GetThreadGID | 94 | |
| [15] | SetGID | 95 | |
| [16] | GetProcessInfo | 10 | |
| [17] | Clear | 3 | |
| [18] | Sleep | 11 | |
| [19] | GetUptime | 19 | |
| [20] | GetRsdp | 20 | |
| [21] | MapPhys | 12 | ⚠️ phải dùng break không return |
| [22] | ReportHardware | 13 | |
| [23] | GetPIDByName | 14 | |
| [24] | ResetCursor | 399 | |
| [25] | RequestFramebuffer | 50 | ⚠️ phải dùng break không return |
| [26] | GetScreenInfo | 51 | |
| [27] | CreateSharedBuffer | 101 | |
| [28] | RedirectTerminal | 52 | |
| [29] | InByte | 29 | |
| [30] | OutByte | 30 | |
| [31] | InWord | 31 | |
| [32] | OutWord | 32 | |
| [33] | OutDword | 33 | |
| [34] | AcquireAtaHw | 60 | |
| [35] | ReleaseAtaHw | 61 | |
| [36] | SudoRun | 94 | |

### 4.2 KASLR + vDSO

- Kernel base random mỗi lần boot
- Apps không được hard-code địa chỉ kernel
- Apps dùng `table[slot]` để gọi syscall stub (bảng tại địa chỉ cố định trong vDSO page)

### 4.3 Syscall dispatch flow

```
User app → INT/SYSCALL → IsrSyscall (NASM)
  → push registers
  → call SyscallHandler (C#)
    → switch(syscallId)
      → X86SyscallImpl.DispatchXxx() hoặc inline logic
      → break (trả về currentRsp)   ← PHẢI LÀM VẬY
  → return currentRsp (hoặc newRsp nếu context switch)
  → mov rsp, rax
  → iretq
```

---

## 5. Build system

### 5.1 Các bước build

```bash
./build.sh
```

Thứ tự:
1. **Lint gate** — reject DllImport vi phạm
2. **Compile Pascal** — `compile_pascal.sh` → build/ *.o
3. **NASM** — Hardware.asm, boot_io.asm → *.obj
4. **bflat** — C# kernel + apps → PE/COFF
5. **lld link** — ghép tất cả thành NekkoOS.efi

### 5.2 Thêm Pascal module mới

1. Tạo `src/kernel/pas/<module>.pas` (hoặc `src/arch/<module>.pas`)
2. Thêm vào `PASCAL_MODULES` trong `compile_pascal.sh`
3. `./build.sh` để kiểm tra link

### 5.3 COFF relocation stripping

`compile_pascal.sh` chạy Python script sau khi compile để xóa `IMAGE_REL_AMD64_ABSOLUTE` (type 0) relocations — lld từ chối những reloc này.

**Không sửa logic này.** Script xóa reloc entries, không sửa code bytes. Nếu sửa sai → smash function prologue → #GP crash lúc runtime.

### 5.4 Chạy QEMU

```bash
./run.sh
```

Serial log: QEMU redirect serial → `/tmp/serial.log` (dùng để debug).

---

## 6. Bẫy đã biết — PHẢI ĐỌC

### 6.1 ❌ C# interface → crash 0xB0000

**Triệu chứng:** Boot → crash/triple fault tại địa chỉ ~0xB0000 (VGA memory region)
**Nguyên nhân:** `new SomeClass()` qua interface cần `RhpInitialDynamicInterfaceDispatch` → không có trong `--stdlib zero` → vtable pointer uninitialized → CPU nhảy vào VGA memory
**Fix:** Dùng static class với static methods. Không dùng interface, không dùng virtual dispatch.
**Commit:** `36634e0`

### 6.2 ❌ SyscallHandler return wrong value → auto-reboot

**Triệu chứng:** Kernel boot thành công, chạy được vài giây, sau đó tự reboot
**Nguyên nhân:** `case 12: return X86SyscallImpl.DispatchMapPhysicalMemory(...)` — Dispatch trả về `1` (success). IsrSyscall thực hiện `mov rsp, 1` → `iretq` → triple fault → CPU reset
**Fix:** Đổi `return Dispatch...()` thành `Dispatch...(); break;`
**Commit:** `f2d002f`
**Quy tắc:** Chỉ `DispatchKeyboardRead` được phép `return` (trả về RSP thật cho context switch). Mọi Dispatch khác: gọi xong rồi `break`.

### 6.3 ❌ FPC RTTI → link error

**Triệu chứng:** `lld: error: undefined symbol: RTTI_$SYSTEM_TGUID$indirect` hoặc tương tự
**Nguyên nhân:** FPC tự động sinh RTTI cho record types và type aliases
**Fix:**
- Thêm `{$TYPEINFO OFF}` ở đầu unit
- Dùng `-CD` flag trong compile command
- Dùng built-in types trong export signatures (`Pointer` không phải custom alias)

### 6.4 ❌ Pascal export signature mismatch → stack corruption

**Triệu chứng:** Crash không rõ ràng, sai giá trị biến, thỉnh thoảng hoạt động đúng
**Nguyên nhân:** C# `[DllImport]` signature không khớp với Pascal `cdecl` export (sai số tham số hoặc kiểu)
**Ví dụ lỗi:** `Shell.ClearBuffer` truyền 2 args cho `MemSet_Pas` nhưng Pascal khai báo 3 tham số → stack frame sai
**Fix:** Luôn đọc Pascal declaration và C# DllImport cạnh nhau. Kiểm tra từng tham số.
**Commit:** `9ac1100`

### 6.5 ❌ QEMU sendkey bị drop keystroke

**Triệu chứng:** Tự động hóa gõ phím qua QEMU monitor → một số phím bị bỏ qua
**Nguyên nhân:** 8042 keyboard controller có buffer giới hạn; keystroke dồn khi CPU đang busy dispatch → drop
**Fix:** Poll serial log, chờ prompt xuất hiện trước mỗi keystroke. Không gõ dồn nhiều phím cùng lúc.

### 6.6 ❌ Integer underflow trong ACPI parsing

**Triệu chứng:** `entriesCount` rất lớn (underflow từ uint) → loop đọc ra ngoài bộ nhớ → crash
**Nguyên nhân:** `sdtRealLength - sizeof(ACPISDTHeader)` wrap around khi `sdtRealLength < 36`
**Fix:**
```csharp
uint headerSz = (uint)sizeof(ACPISDTHeader);
int entriesCount = (sdtRealLength > headerSz)
    ? (int)((sdtRealLength - headerSz) / (useXsdt ? 8u : 4u))
    : 0;
```

### 6.7 ❌ MapACPI null dereference

**Triệu chứng:** Kernel crash khi parse ACPI tables
**Nguyên nhân:** `MapACPI()` có thể trả về 0 nếu mapping thất bại, code dereference ngay không kiểm tra
**Fix:** Luôn kiểm tra return value của MapACPI trước khi cast:
```csharp
ulong virt = MapACPI(phys, size);
if (virt == 0) { /* log error + exit/continue */ }
```

### 6.8 ⚠️ build/asm/ppas.sh là artifact sinh tự động

**Đừng commit file này.** Sinh ra mỗi lần FPC compile, phải revert trước commit.

### 6.9 ⚠️ QEMU process zombie

Sau khi dừng QEMU, kiểm tra:
```bash
pgrep -f qemu-system
rm -f hdd.img.lock
```
Trước khi chạy VM mới nếu không sẽ bị "disk locked" error.

---

## 7. Mục tiêu đa kiến trúc

### 7.1 Kế hoạch

```
Giai đoạn 1 (hiện tại): x86_64
  - Port 100% logic kernel sang Pascal ✅ (đang làm dở)
  - HAL interface đã định nghĩa đầy đủ ✅
  - Smoke tests pass ✅

Giai đoạn 2: ARM64
  - Tạo src/arch/arm64/ với arch_interface_arm64.pas
  - Implement HAL: GIC, Generic Timer, ARMv8 MMU
  - Implement SyscallImpl cho ARM64
  - Target board: QEMU virt machine (AArch64)
  - Bước đầu: không cần boot thật, QEMU đủ

Giai đoạn 3: RISC-V 64
  - Tạo src/arch/riscv64/ với arch_interface_riscv64.pas
  - Implement HAL: PLIC, CLINT, Sv39 MMU
  - Target: QEMU virt (RISC-V)
```

### 7.2 Nguyên tắc portability

**Kernel Pascal code:**
- KHÔNG import `arch_interface` trực tiếp — chỉ dùng `hal.*` units
- KHÔNG hard-code địa chỉ APIC, IOAPIC, hoặc bất kỳ MMIO x86-specific
- KHÔNG dùng x86-specific instructions (cli/sti) — dùng `Arch_DisableInterrupts`/`Arch_EnableInterrupts`

**C# kernel glue:**
- Chỉ dùng `Arch_*` từ `Arch.cs` — không trực tiếp gọi x86 port I/O
- Syscall.cs switch chỉ dispatch — không chứa hardware logic

**Khi thêm kiến trúc mới:**
1. Thêm `src/arch/<arch>/Hardware_<arch>.asm` (hoặc .S)
2. Thêm `src/arch/<arch>/arch_interface_<arch>.pas`
3. Implement tất cả HAL interfaces trong `src/arch/<arch>/`
4. Thêm build target trong `build.sh` (conditional trên `$ARCH` env var)
5. **Không sửa code kernel chung** — nếu phải sửa kernel, HAL thiếu abstraction

---

## 8. Quy trình làm việc cho AI agents

### 8.1 Trước khi bắt đầu

1. **Đọc file liên quan** — không suy luận từ tên file
2. **Chạy build trước** — xem trạng thái hiện tại: `./build.sh 2>&1 | tail -30`
3. **Đọc AGENTS.md** (file này) — đặc biệt §2 và §6

### 8.2 Khi port C# → Pascal

```
BẮT BUỘC theo thứ tự:
1. Đọc C# function cần port
2. Kiểm tra signature: số tham số, kiểu, thứ tự
3. Viết Pascal function với cdecl + public name '*_Pas'
4. Thêm {$TYPEINFO OFF} nếu dùng record
5. Kiểm tra compile: fpc -Twin64 -O1 -CX -Ur -g- -Si -CD ...
6. Kiểm tra link: ./build.sh
7. Kiểm tra runtime: ./run.sh
8. Commit

KHÔNG được:
- Port nhiều modules cùng lúc mà không test từng cái
- Thêm DllImport ngoài src/arch/ mà không có _Pas suffix
- Dùng C# interface để wrap Pascal code
```

### 8.3 Khi thêm syscall mới

```
BẮT BUỘC:
1. Chọn syscall ID chưa dùng (kiểm tra Syscall.cs)
2. Thêm vDSO slot vào API.cs nếu cần app access
3. Viết case trong Syscall.cs switch:
   - Nếu Dispatch function trả về success code: DÙNG break
   - Nếu Dispatch function trả về RSP (context switch): DÙNG return
4. Document trong AGENTS.md §4.1
```

### 8.4 Debug crash

```
Thứ tự debug:
1. Đọc serial log: cat /tmp/serial.log
2. Tìm dòng cuối cùng trước crash
3. Nếu reboot sau syscall → kiểm tra Syscall.cs case tương ứng có dùng return không
4. Nếu crash tại ~0xB0000 → kiểm tra có dùng C# interface không
5. Nếu link error RTTI → kiểm tra Pascal unit có {$TYPEINFO OFF} không
6. Nếu stack corruption → so sánh Pascal export signature với C# DllImport
```

### 8.5 Giới hạn agent

- Mỗi agent chỉ làm một nhiệm vụ cụ thể
- Agent có thể bị rate-limit (429) — nếu bị, đọc kết quả partial và tiếp tục thủ công
- Không chạy hai agent song song cùng sửa một file
- Luôn nghiệm thu kết quả agent trước khi dùng: đọc file đã sửa, kiểm tra build

---

## 9. Commit conventions

```
Port X sang Pascal              # port đơn giản
Fix Y: mô tả ngắn nguyên nhân  # fix bug
Add Z: mô tả tính năng         # tính năng mới
Refactor W: mô tả lý do        # refactor
```

Commit nhỏ, thường xuyên. Không gộp port Pascal + fix bug vào 1 commit.

---

## 10. Smoke tests

```bash
python3 test/automation/smoke_test.py
# 9/9 phải pass: boot → login → ls → LS → cd.. → root listing → write → cat → shutdown
```

Phải pass trước mỗi commit ảnh hưởng đến kernel hoặc syscall.

---

## 11. Việc tiếp theo (thứ tự ưu tiên)

1. ~~Port ACPI parsing sang Pascal~~ ✅
2. ~~Port PELoader sang Pascal~~ ✅
3. ~~Port helper chuỗi vào libc.pas~~ ✅
4. ~~Fix auto-reboot (syscall 12/50 return RSP bug)~~ ✅
5. **Port phần còn lại của Scheduler sang Pascal** (scheduler_dispatch.pas đã có, cần wire đầy đủ)
6. **Refactor Syscall.cs**: đảm bảo tất cả cases đều dùng break đúng cách, không case nào return success code
7. **ARM64 HAL stub**: tạo skeleton src/arch/arm64/ với no-op implementations
8. **Build system dual-arch**: build.sh nhận `ARCH=arm64` env var, compile đúng HAL
9. **QEMU ARM64 test**: boot NekkoOS trên `qemu-system-aarch64 -M virt`
