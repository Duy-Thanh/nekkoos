# AGENTS.md — NekkoOS: Hướng dẫn bắt buộc cho AI agents

> **ĐỌC TOÀN BỘ FILE NÀY TRƯỚC KHI LÀM BẤT CỨ ĐIỀU GÌ.**
> Vi phạm các quy tắc dưới đây gây crash, triple fault, hoặc phá vỡ build.
> File này là nguồn sự thật duy nhất — không suy luận từ code chưa đọc.

---

## 1. Tổng quan dự án

**NekkoOS** là hệ điều hành 64-bit giáo dục. **Toàn bộ mã nguồn là Pascal (FPC) và NASM — không còn
dòng C# nào** (hoàn tất 2026-10-26). Mục tiêu tiếp theo: **chạy đa kiến trúc (x86_64 → ARM64 → RISC-V)**.

### Toolchain (openSUSE Tumbleweed)
- **fpc 3.2.2**: compile Pascal → COFF `.o` cho target Win64 (kernel, app, bootloader)
- **NASM**: boot + hardware primitives (`src/arch/x86_64/Hardware.asm`, `src/boot/boot_io.asm`, `smp_x86.asm`)
- **lld** (`lld-link`, gói `lld` của hệ thống): linker duy nhất cho **mọi** image
- ~~bflat / C#~~: đã loại bỏ. `build.sh` **từ chối build** nếu còn bất kỳ `.cs` nào dưới `src/`.

```bash
./build.sh       # build toàn bộ
./run.sh         # chạy QEMU
make test        # smoke + extra + hwcheck
./verify_pascal_link.sh   # không C#, không RTTI, entry point còn đủ
```

### Ba loại image, một linker
| Image | Nguồn | Link |
|---|---|---|
| `efi/boot/bootx64.efi` | `src/boot/boot.pas` + `boot_io.asm` | `lld-link -subsystem:efi_application -entry:NekkoBoot` |
| `Kernel.exe` (PE DLL, export `KernelMain`) | toàn bộ unit kernel + arch + drivers + `Hardware.asm` | `lld-link /dll /noentry /export:KernelMain /dynamicbase ...` |
| `*.exe` Ring-3 (export `AppMain`) | `src/apps/*_app.pas` + `app_api.pas` | `lld-link -entry:AppMain -export:AppMain` |

### Cấu trúc thư mục
```
src/
  boot/            # boot.pas (UEFI bootloader), boot_io.asm
  kernel/pas/      # kernel generic: scheduler, ipc_kernel, heap, pmm, fat16_kernel, ata_kernel,
                   #   syscall_dispatch, kernel_main, console, sudo_dispatch, internal_shell, pe_loader ...
  arch/
    arch_interface.pas   # Pascal khai báo Arch_* primitives (implement trong Hardware.asm)
    hal/                 # interface HAL (arch-agnostic): interrupt, mmu, platform, timer
    x86_64/              # gdt idt vmm apic ioapic pic pit smp vdso interrupt_handlers syscall_impl
                         #   hardware_checks + *_impl.pas (HAL x86_64) + Hardware.asm
  drivers/         # power.pas, pci.pas, input_drv.pas
  apps/            # app_api.pas + *_app.pas (Ring-3): shell, login, ata, fat16, mouse, acpi, top, dsrv, explorer, stress
scripts/           # gen_auth.py, strip_coff_relocs.py
test/automation/   # smoke_test.py, extra_test.py, hwcheck_test.py
```

---

## 2. GIỚI HẠN CỨNG — KHÔNG ĐƯỢC VI PHẠM

### 2.1 Không có runtime, không có RTL

Kernel chạy freestanding: **không heap của FPC, không exception, không RTTI**. Chỉ dùng:
- kiểu thô (`Pointer`, `PByte`, `QWord`, `Cardinal`, mảng tĩnh), `packed record` **khai báo trong `implementation`**
- `AnsiString` chỉ ở dạng **hằng literal truyền vào `W(...)`** (xem `kstring.pas`); **không** dùng
  `AnsiString` làm biến/kết quả/ghép chuỗi (kéo theo `fpc_ansistr_*` mà lld không có — bootloader đã bị vướng chuyện này)
- Chuỗi UTF-16 cho terminal/user: `PWord` + `W('text')` (pool xoay vòng 8 slot, **không giữ** con trỏ quá 8 lần gọi `W`)

### 2.2 Giới hạn của hạ tầng build

- `{$TYPEINFO OFF}` + `{$M-}` ở đầu mỗi unit; cờ `-CD` khi compile (chi tiết §2.4, §6.3)
- Unit không có `uses` vòng. Lõi dùng chung nhau qua `kstate.pas` (state dùng chung, **không có `uses`**)
- Một unit chỉ để xuất symbol (ISR handler, `SyscallHandler`, `KernelMain`) có `interface` rỗng và
  `public name '...'` trong implementation — vẫn phải được đăng ký trong cả hai script (§5.1b)

### 2.3 SyscallHandler RSP contract — CỰC KỲ QUAN TRỌNG

`IsrSyscall` (NASM) hoạt động như sau:
```nasm
call SyscallHandler    ; RAX = giá trị trả về
mov rsp, rax           ; RSP = giá trị trả về
iretq                  ; restore RIP, CS, RFLAGS, RSP, SS từ stack mới
```

**`SyscallHandler` PHẢI trả về RSP hợp lệ.** Trả `1` (mã thành công) → `mov rsp, 1` → triple fault → CPU reset.

Trong `src/kernel/pas/syscall_dispatch.pas`:
- Mọi `Disp_*` (trong `syscall_impl.pas`) trả về **mã thành công/lỗi**, KHÔNG phải RSP → gọi xong rồi để rơi xuống
  `SyscallHandler := currentRsp` cuối hàm.
- Chỉ hai nguồn được gán vào `switchedRsp`/`switched := True`: **`Sched_SwitchTask`** và **`Disp_KeyboardRead`**
  (syscall 4, 97, 98, 100, và nhánh jailed-phantom).
- Case mới: kiểm tra từng nhánh — đây đã gây auto-reboot 2 lần (`f2d002f`).

### 2.4 FPC / Pascal constraints

**KHÔNG dùng:**
- `record`/`enum` khai báo trong `interface` → FPC sinh RTTI `RTTI_$SYSTEM_*$indirect` → lld không resolve (§6.3)
- Tên hàm trùng tên unit (vd. hàm `Sudo_Dispatch` trong unit `sudo_dispatch` → FPC hiểu là `unit.xxx`)
- Tên biến module trùng tên tham số (Pascal không phân biệt hoa thường: `Width` vs `width`)
- Tên `result` làm tham số (từ khoá trong objfpc)
- `{$TYPEINFO ON}`

**Bắt buộc:**
- `{$TYPEINFO OFF}` ở đầu mỗi unit; kiểu built-in trong chữ ký `cdecl` export

**Lệnh compile (xem `compile_pascal.sh`):**
```bash
fpc -Twin64 -O1 -CX -Ur -g- -Si -CD @.fpc/fpc.cfg -FUbuild/ <file.pas>
```
`.fpc/fpc.cfg` chứa các `-Fu` tới `src/**` nên FPC tự dựng lại unit phụ thuộc theo bất kỳ thứ tự nào.
`-CD` tắt RTTI; thiếu → lỗi link.

**Win64:** `cdecl` của FPC trên target này chính là **Microsoft x64 ABI** — cùng ABI với UEFI và với `Hardware.asm`.
Con trỏ hàm do firmware/asm cấp đọc ra rồi ép sang kiểu thủ tục `cdecl`.

