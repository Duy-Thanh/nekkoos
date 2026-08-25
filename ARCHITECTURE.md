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

- ~~`Syscall.cs`/`Thread.cs`: đọc `ctx->Rax…Rip` trực tiếp~~ → **layout đã
  tách** sang `arch/x86_64/ContextLayout.cs`. Còn lại: ~125 lượt truy cập
  `ctx->` cần thay bằng accessor per-arch (`Arch_GetCtxReg/SetCtxReg`)
  trước khi port ARM64
- `VMM.cs`: CR3/TLB đã đi qua HAL (`HAL_GetCurrentPageTable`,
  `HAL_FlushTLBAddress`). VMM.cs hiện ĐÚNG vị trí trong arch/x86_64/
  với tư cách implementation mmu của x86_64; việc migrate toàn bộ walk
  PML4 sang Pascal (mmu_impl.pas) là tối ưu hóa, không còn là nợ chặn port
- ~~PS/2/Serial/PIT wiring rải trong Kernel.cs~~ → **tập trung** vào
  `arch/x86_64/PlatformBootstrap.cs`; kernel generic chỉ gọi 3 method.
  Bước kế tiếp: driver registry runtime (bật/tắt qua boot flag) thay vì
  compile-time wiring
- ~~Boot contract nhân bản ở Boot.cs + Kernel.cs~~ → **tách** thành
  `src/BootContract.cs` (NekkoBootInfo duy nhất, cả 2 phía tham chiếu).
  Việc còn lại: thêm version field + checksum cho contract khi thêm
  field mới

## 5. Checklist port sang kiến trúc mới (vd ARM64)

1. Tạo `src/arch/arm64/Hardware.asm` (hoặc .S) cài đặt đủ ~50 symbol
   `Arch_*` theo `src/arch_interface.pas`
2. Thay thế: GDT/IDT/TSS → hệ thống tương đương; PIC/PIT/APIC/IOAPIC →
   GIC + arch timer; VMM PML4 → bảng trang 4-level ARM
3. Port exception/syscall frame layout trong
   `arch/arm64/InterruptHandlers.cs` + ISR glue
4. Boot: EFI stub ARM64 cho `Boot.cs` + bootloader asm riêng
5. Giữ nguyên toàn bộ kernel generic + userland (chỉ recompile
   `--arch arm64`)
6. Chạy bộ verify: boot → login → sudo → FAT16 CRUD → SMP 2 core
