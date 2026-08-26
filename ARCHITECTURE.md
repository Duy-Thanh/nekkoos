# NekkoOS Architecture & Porting Guide

## 0. Bố cục mã nguồn

```
src/
  boot/          Bootloader EFI (Boot.cs), hợp đồng bàn giao (BootContract.cs),
                 boot_io.asm
  kernel/        Lõi kernel arch-neutral (C#): Syscall, Thread, IPC,
                 FAT16/ATA protocol, PELoader, vDSO... + shim C# gọi _Pas
    pas/         9 unit Pascal dùng chung (heap ipc kerncrypto libc pmm prng
                 rtc strandscheduler terminal) - build bởi compile_pascal.sh
  apps/          Userland Ring 3: Shell, Login, daemons (acpi ata fat16 mouse
                 dsrv), top, explorer, stresstest + API.cs vDSO surface
  arch/          AAL contract (arch_interface.pas) + HAL interfaces (hal/)
                 + per-arch implementation (x86_64/: Hardware.asm, GDT IDT ISR
                 InterruptHandlers PIC PIT APIC IOAPIC SMP VMM smp trampoline,
                 PlatformBootstrap, ContextLayout)
```

## 1. Nguyên tắc phân lớp

```
+--------------------------------------------------------------+
|  Kernel generic (arch-neutral C#): Kernel, Syscall, Thread,   |
|  IPC, Scheduler, FAT16/ATA protocol logic, Heap, PMM, vDSO    |
+---------------------------------------------------------------+
|  Architecture Abstraction Layer (AAL) - HỢP ĐỒNG ỔN ĐỊNH       |
|  ~50 symbol Arch_* : port I/O, MMIO, atomics, fences,          |
|  GDT/IDT/TSS load, TLB, NX, ISR addresses, FPU, halt/pause     |
+---------------------------------------------------------------+
|  Per-arch implementation:                                      |
|    src/arch/x86_64/Hardware.asm (NASM, duy nhất chạm CPU)      |
+---------------------------------------------------------------+
```

Quy tắc bất di bất dịch: **không file nào ngoài `src/arch/<arch>/` được
chạm thanh ghi/tài nguyên CPU-specific trực tiếp**. Mọi truy cập phải đi
qua symbol `Arch_*` (C# khai báo `[DllImport("*", EntryPoint="Arch_…")]`,
Pascal khai báo trong `src/arch_interface.pas`).

## 2. Phân loại module hiện tại

### Arch-neutral (port được sang arch khác mà không sửa logic)
- `Kernel.cs`, `Syscall.cs`*, `Thread.cs`*, `IPC.cs`→ipc.pas,
  `Heap.cs`→heap.pas, `PMM.cs`→pmm.pas, `PRNG.cs`→prng.pas,
  `RTC.cs`→rtc.pas, `Terminal.cs`→terminal.pas,
  `StrandScheduler.cs`→strandscheduler.pas, `KernCrypto.cs/Crypto.cs`
  →kerncrypto.pas, `FAT16.cs`, `FAT16_Driver.cs`, `ATA*.cs`,
  `PELoader.cs`, `Spinlock.cs`, `vDSO.cs`, `LibC.cs`*
- (\*) có vài điểm chạm CR3/PML4 - xem mục 4

### x86_64-only (`src/arch/x86_64/`)
- `Hardware.asm` - toàn bộ primitive `Arch_*` (inline asm)
- `smp_x86.asm` - trampoline SMP real-mode
- `GDT.cs`, `IDT.cs`, `ISR.cs`, `InterruptHandlers.cs` (exception frame
  layout Rax…Rip/Rsp/Rfl), `PIC.cs`, `PIT.cs`, `APIC.cs`, `IOAPIC.cs`,
  `SMP.cs`, `VMM.cs` (4-level paging PML4)

### Legacy-ISA (x86 nhưng không bắt buộc arch khác phải có)
- PS/2: `KeyboardDriver.cs`, `MouseDriver.cs`; UART: `Serial.cs`;
  PCI config: `PCI.cs`; ACPI: `Power.cs`, `acpi.cs`, `Boot.cs`

## 3. Pascal shared units (logic dùng chung, build bằng FPC)