### 2.5 Quy ước export

- Hàm gọi từ asm: tên cố định theo `extern` trong `Hardware.asm` (`SyscallHandler`, `TimerHandler`,
  `YieldHandler`, `KeyboardHandler`, `MouseHandler`, `DivideByZeroHandler`, `GPFHandler`, `PageFaultHandler`).
- Hàm gọi giữa các image hoặc từ tên-cố-định khác: `cdecl; public name '<Tên>_Pas'`.
- Chữ ký phải khớp **hoàn toàn** giữa nơi khai báo `external name` và nơi định nghĩa — sai một tham số → stack
  corruption không báo lỗi (§6.4).

---

## 3. Kiến trúc

### 3.0 Bảng đối chiếu C# (đã xoá) → Pascal

| C# cũ | Pascal hiện tại |
|---|---|
| Kernel.cs | `kernel/pas/kernel_main.pas` (`KernelMain`, `KernelIdleLoop`, vòng chờ daemon) |
| Syscall.cs / SyscallImpl.cs | `kernel/pas/syscall_dispatch.pas` / `arch/x86_64/syscall_impl.pas` |
| InterruptHandlers.cs | `arch/x86_64/interrupt_handlers.pas` |
| Thread.cs (Scheduler) | `kernel/pas/scheduler.pas` (state sở hữu bởi Pascal) |
| SMP.cs | `arch/x86_64/smp.pas` |
| HardwareChecks.cs | `arch/x86_64/hardware_checks.pas` |
| GDT / IDT / PIC / PIT / APIC / IOAPIC / VMM / vDSO .cs | cùng tên `.pas` trong `arch/x86_64/` |
| Terminal.cs | `terminal.pas` (vẽ) + `console.pas` (khoá màn hình, màu theo thread, shadow buffer) |
| ATA.cs / FAT16.cs | `ata_kernel.pas` / `fat16_kernel.pas` |
| Heap.cs / IPC.cs / PMM.cs | `heap.pas` / `ipc_kernel.pas` (+`ipc.pas`) / `pmm.pas` |
| Power.cs / PCI.cs | `drivers/power.pas` / `drivers/pci.pas` |
| KeyboardDriver.cs / MouseDriver.cs | `drivers/input_drv.pas` |
| Sudo.cs / InternalShell.cs / PELoader.cs | `sudo_dispatch.pas` / `internal_shell.pas` / `pe_loader.pas` |
| Boot.cs | `boot/boot.pas` |
| acpi.cs / API.cs | `apps/acpi_app.pas` / `apps/app_api.pas` |

### 3.1 Trình tự khởi động (`kernel_main.pas`)

1. console + serial → 2. PMM (từ UEFI memory map) → VMM → heap → shadow buffer → FAT16 raw →
3. GDT/TSS, IDT, remap PIC, tắt bus-master DMA PCI → 4. PIT, IPC, PRNG, vDSO, strands, **scheduler**, bật ngắt →
5. `HwChecks_CheckHardwareError` (cổng xác thực nền tảng qua fw_cfg) →
6. spawn ACPI.EXE → chờ APIC/IOAPIC → IOAPIC + SMP → spawn ATA, FAT16, MOUSE → chờ 3 handshake IPC
(có deadline `Pit_MsToTicks`, mouse được kill + respawn 1 lần) → spawn SYSLOGON.EXE → idle loop.

### 3.2 HAL (Hardware Abstraction Layer)

HAL là cầu nối giữa kernel Pascal (arch-agnostic) và hardware x86_64.

**Interface (src/arch/hal/):** `interrupt.pas` (IRQ routing, EOI, IPI), `mmu.pas` (page table, TLB),
`platform.pas` (CPU info, power), `timer.pas` (local timer).

**x86_64 (src/arch/x86_64/):** `interrupt_impl.pas` (APIC+IOAPIC), `timer_impl.pas`, `mmu_impl.pas`,
`platform_impl.pas` (CPUID/ACPI).

**ARM64 / RISC-V (tương lai):** GIC + Generic Timer + ARMv8 MMU + PSCI / PLIC+CLINT + mtime + Sv39/48 + SBI.

**Quy tắc:** kernel Pascal arch-agnostic KHÔNG gọi APIC/IOAPIC trực tiếp. *Thực tế hiện tại:* `scheduler.pas`,
`syscall_impl.pas`, `interrupt_handlers.pas`, `smp.pas`, `kernel_main.pas` còn gọi thẳng `apic`/`gdt`/`vmm`
(x86_64). Muốn thêm kiến trúc thì các điểm đó là thứ phải trừu tượng hoá trước (§7, §11).

### 3.3 arch_interface.pas — AAL primitives

`src/arch/arch_interface.pas` khai báo mọi `Arch_*` implement trong `Hardware.asm`:

**I/O:** `Arch_WritePort8/16/32`, `Arch_ReadPort8/16/32`, `Arch_IoWait` · **MMIO:** `Arch_WriteMmio32/ReadMmio32` ·
**CPU:** `Arch_EnableInterrupts/DisableInterrupts/Halt`, `Arch_GetFlags` · **Atomics:** `Arch_AtomicExchange/Add64`, `Arch_CmpXchg` ·
**Fences:** `Arch_{Compiler,Store,Load,Full}Fence` · **Paging:** `Arch_LoadPageTable/ReadPageTable/FlushTLB` ·
**GDT/IDT/TSS:** `Arch_LoadGDT/LoadIDT/LoadTSS` · **ISR entry:** `Arch_GetIsr*` · **Scheduler:** `Arch_LockScheduler/UnlockScheduler/ForceYield`.

Thêm kiến trúc: tạo `src/arch/<arch>/arch_interface_<arch>.pas` cùng API; không sửa file x86_64.

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
  → call SyscallHandler (syscall_dispatch.pas)
    → switch(syscallId)
      → Disp_Xxx() (syscall_impl.pas) hoặc inline logic
      → break (trả về currentRsp)   ← PHẢI LÀM VẬY
  → return currentRsp (hoặc newRsp nếu context switch)
  → mov rsp, rax
  → iretq