`heap, ipc, kerncrypto, libc, pmm, prng, rtc, strandscheduler, terminal`
(+ `arch_interface` + HAL impls). C# tương ứng chỉ là shim
`[DllImport("*", EntryPoint="…_Pas")]`. Quy trình chuyển đổi mới:
1) port logic sang `src/<module>.pas` với export cdecl
2) compile trong `compile_pascal.sh` → `build/<module>.o`
3) link vào Kernel qua `--ldflags` trong build.sh
4) C# giữ lại shim mỏng để Ring3/kernel gọi cùng symbol

## 4. Nợ kiến trúc (trạng thái cập nhật)

- ~~`Syscall.cs`/`Thread.cs`: đọc `ctx->Rax…Rip` trực tiếp~~ → **XONG**:
  `ArchCtx` (GetNumber/GetArg/SetRet/SetRet2) trong
  `arch/x86_64/ContextLayout.cs`; kernel generic không còn đụng tên thanh ghi
- ~~`VMM.cs`~~ → **đúng vị trí**: CR3/TLB qua HAL; PML4 walk là impl x86_64 chính đáng
- ~~PS/2/Serial/PIT wiring~~ → `PlatformBootstrap.cs`; DMA purge →
  `PCI.DisableAllBusMastering()`; mask 8259 → `PIC.MaskAllIrqs()`;
  xả buffer 8042 → `PlatformBootstrap.DrainPs2Buffers()`;
  anti-tamper/CheckHardwareError → `arch/x86_64/HardwareChecks.cs`;
  vDSO stub `int 0x80` → `arch/x86_64/vDSO.cs`
- ~~Boot contract nhân bản~~ → `src/BootContract.cs`

### Coupling platform còn lại (chấp nhận có chủ ý, KHÔNG phải CPU-arch)
- `apps/Mouse.cs`: daemon Ring3 điều khiển thẳng 8042 qua cổng được
  vDSO cấp quyền — mô hình microkernel chủ đích; ARM64 sẽ thay bằng
  USB-HID daemon tương ứng
- `boot/Boot.cs`: in debug ra COM1 — thuộc boot contract, arch mới tự
  chọn UART của nó
- `kernel/LibC.cs` → `HardwareChecks.GetFwCfgSelector`: fw_cfg là
  interface thiết bị ảo QEMU (không phụ thuộc CPU); giữ lại làm chuẩn
  phát hiện máy ảo

## 5. Port kit — checklist port sang kiến trúc mới (vd ARM64)

**Bề mặt hợp đồng C#**: `src/arch/Arch.cs` — class tĩnh duy nhất chứa toàn
bộ extern `Arch_*` (~30 primitive: ports, MMIO, fences, atomics, GDT/IDT/
TSS load, ISR addresses, timestamp). **Lint gate trong build.sh CHẶN cứng**
mọi `[DllImport("Arch_…")]` ngoài `src/arch/` — vi phạm = build fail.

Việc cần làm khi port, theo thứ tự:

1. Tạo `src/arch/<arch>/Hardware.asm` (hoặc .S) export đúng các symbol
   `Arch_*` (danh mục tham chiếu: `src/arch/arch_interface.pas`)
2. Thay thế bộ implementation file trong `src/arch/<arch>/`:
   - `ContextLayout.cs` — frame layout + mapping vai trò `ArchCtx`
     (GetNumber/GetArg/SetRet/SetRet2)
   - `PlatformBootstrap.cs` — early serial, hook ngắt input, legacy timer
   - `GDT/IDT/ISR/InterruptHandlers.cs` — descriptor table + exception glue
   - `PIC/PIT/APIC/IOAPIC/SMP.cs` — interrupt controller + SMP bring-up
     (ARM64: GIC + arch timer)
   - `VMM.cs` — paging impl (ARM64: bảng trang 4-level AA64)
   - `vDSO.cs` — blob mã máy syscall entry (ARM64: `svc #0`)
   - `HardwareChecks.cs` — anti-tamper boot check
3. Bootloader: EFI stub cho arch đó (`src/boot/Boot.cs` build với
   `--arch <new>`) + `boot_io.asm` thay bằng helper tương ứng
4. **Không sửa gì cả**: `src/kernel/*`, `src/kernel/pas/*`, `src/apps/*`
   — chỉ thêm dòng build mới vào build.sh
5. Chạy bộ verify: build sạch → QEMU boot → login → sudo → FAT16 CRUD →
   SMP N cores