```

---

---

## 5. Build system

### 5.1 Các bước build

```bash
./build.sh
```
1. **Guard "no C#"** — fail nếu còn `.cs` dưới `src/`
2. **`compile_pascal.sh`** — compile mọi unit → `build/*.o`, rồi **strip relocation type-0** (§5.3)
3. **NASM** — `Hardware.obj`, `boot_io.obj`, `smp.bin`
4. **Link** (đều bằng `lld-link`): `Kernel.exe`, các `*.exe` Ring-3
5. Kiểm tra chữ ký KASLR trong `Shell.exe`, sinh RSA key (`private.pem`, gitignored), **ký** `Kernel.exe` → `Kernel.exe.mui`
6. **Chèn public key vào `src/boot/boot.pas`** (marker `{ INJECT_PUBKEY }`, hex dạng `$XX`), `compile_boot.sh`, link bootloader
7. `scripts/gen_auth.py` (PASSWD/SUDOERS) → tạo `hdd.img` FAT16 và `mcopy`

`build.sh` giữ artifact cũ nếu build lỗi (§13.1). Dùng `LLD=<đường dẫn>` để đổi linker.

### 5.1b ⚠️ Đăng ký unit mới — phải sửa CẢ HAI script

| Thiếu ở | Lỗi |
|---|---|
| `compile_pascal.sh` | `lld: error: unsupported relocation type 0x0 in build/<mod>.o` |
| `build.sh` (`KERNEL_OBJS`) | `lld: error: undefined symbol: ...` |

`compile_pascal.sh` có 3 danh sách: `PASCAL_MODULES` (kernel generic + drivers), `ARCH_X86_64_MODULES`
(`src/arch/x86_64/<mod>.pas`) và `APP_MODULES`. Hàm `mod_src` ánh xạ tên → đường dẫn cho `PASCAL_MODULES`
(`src/drivers/*` cần được liệt kê ở đó). `compile_boot.sh` lo riêng `boot.pas`.

### 5.2 Thêm Pascal module mới

1. Tạo `src/kernel/pas/<module>.pas` (hoặc `src/arch/x86_64/`, `src/drivers/`)
2. Thêm vào danh sách tương ứng trong `compile_pascal.sh` (+ `mod_src` nếu nằm ngoài `kernel/pas`)
3. Thêm `build/<module>.o` vào `KERNEL_OBJS` trong `build.sh` (app: thêm một dòng `link_app`)
4. `./build.sh` rồi `./verify_pascal_link.sh`

Toàn bộ quy ước: `docs/PASCAL_PORTING.md`.

### 5.2b ⚠️ File chứa credential: `passwd` + `sudoers`

Hai file này **gitignored** (chứa password hash) nên **không có trong clone
sạch**. `build.sh` copy chúng vào `::/ETC/PASSWD` và `::/ETC/SUDOERS`; thiếu
thì `mcopy` fail (build.sh có `set -e`).

Đã thêm `scripts/gen_auth.py`, chạy ở bước `[2.5/4]` ngay trước khi tạo
đĩa. File đã tồn tại thì **giữ nguyên** để không đổi mật khẩu đang dùng.

```bash
python3 scripts/gen_auth.py                # tạo nếu thiếu
python3 scripts/gen_auth.py --force        # sinh lại salt mới
python3 scripts/gen_auth.py --print        # xem account, không in hash
NEKKO_PASSWORD=... python3 scripts/gen_auth.py --force
```

**Bẫy cần nhớ:** salt được lưu dưới dạng 64 ký tự hex nhưng hash tính trên
**32 byte đã decode**, không phải trên chuỗi hex:

```
sha256(bytes.fromhex(salt_hex) + password)
```

Hash trên chuỗi hex cho digest khác → đăng nhập luôn báo "ACCESS DENIED"
dù file trông hoàn toàn bình thường. Script có `--self-test` tự kiểm tra
lại bằng cặp hash đã biết là đúng, nếu format đổi sẽ fail ngay.

### 5.3 COFF relocation stripping

`compile_pascal.sh` chạy Python script sau khi compile để xóa `IMAGE_REL_AMD64_ABSOLUTE` (type 0) relocations — lld từ chối những reloc này.

**Không sửa logic này.** Script xóa reloc entries, không sửa code bytes. Nếu sửa sai → smash function prologue → #GP crash lúc runtime.

### 5.4 Chạy QEMU

```bash
./run.sh
```

Serial log: QEMU redirect serial → `/tmp/serial.log` (dùng để debug).

---

---

## 6. Bẫy đã biết — PHẢI ĐỌC

### 6.1 📜 (lịch sử) C# interface → crash 0xB0000

**Triệu chứng:** Boot → crash/triple fault tại địa chỉ ~0xB0000 (VGA memory region)
**Nguyên nhân:** `new SomeClass()` qua interface cần `RhpInitialDynamicInterfaceDispatch` → không có trong `--stdlib zero` → vtable pointer uninitialized → CPU nhảy vào VGA memory
**Fix:** Dùng static class với static methods. Không dùng interface, không dùng virtual dispatch.
**Commit:** `36634e0`

### 6.2 ❌ SyscallHandler return wrong value → auto-reboot (quy tắc vẫn nguyên giá trị)

**Triệu chứng:** Kernel boot thành công, chạy được vài giây, sau đó tự reboot
**Nguyên nhân:** `case 12: return X86SyscallImpl.DispatchMapPhysicalMemory(...)` — Dispatch trả về `1` (success). IsrSyscall thực hiện `mov rsp, 1` → `iretq` → triple fault → CPU reset
**Fix:** Đổi `return Dispatch...()` thành `Dispatch...(); break;`
**Commit:** `f2d002f`
**Quy tắc:** Chỉ `DispatchKeyboardRead` được phép `return` (trả về RSP thật cho context switch). Mọi Dispatch khác: gọi xong rồi `break`.

### 6.3 ❌ FPC RTTI → link error

**Triệu chứng:** `lld: error: undefined symbol: RTTI_$SYSTEM_TGUID$indirect` hoặc tương tự
**Nguyên nhân:** FPC tự động sinh RTTI cho record types và type aliases
**Fix:**
- Thêm `{$TYPEINFO OFF}` ở đầu mổi unit
- Dùng `-CD` flag trong compile command
- Dùng built-in types trong export signatures (`Pointer` không phải custom alias)

**⚠️ QUAN TRỌNG — `{$TYPEINFO OFF}` KHÔNG đủ nếu record nằm ở `interface`:**

FPC vẫn sinh RTTI cho **bất kỳ record type nào khai báo trong `interface` section**,
kể cả khi `{$TYPEINFO OFF}` được đặt đúng chỗ. Thứ tự directive không có tác dụng —
đã test cả `{$TYPEINFO OFF}` trước và sau `{$ASMMODE Intel}`.

Kết quả: `lld: error: undefined symbol: RTTI_$SYSTEM_$$_WORD$indirect`

**Fix bắt buộc:** record + pointer typedef **chỉ** khai báo trong `implementation`.
Interface chỉ expose `Pointer`:

```pascal
interface
function Gdt_GetTss: Pointer;          // ← Pointer, không phải PTssEntry

implementation
type
  PTssEntry = ^TTssEntry;             // ← chỉ ở đây
  TTssEntry = packed record ... end;
```

Xem `src/arch/x86_64/gdt.pas`, `idt.pas`, `context.pas` làm mẫu chuẩn.

### 6.3b ❌ RTTI do `unit` khác export record ở interface

Ngay cả khi unit của bạn tự khai báo đúng, **một unit khác** expose record ở
`interface` sẽ kéo RTTI vào link. Kiểm tra trước khi build:

```bash
objdump -t build/<module>.o | grep -i rtti    # phải = 0
```

### 6.3c ❌ Module Pascal mới chưa được strip relocation

Unit mới thêm vào `build/` **phải** được liệt kê trong `compile_pascal.sh`
(`PASCAL_MODULES` hoặc `ARCH_X86_64_MODULES`). Nếu chỉ thêm vào `build.sh` mà
quên `compile_pascal.sh`, reloc type-0 chưa được strip →
`lld: error: unsupported relocation type 0x0 in build/<mod>.o`


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

### 6.6 ❌ Integer underflow trong ACPI parsing (code nay ở `src/apps/acpi_app.pas`)

**Triệu chứng:** `entriesCount` rất lớn (underflow từ uint) → loop đọc ra ngoài bộ nhớ → crash
**Nguyên nhân:** `sdtRealLength - sizeof(ACPISDTHeader)` wrap around khi `sdtRealLength < 36`
**Fix:**
```csharp
uint headerSz = (uint)sizeof(ACPISDTHeader);
int entriesCount = (sdtRealLength > headerSz)
    ? (int)((sdtRealLength - headerSz) / (useXsdt ? 8u : 4u))
    : 0;
```

### 6.7 ❌ MapAcpi null dereference (`acpi_app.pas`)

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

### 6.10 📜 (lịch sử) Smoke test flaky ~1/3 — nguyên nhân thật là §15.0, đã sửa

**Triệu chứng:** `smoke_test.py` báo `[FAIL] boot to login prompt` /
`OS did not reach login prompt within timeout`, nhưng chạy lại thì 9/9.

**Serial log dừng ở đúng dòng 58** (`[+] Process Started!` sau FAT16.EXE),
tức là ngay sau khi spawn 3 daemon, trước login banner.

**Nguyên nhân (KHÔNG phải lỗi code):**
- `Kernel.cs` có vòng chờ handshake daemon với **timeout 30 giây**
  (`PIT.Ticks - daemonWaitStart > 30000`). Nếu daemon handshake chậm
  (ATA/FAT16/Mouse), boot bị trì hoãn tới 30s.
- `smoke_test.py` dùng timeout **cố định 60s** cho `Username:`.
- Tổng thời gian boot đôi khi vượt 60s → test fail dù OS hoàn toàn bình thường.

**Fix khi gặp:** chạy lại smoke test. **Đừng** debug code như thể đây là
regression. Đã đo: 3 lần chạy → 2 pass, 1 fail (đã xác nhận bằng cách
chạy lại và cả bằng log cho thấy boot tiến triển bình thường).

**Lưu ý khi chẩn đoán regression thật:** các unit Pascal mới port (chưa được
C# gọi tới) **không thể** gây ra boot stall, vì chúng chỉ được link chứ chưa
được invoke. Nếu smoke fail, hãy kiểm tra xem module C# tương ứng đã được
thay chưa — nếu chưa thì đây là flaky, không phải regression.


---

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

---

## 8. Quy trình làm việc cho AI agents

### 8.1 Trước khi bắt đầu
1. **Đọc file liên quan** — không suy luận từ tên file
2. **Chạy build trước** — `./build.sh 2>&1 | tail -30` và **kiểm tra exit code** (§13.1, §13.2)
3. Đọc AGENTS.md này, đặc biệt §2, §6, §15

### 8.2 Khi sửa/thêm code kernel
```
1. Đọc unit liên quan và các unit nó `uses`
2. Viết Pascal theo §2 (record ở implementation, không AnsiString động, {$TYPEINFO OFF})
3. Đăng ký unit mới ở CẢ HAI script (§5.1b)
4. ./build.sh  →  ./verify_pascal_link.sh
5. python3 test/automation/smoke_test.py   (+ extra_test.py nếu đụng syscall/shell/sudo/power/acpi,
                                             hwcheck_test.py nếu đụng bootloader/hardware_checks)
6. Commit nhỏ
```
Một unit port/viết mới **chưa từng chạy** gần như chắc chắn có lỗi (xem §15: mọi unit "đã port" đều có lỗi khi nối thật).
Đừng tin comment "compile sạch" — tin test.

### 8.3 Khi thêm syscall mới
```
1. Chọn ID chưa dùng (grep `case` trong syscall_dispatch.pas)
2. Viết thân hàm Disp_* ở syscall_impl.pas (trả mã, KHÔNG phải RSP — §2.3)
3. Thêm case vào syscall_dispatch.pas; chỉ Sched_SwitchTask/Disp_KeyboardRead được gán switchedRsp
4. Nếu app cần gọi: thêm slot cuối bảng ở vdso.pas (chỉ append) + wrapper trong app_api.pas
5. Ghi vào bảng §4.1
```

### 8.4 Debug crash
```
1. Serial log: test/automation/serial.log (smoke_test lưu bản sao ở test/automation/logs/ TRƯỚC khi kill QEMU)
2. Dòng cuối trước crash
3. Reboot sau syscall → case tương ứng có gán nhầm switchedRsp không (§2.3)
4. Link error RTTI → record/enum ở interface (§6.3)
5. Stack corruption → so chữ ký `external name` với định nghĩa (§6.4)
6. Treo không log → `-monitor unix:...` + `info registers -a` / `info lapic` (đã tìm ra lỗi LVT timer one-shot nhờ cách này, §15)
```
Mẹo tách lỗi: chèn `Out8($3F8, Ord('A'))` làm mốc ra COM1 (không phụ thuộc terminal).

### 8.5 Giới hạn agent
- Mỗi agent một nhiệm vụ; không chạy hai agent cùng sửa một file
- Luôn nghiệm thu kết quả agent: đọc file đã sửa, build, chạy test

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

---

## 10. Tests

```bash
python3 test/automation/smoke_test.py    # 10 bước: boot → login → ls → LS → cd.. → root listing → write → ls → cat → shutdown
python3 test/automation/extra_test.py    # 19 bước: builtin kernel (uname/help/mem/uptime/date/pci/unknown), mkdir/rmdir,
                                         #   sudo end-to-end (mkdir/ls/rmdir + sai mật khẩu), REBOOT thật, SHUTDOWN thật (QEMU thoát)
python3 test/automation/hwcheck_test.py  # boot KHÔNG có fw_cfg key: phải dừng ở cổng xác thực, gõ key thì boot tiếp
./verify_pascal_link.sh                  # không .cs, không RTTI, đủ entry point
```

`smoke_test` không phủ builtin của kernel, sudo, reboot/shutdown thật hay cổng xác thực — đó là lý do có `extra_test`/`hwcheck_test`.
Một refactor có thể pass 10/10 mà hỏng cả ba.

⚠️ **Flaky**: boot chậm do Mouse handshake (§6.10, §13.3) — `smoke_test` chạy lại nếu fail ở bước boot. Boot bình thường ~8 s; nếu một boot mất ~53 s thì cơ chế respawn mouse đã chạy (không còn là chuyện bình thường); nếu một boot treo **mãi** (không có dòng `[TIMER] mouse deadline hit`) thì đó là
hồi quy thật (xem §15 — lỗi LVT timer one-shot và lỗi idle-loop nuốt IPC đều trông y hệt "flake").

---

## 11. Việc tiếp theo (thứ tự ưu tiên)

1. ✅ ~~Port toàn bộ C# sang Pascal~~ — kernel, app, bootloader, hạ tầng test (2026-10-26)
2. ✅ ~~Bỏ bflat, link thuần lld~~
3. **Tách phụ thuộc x86_64 khỏi kernel generic** để có thể thêm ARM64 (§7): `scheduler.pas`/`syscall_impl.pas`/
   `interrupt_handlers.pas`/`kernel_main.pas` đang `uses apic, gdt, vmm` trực tiếp. Đưa qua `hal/*`.
4. ✅ ~~Mouse handshake mất ~30–50% boot~~ — **đã tìm ra và sửa** (§15.0). Boot giờ ổn định ~8 s.
5. **Dọn các điểm lệch đã ghi nhận** (§15.3): `MsToTicks_Pas` giả định 100 Hz (PIT chạy 250 Hz), builtin `uptime` in tick thô,
   `Con_Print` có khoá còn `Terminal_Print_Pas` không (in chồng lên nhau giữa các lõi).
6. Mở rộng test: `logout`, `chmod/chown` qua sudo, ghi tệp lớn, nhiều tiến trình đồng thời.
7. ARM64 trên QEMU virt (§7.1 giai đoạn 2).

---

## 12. Ghi chép từ giai đoạn chuyển app sang Pascal (còn hiệu lực)

bflat đã bị loại bỏ hoàn toàn (§1). Các mục dưới đây mô tả **hành vi của hệ thống**, không phải của bflat; tên file C#
(`Kernel.cs`, `Syscall.cs`, `Thread.cs`...) trong đó nay là các file Pascal ở bảng §3.0.

**Công thức link app (xem `build.sh`):** `lld-link -subsystem:console -entry:AppMain -export:AppMain -out:APP.exe build/APP_app.o build/app_api.o ...`
`-export:AppMain` là bắt buộc: `pe_loader.pas` tra tên `AppMain` trong PE **export directory**, không đọc `AddressOfEntryPoint`.
KASLR của app: `app_api` khai báo một QWORD `0x1337BEEFCAFE8BAD` trong `.data`; `PELoader` quét byte-by-byte rồi patch bằng địa chỉ vDSO thật.

### 12.1b ⚠️ ABI của vài syscall không theo tuần tự tham số thường

`app_api.pas` đã vấp một lỗi kiểu này và đã sửa, nhưng còn dễ mắc:

- **slot 27 `CreateSharedBuffer`**: kernel đọc `RCX=destPid`, `RDX=numPages`,
  `R8=&outAddr`, và trả về **hai** giá trị — RAX là địa chỉ của caller, **RBX
  là địa chỉ của tiến trình đích**. Wrapper phải load tay bằng inline asm;
  gọi có kiểu thường sẽ bỏ mất RBX.
- **slot 36 `SudoRun`**: `RCX=appName`, `RDX=password`, `R8=content`,
  `R9=contentLen`.
- **slot 9/14 `GetThreadUID`/`GetThreadGID`**: kernel đọc tid từ
  `GetArg(ctx,0)` = **RCX**, tức tham số ĐẦU TIÊN. `API.cs` khai
  `delegate* unmanaged<uint,uint>`. Wrapper cũ trong `app_api.pas` nhận
  **không tham số** → hỏi credential của chính caller, mọi quyết định
  access-control sẽ sụp.

Khi thêm wrapper mới, **đọc `Syscall.cs` case tương ứng trước** để biết
kernel thực sự đọc thanh ghi nào — đừng suy ra từ tên hàm. Xem §6.4.

### 12.4 ✅ ĐÃ SỬA: MOUSE gửi handshake sau `GrantPort` → mất IPC 44

**Triệu chứng:** mọi lần boot đều in
`[!] Timeout waiting for Mouse handshake! Proceeding anyway.` rồi đứng
30 giây, `Kernel.cs` mới đi tiếp. Smoke test chết vì hết giờ, **không phải**
vì code sai.

**Nguyên nhân:** `mouse_app.pas` gọi `App_GrantPort` **trước** khi gửi
handshake. Comment `[FIX HANG BOOT]` trong bản C# cũ nói "gửi handshake
trước, đừng chờ phần cứng" — nhưng cái "trước" đó chỉ so với phần khởi tạo
PS/2, còn `GrantPort` vẫn nằm phía trên. Nên fix cũ chưa bao giờ có tác
dụng: daemon chết (hoặc mất IPC) trước khi tới lệnh gửi.

**Fix:** đảo lại — `App_SendIPC(0, IPC_MOUSE_READY, 0)` phải nằm **trên**
`App_GrantPort`. Marker chẩn đoán xác nhận thứ tự mới chạy hết
`A(init) D(send) B(grant60) C(grant64) E(drain)` và **không còn dòng timeout**.

**Bài học:** daemon nào kernel chờ handshake thì phải gửi handshake là việc
*đầu tiên*, trước mọi syscall khác — kể cả syscall trông vô hại.

### 12.3 ✅ ĐÃ SỬA: login chập chờn khi FAT16.exe viết bằng Pascal

**Triệu chứng:** boot tới `Username:` ổn định. Nhưng `root` + mật khẩu đúng
thỉnh thoảng bị `[!] ACCESS DENIED!`, và thỉnh thoảng thì
`[+] AUTHENTICATED!`.

**QUAN TRỌNG — đây là lỗi CHẬP CHỜN, không phải lỗi tất định.** Đo được:
FAT16.exe Pascal → 1 fail / 2 pass (cộng 1 lần chạy tay pass). Đừng đi tìm
một nguyên nhân "chắc chắn sai" — nó không luôn xảy ra. Bản C# chỉ mới lấy
được **một** mẫu pass, nên chưa đủ cơ sở kết luận C# sạch.

**Đã loại trừ** (đừng đi lại những hướng này):
- Offset shared memory khớp: `FatResponseData` ở 8192 = `OFF_RESP_DATA`.
- Hằng số IPC khớp trên dây: 30/31/38/39/42 và **311** (size-ack).
  `fat16_app` gọi nó `FS_READ_START`, `login_app` gọi `IPC_READ_ACK` — cùng
  giá trị, chỉ khác tên.
- Vòng chờ bằng receive+yield giống **y hệt** bản C# (`FAT16_Driver.cs:954`),
  nên không phải lỗi dịch.
- `App_Yield` không nhảm syscall: `app_api` slot 12 và `API.cs` `table[12]`
  đều là syscall 98, và `case 98` có thật.
- FAT16 không tự in "Access Denied: You do not have Read (r) permission" —
  nên nó không bị chặn ở tầng access-control.

**Đã sửa.** Nguyên nhân thật: `EOF` **không đảm bảo đã đủ dữ liệu**.

- Server (`fat16_app.pas`) gửi `FS_READ_CHUNK` rồi **chỉ** gửi `FS_READ_EOF`
  khi hết cluster chain. Nó không đếm bao nhiêu chunk client thực sự nhận.
- Client (`login_app.pas` `ReadFileIPC`) coi `EOF` là "đã xong" và `return
  fileSize` — **không kiểm tra gì cả**.
- Chunk server gửi theo thứ tự tuần tự (chỉ gửi sector k sau khi sector
  k-1 được ack), nên client dùng `offset` trong payload là đủ để biết có bị
  thiếu không. Nhưng nếu một chunk lỡ, `PassFileBuf` — là buffer **static**,
  sống qua cả các lần login — giữ lại **nội dung lần trước** ở đúng lỗ hổng
  đó.
- Kết quả: `passSize > 0` nên **không** hiện `CRITICAL ERROR`, nhưng nội
  dung bị lẫn dữ liệu cũ giữa chừng → hash sai → `ACCESS DENIED`. Đúng triệu
  chứng chập chờn quan sát được.

**Fix** (tầng protocol, không phải delay):

1. Xoá toàn bộ `fileBuffer` trước mỗi lần đọc → không còn dữ liệu cũ nào
   sống sót trong lỗ hổng.
2. Client theo dõi `nextOffset` và **từ chối** chunk có `offset <> nextOffset`,
   đặt cờ `gap`.
3. Vẫn ack chunk để daemon không bị kẹt (một daemon kẹt sẽ kéo theo mọi
   tiến trình khác), nhưng `gap` khiến lần đọc đó bị coi là thất bại.
4. Chỉ `return fileSize` khi **không gap và `nextOffset >= fileSize`**.
   Thiếu byte thì báo lỗi thật thay vì trả về file hỏng.
5. Vòng lặp thử lại tối đa `READ_ATTEMPTS = 3` lần cho trường hợp mất
   message thật (race, không phải disk hỏng). Trường hợp file quá buffer
   thì không thử lại — đó là lỗi xác định, không phải race.

**Đo sau khi sửa:** 4/4 lần boot tới login đều `AUTHENTICATED` (trước đó
login fail ~1/3). Trong 5 lần chạy chỉ còn 1 fail, và fail đó ở bước
**boot to login prompt** — flake timeout 60s có sẵn ở §6.10, không liên
quan. Login thì 0 fail.

**Đã sửa tiếp (server ném message).** Unit đã có sẵn `EnqueuePending` và
hàng đợi `PendingHead/PendingTail` từ thời port, nhưng **chỉ được gọi trong
ba vòng chờ của helper ATA**; ba vòng chờ của *file transfer* thì không. Ba
vòng chờ đó giờ đều park message lạ vào hàng đợi (gọi trong nhánh READ và
nhánh WRITE), nên request của client khác còn nguyên và được xử lý sau khi
transfer hiện tại xong. Xem §12.8 trước khi đụng vào đây.

### 12.5 ⚠️ Cạm bẫy khi chẩn đoán: log serial bị cắt khi kill QEMU

Khi smoke test giết QEMU, buffer serial **chưa flush** — `serial.log` bị cắt
cứng ở dòng 58, mất đúng 30 giây cuối, tức là **mất luôn dòng
`Timeout waiting for Mouse`**. Rất dễ kết luận nhầm rằng daemon không in gì.

Muốn thấy phần cuối log: chạy QEMU bằng `run.sh`, **đợi QEMU còn sống**, rồi
đọc log. Marker chẩn đoán cũng phải grep không neo (`^[A-E]` thay vì
`^[A-E]$`) vì serial dùng CRLF nên dòng là `A\r`.

Lưu ý thêm: `pkill -f qemu-system` sẽ **giết luôn chính shell đang chạy
lệnh đó** (chuỗi lệnh chứa "qemu-system"). Đừng dùng `pkill -9 -x
qemu-system-x86_64` để tránh điều đó — **lệnh đó không bao giờ khớp được**.
`/proc/comm` cắt tên process còn 15 ký tự, nên process thật là
`qemu-system-x86`:

```bash
pkill -9 -x qemu-system-x86   # đúng
```

Hệ quả của việc dùng sai tên này rất dễ hiểu nhầm: QEMU cũ vẫn sống và
giữ `hdd.img`, nên `smoke_test.py` của lần chạy sau **thoát ra không in
gì cả** (không phải `[FAIL]`, mà là không có output) — trông như harness
chết. Kiểm tra bằng `ps -eo comm | grep '^qemu-system-x86$'`. Lệnh kết
thúc rồi thì xoá `hdd.img.lock` và **chờ QEMU thực sự biến mất** trước
khi chạy lần kế tiếp, nếu không sẽ dính đúng lỗi tranh chấp disk này.

### 12.8 ⚠️ ĐỪNG gọi `App_GetProcessInfo` trong vòng lặp nóng của daemon

Đã thử thêm kiểm tra "client còn sống" vào `fat16_app.pas` để daemon không
treo khi client chết giữa chừng. Thất bại, phải hoàn nguyên. Ghi lại để
không ai đi lại:

- **Triệu chứng:** boot từ **11 giây** nhảy lên **130 giây**. Smoke test
  (timeout 60s) fail ngay bước "boot to login prompt". Log đầy đủ (chạy
  QEMU tay với `-serial file:`) in thêm
  `[!] Timeout waiting for Mouse handshake! Proceeding anyway.` — tức
  +30 giây, và còn ~90 giây không lý giải được ở chỗ khác.
- **Nguyên nhân chưa rõ**, nhưng phép thử A/B là rõ ràng: chỉ bỏ 3 dòng
  `ClientAlive(...)` (giữ nguyên phần park message) → boot về 11 giây,
  không còn timeout. Vậy thủ phạm là `App_GetProcessInfo`, không phải việc
  park.
- **Bẫy phụ khi làm việc này:** `App_ProcIsJailed` và
  `App_ProcIsPhantomDead` **có implementation nhưng không có khai báo ở
  `interface`** của `app_api.pas`, nên unit khác gọi sẽ ra
  `Identifier not found`. Nếu bỏ công sửa dùm thì nhớ cả hai việc — sửa
  interface rồi khởi tạo biến: `info := nil` **trước** khi gọi
  `App_GetProcessInfo`. `top_app.pas` và `stress_app.pas` đều set
  `p := nil` trước; không làm thế thì biến đựng rác (đo được: `info = 7`)
  và accessor đọc `[7 + 14] = 0x15` → page fault giết app.
- **Kết luận:** đừng dùng phương pháp này để bảo vệ daemon. Nếu cần
  chống treo thì làm ở tầng khác (ví dụ scheduler dọn client chết, hoặc
  bound số vòng quay), không gọi syscall này trong vòng lặp spin.

### 12.9 ✅ Smoke test giờ đọc log, và log lộ ngay hai bug thật

`smoke_test.py` từng **báo PASS cho những lệnh thất bại**, nên kết quả 9/9
không có giá trị chẩn đoán. Đã sửa hai thứ và thêm một thứ:

1. **Lưu log TRƯỚC khi kill QEMU.** `finally` cũ terminate QEMU rồi mới in
   kết quả, nên log cuối luôn bị cắt ở ~58 dòng — mất đúng phần giải thích lỗi.
   Giờ `archive_serial_log()` copy log sang `test/automation/logs/` (đã có
   `*.log` trong `.gitignore`) khi QEMU **còn sống**, cả trong `die()`.
2. **Audit log dù pass hay fail.** `audit_log()` quét các mẫu lỗi
   (PANIC, `EXCEPTION 0x`, `Timeout waiting for ... handshake`, `ACCESS
   DENIED`, `OVERFLOW`, memory fault, `transfer aborted`) và in ra phần
   RESULTS. Một bản 9/9 có timeout trong log giờ được gọi là có vấn đề.
3. **Baseline thay vì window.** Các bước trước chỉ `tail(300)` nên khớp cả
   echo của phím đã gõ ở bước trước. `cd ..` đứng ở prompt suốt nên PASS kể
   cả khi thất bại; `cat hello.txt` PASS chỉ vì bước write echo lại nội dung.
   Giờ dùng `snapshot_lines()` + `tail_since()` để chỉ đọc log sinh ra SAU
   khi gõ.

**Hai bug thật (chưa sửa, mới lộ ra nhờ log):**

- **`cd ..` luôn thất bại.** Nhánh `FS_CD_REQ` trong `fat16_app.pas` chỉ xử
  lý đúng chuỗi `'\'` (về root); mọi tên khác rơi vào `FindEntry` tìm entry
  tên `..`. FAT16 **không lưu entry `.`/`..`** nên tra không bao giờ thấy →
  `FS_CD_RESULT, 0`. Cần tìm cluster cha (quét cây thư mục, hoặc đổi sang
  lưu stack cwd); **không** phải thêm một nhánh so sánh chuỗi.
- **Ghi được nhưng đọc không được.** Log cho thấy `[+] File written
  successfully!` rồi ngay sau đó `cat hello.txt` →
  `[!] Shell: File not found or Access Denied!`. Liên quan mật thiết tới lỗi
  trên: sau `cd ..` hỏng, `CurrentDirCluster` của daemon còn trỏ đâu chưa rõ,
  nên write và cat có thể dùng hai thư mục khác nhau.

**Bài học chung:** đừng dùng `wait_for(r"root@nekkoOS#")` làm bằng chứng.
Prompt quay lại bất kể lệnh thành công hay không — chỉ có text của chính
lệnh đó mới là bằng chứng.

---

---

## 13. Bẫy đã tự vấp (2026-10-12) — đọc trước khi debug Mouse handshake

Ghi lại vì đã đốt một buổi sáng vào đó.

### 13.1 `build.sh` từng xoá sạch artifact trước khi compile — ĐÃ SỬA

Dòng cleanup ở đầu `build.sh` xoá `*.exe` và `hdd.img` **trước khi compile bất cứ
thứ gì**. Một lỗi compile Pascal (hoặc C#) làm `set -e` bắn ra ngay, để lại cây
thư mục **rỗng** — không còn `hdd.img`, không còn app nào.

Hậu quả đo được: `smoke_test.py` báo
`[FATAL] disk image (hdd.img) not found`. Thông báo đó **trông chẳng giống lỗi
build chút nào** nên rất dễ bị hiểu nhầm là QEMU cấu hình sai, và mất hàng giờ
đi sai hướng.

Đã sửa (commit `8bccb1a`): artifact được `mv` sang chỗ tạm, `trap ERR` đưa lại
nếu build không xong. Verify bằng cách chèn lỗi compile thật vào
`ata_app.pas` — build `exit 1`, có thông báo rõ, 11 exe + hdd.img còn nguyên.

**Bài học:** nếu smoke test nói không thấy `hdd.img`, hãy chạy `./build.sh` và
đọc exit code TRƯỚC khi đụng vào QEMU.

### 13.2 Log stale đọc như log mới — bẫy tự đánh lừa chính mình

6 lần đo "đã fix Mouse timeout" là **vô giá trị hoàn toàn**:

- build fail → `hdd.img` không tồn tại
- mỗi run smoke test FATAL ngay, **không tạo log mới**
- lệnh `ls -t logs/*.log | head -1` trong vòng lặp copy **log của lần trước**
- `grep -c 'Timeout waiting'` trên output rỗng → `0 timeouts`
- markers `[MOUSE] b c d e f` in ra đẹp đẹp — nhưng đó là log cũ

Kết luận "đã hết timeout" được rút từ **không có lần chạy nào cả**. Đây là lỗi
của tôi, không phải của test.

**Quy tắc:** trước khi tin một phép đo, kiểm tra phép đo đó có thực sự chạy
không. `[FATAL] ... not found` là bằng chứng phản bác, không phải nhiễu.

### 13.3 Mouse handshake timeout — ĐÃ SỬA (xem §15.0; nội dung dưới là lịch sử điều tra)

**Sự thật đã xác lập (đo, không suy đoán):**
- `App_SendIPC(0, 44, 0)` là **hành động đầu tiên** trong `AppMain`, trước cả
  `App_GrantPort`. Nên lý do "chết trước khi gửi" trong comment cũ là sai.
- `PELoader.LoadAndRun(rawFat, true, false, true, p3, 3)` cho Mouse:
  `runInBackground=true, isJailed=false, forceRoot=true`.
  `forceRoot` ⇒ `UID=0` ⇒ `isKing=true` ⇒ `DispatchGrantPortAccess` **không**
  giết. Không jailed nên nhánh `IsJailed==1 && receiver 0/1` trong `case 5`
  cũng không bắn.
- **~50% boot mất handshake** (đo 3/6 lần với build sạch, và 5/5 ở lần đo khác).
  Không phải flake ~1/3 như §6.10 từng ghi.
- Chi phí: đúng **30 giây** (`PIT.Ticks - daemonWaitStart > 30000`). Không mất
  chức năng — 10/10 bước smoke vẫn pass.

**Ứng viên còn lại, chưa loại trừ:**
- Vòng chờ `Kernel.cs:424-450` chỉ `IO.Hlt()`, **không `Scheduler.Yield()`**
  trong khi vòng chờ ACPI (`Kernel.cs:348-368`) có. Nếu `Hlt` một mình không
  chuyển thread thì Mouse không được schedule. Nhưng nếu đúng vậy thì phải fail
  100%, nên chưa giải thích được tỷ lệ 50%.
- `Scheduler.Threads[receiverId].Active == 0` tại thời điểm Mouse gửi ⇒
  `Syscall.cs:229` **drop message, trả về 0**. Đây là ứng viên mạnh nhất vì nó
  giải thích được intermittency: `Active` là biến race, chỉ cần send trúng lúc
  thread 0 đang chuyển trạng thái là mất. Chưa đo được vì hết giờ.
- `KernelIdleLoop` (`Kernel.cs:101-110`) drain receiver 0 nhưng **chỉ xử lý
  type 9 và 39** — type 44 rơi vào đây sẽ bị vứt. Nhưng `KernelIdleLoop` chỉ
  chạy sau vòng chờ 30s nên chưa thấy đường nào tới được.
- Diagnostic trong chính vòng chờ (in `dbgLoop`) **làm lỗi biến mất hoàn toàn**
  (0/10 lần). Phép thử đó không chứng minh gì về nguyên nhân — nó chỉ chứng minh
  đây là race nhạy với timing, và **không thể quan sát bằng cách chèn code vào
  đúng chỗ đang cần quan sát**.

**Cách làm nếu tiếp tục (nên làm theo thứ tự này):**
1. Thêm wrapper trả giá trị syscall cho `App_SendIPC` trong `mouse_app.pas`
   (khai báo `function ...): Cardinal; cdecl;` ở **cả** `interface` lẫn
   `implementation`, nếu không FPC báo `Calling convention doesn't match`).
   `0` = kernel từ chối queue ⇒ xác nhận ứng viên `Active == 0`.
2. Nếu (1) ra 0: loại bỏ điều kiện `Active == 0` cho receiver là thread kernel,
   hoặc đọc `Active` một cách an toàn hơn.
3. Đăng ký type 44 trong `KernelIdleLoop` đề phòng path khác chạy tới.

### 13.4 FPC: rác sau `end.` được chấp nhận im lặng

`procedure Broken; begin Undefined_Symbol(); end;` **thêm vào sau `end.` cuối
cùng của unit** compile sạch, không warning, không error. Phải chèn lỗi **bên
trong** unit (trước `end.`) thì mới test được đường lỗi compile.

### 13.5 Không đặt `type` ở giữa `implementation` khi đang debug nhanh

Hai lần phải dời `type TFn` / `procedure DbgStep` vì FPC không thấy symbol dù
thứ tự nhìn có vẻ đúng. Nếu phải chèn helper vào app Pascal, khai báo ở
`interface` và `implementation` **cùng một dạng signature** (kể cả `cdecl`).

---

---

## 14. Đơn vị tick: mọi hằng số thời gian phải qua `MsToTicks` (2026-10-13)

`PIT.CurrentFreq = 250` (nạp bởi `PlatformBootstrap.InitLegacyTimer(250)`), nên
**một tick = 4ms**, không phải 1ms. Mọi chỗ so `PIT.Ticks` với một con số trần
trụng đều sai bốn lần.

Lịch sử:
- Vòng chờ daemon cũ ghi `> 30000` với comment "Timeout 30s". Thực đo:
  **11260 tick ≈ 45s** cho ngưỡng mới, tức 30000 tick ≈ 120s. Con số "30 giây"
  trong AGENTS.md trước đây **chưa từng được đo**, chỉ suy từ hằng số.
- Khi đổi sang 45 giây, tôi cũng ghi trần trụng `45000` = **180 giây** → boot
  im lặng hơn 2 phút. Người dùng phát hiện, buộc kiểm tra đồng hồ.

Sửa (Kernel.cs): hằng số là **mili giây**, so với `PIT.MsToTicks(...)`.

**Quy tắc:** không bao giờ so `PIT.Ticks` với số vô danh. Muốn hẹn 45 giây thì
viết `PIT.MsToTicks(45000)`. In ra cũng phải đổi ra ms
(`elapsedTicks * 1000 / PIT.CurrentFreq`), đừng in tick trần trụng.

### 14.1 Phục hồi thay vì đợi

Mouse handshake rơi vào ~50% boot, nguyên nhân **vẫn chưa biết** (mọi phép thử
chèn code vào đúng vòng chờ đều làm lỗi biến mất — thay đổi timing là che nó).
Thay vì tiếp tục đuổi theo, vòng chờ giờ:

- Mỗi lần thử có deadline cứng **45 giây**.
- Hết hạn mà Mouse chưa báo → **giết thread daemon đó và spawn lại MOUSE.EXE**
  (spawn bản mới TRƯỚC khi giết bản cũ, để spawn hỏng không để hệ thống trắng
  daemon).
- Tiến trình con được hưởng deadline đầy đủ của riêng nó, không phải phần dư.
- Ngân sách: **1 lần restart** → tệ nhất ~90s, vẫn trong cửa sổ 150s của smoke.
- ATA/FAT16 **không** restart: chúng là bắt buộc (SYSLOGON đọc từ FAT16 volume),
  chỉ được bỏ qua.

Verify bằng cách **cố tình tắt handshake** trong `mouse_app.pas` (không đo bằng
cách "mong" lỗi tự xảy ra):
```
[TIMER] mouse deadline hit after 45048 ms (11262 ticks)
[!] Mouse handshake timed out - killed the daemon, respawned a fresh one.
[!] Timeout waiting for Mouse handshake after restart. Proceeding anyway.
```
Kèm **10/10 smoke pass**. Không verify được thì coi như chưa sửa.

> Lưu ý: lần đầu "cố tình tắt" tôi sửa nhầm dòng (`App_SendIPC` thay vì
> `DbSendIpc`), nên handshake vẫn chạy và test "pass" một cách vô nghĩa. Nếu
> ép lỗi, phải xác nhận lỗi **thật sự** đã xảy ra bằng log.

---

## 15. Bài học từ lần port cuối (2026-10-26)

### 15.0 ✅ Nguyên nhân gốc của "Mouse handshake flake" (tồn tại hàng tuần)

`KernelIdleLoop` là thân của **mọi** idle task, kể cả idle thread của core 1. Nó rút hộp thư của thread 0 (receiver 0)
để ghi nhận handshake ATA/FAT16 — nhưng chạy trên core 1 thì nó cũng rút và **vứt** thông điệp type 44 (Mouse) rồi
thread 0 chờ hết deadline cho một daemon thật ra đã báo sẵn sàng. Race giữa hai core nên ~30–50% boot dính.
Mọi phép thử chèn code vào vòng chờ "làm lỗi biến mất" vì chúng đổi timing của race giữa hai core đó.

Sửa (`kernel_main.pas`): chỉ **thread 0** được rút hộp thư đó, chỉ **khi daemon chưa lên đủ** (sau đó receiver 0 còn
nhận scancode bàn phím — rút nữa là nuốt phím), và xử lý đủ cả ba loại thông điệp. Kết quả: 14/14 boot ≈ 8 s.
Hệ quả phụ: khi boot nhanh, test phải đợi ~4 s sau prompt vì daemon chuột còn đang khởi tạo 8042.

Bài học: **dữ liệu dùng chung giữa các lõi mà ai cũng "tiện tay" rút ra là lỗi thiết kế**, không phải lỗi timing —
một người nhận một hộp thư.

### 15.1 Mọi unit "đã port, chưa nối" đều có lỗi khi nối thật

Các unit `gdt idt vmm apic ioapic vdso scheduler ...` được ghi là "port xong, link sạch" nhưng chưa bao giờ chạy.
Khi nối từng cái vào kernel (mỗi lần một cái, test sau mỗi lần), đã lộ:

| Unit | Lỗi | Triệu chứng |
|---|---|---|
| `apic.pas` | LVT timer ghi `32` thay vì `0x20000 \| 32` (thiếu bit **periodic**) | core 0 chỉ nhận **một** ngắt timer → ~40% boot treo vĩnh viễn, trông như "flake Mouse" |
| `vmm.pas` | `ENTRY_USER = 2` (đó là bit Writable; User là bit 4); bảng trung gian thiếu cờ U | app Ring-3 fault; `DestroyUserSpace` kiểm sai bit |
| `kstate.pas` | khoá scheduler riêng, không phải `Arch_LockScheduler` | không loại trừ nhau với scheduler thật |
| `sudo` (từ C#) | buffer salt 64 ký tự, parser giữ `cap-1` = 63 → salt thành 31 byte | **không mật khẩu sudo nào từng xác thực được** |
| `sudo` (từ C#) | truyền con trỏ **byte** vào parser dòng PASSWD đọc **wide char** | không account nào khớp |
| `boot.pas` | Boot Services là hàm thường (không có `This`) nhưng wrapper truyền `bs` làm tham số đầu | firmware nhận tham số lệch → page fault |
| `boot.pas` | `GetMemoryMap` nhận buffer, wrapper truyền con trỏ-tới-biến | firmware ghi đè stack |
| `boot.pas` | `U16` trả con trỏ vào mảng **local** của chính nó | chuỗi hỏng ngay lần gọi kế tiếp |
| `boot.pas` | `RsaMod` dịch bit ngược chiều limb | chữ ký không bao giờ xác thực → "YOUR DEVICE IS CORRUPT" |
| `boot.pas` | `IsKernelMain` so sai ký tự | "KernelMain not found" |
| `InternalShell` (từ C#) | `logout` đọc `ETC/PASSWD` rồi kiểm tra header `MZ` | không bao giờ thành công (đã sửa về đọc `syslogon.exe`) |
| `FAT16.cs` (từ C#) | `RemoveDir` gửi IPC hai lần, nhả khoá hai lần | reply thừa kẹt trong mailbox |

Cách phát hiện hiệu quả: **đối chiếu từng hàm với bản gốc, test từng unit riêng, và dùng QEMU monitor
(`info registers -a`, `info lapic`) khi hệ thống treo.**

### 15.2 Bẫy khi đọc kết quả test
- `ps -eo comm | grep '^qemu-system-x86$'` trước mỗi lần chạy QEMU mới (§12.5)
- Chạy nhiều lần (≥10) trước khi kết luận về lỗi ngẫu nhiên: 4 lần pass liên tiếp từng che mất lỗi LVT (nguyên nhân thật chỉ gây ~40%).
- `grep -B`/`-A` rộng trên repo lớn sẽ tràn context — dùng `grep -c`/`-l` trước.

### 15.3 Điểm lệch còn tồn tại (chủ ý giữ nguyên hành vi cũ)
- ✅ `libc.MsToTicks` và builtin `uptime` đã đổi sang 250 Hz (sửa 2026-10-26)
- `Pit_MsToTicks` mới là bản đúng; `power.pas` giữ nguyên các hằng tick cũ (5000/1000/3000 tick)
- `IsValidUserPtr_Pas(…, totalPages)`: một số caller C# cũ truyền số **byte** (nới lỏng giới hạn gấp 4096 lần); bản Pascal luôn truyền số trang
