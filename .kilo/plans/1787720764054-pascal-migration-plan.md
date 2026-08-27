# Bản Kế Hoạch: Chuyển Toàn Bộ Mã Sang Pascal (Bỏ Qua bflat)

## Bối Cảnh
- bflat đã ngừng phát triển >1 năm, không hỗ trợ RISCV64, security risk cao
- bflat chỉ biên dịch C# sang Win64 PE object (x64/ARM64 only)
- FPC (Free Pascal Compiler) là backend Pascal đã hoạt động ổn định, hỗ trợ nhiều arch
- Mục tiêu: giảm phụ thuộc bflat, tận dụng FPC hơn
- Hiện trạng: 12 Pascal modules đã port (libc, prng, kerncrypto, pmm, heap, strandscheduler, ipc, terminal, arch_interface, rtc, fat16)

## Phạm Vi
### Bao Gồm
- Port logic C# còn lại sang Pascal units mới
- Thay thế bflat build bằng FPC cho các module mới
- Thêm test automation để verify sau mỗi migration bước

### Loại Trừ
- ARM64 port (chủ đề khác)
- Các thay đổi giao diện người dùng bảo hiểm

## Kiến Trúc Mục Tiêu
```
Kernel.exe (bflat)  →  Kernel.exe (FPC native)
  ├─ Kernel.cs         →  kernel_unit.pas
  ├─ Syscall.cs        →  syscall_unit.pas
  ├─ FAT16.cs          →  fat16_ext.pas (protocol I/O glue)
  ├─ IPC.cs            →  ipc.pas ✓ (đã port)
  ├─ Heap.cs           →  heap.pas ✓
  ├─ PRNG.cs           →  prng.pas ✓
  ├─ RTC.cs            →  rtc.pas ✓
  ├─ Spinlock.cs       →  strandscheduler.pas ✓
  ├─ StrandScheduler.cs→  strandscheduler.pas ✓
  ├─ Terminal.cs       →  terminal.pas ✓
  ├─ PMM.cs            →  pmm.pas ✓
  ├─ KernCrypto.cs     →  kerncrypto.pas ✓
  ├─ LibC.cs           →  libc.pas ✓ (shim)
  └─ PELoader.cs       →  pe_loader.pas (mới)
```

## Phụ thuộc & Thứ Tự Thực Hiện

## Tiến Độ (Updated 2026-08-27)
### Giai đoạn 1: Nền tảng ✅ HOÀN THÀNH
- 1.1 ✅ Tạo `fpc_runtime.pas` — PE constants, type aliases (built-in types only, no RTTI)
- 1.2 ✅ Thêm `-CD` flag vào compile_pascal.sh
- 1.3 ✅ pe_loader.pas là template mẫu cho module kế tiếp

### Giai đoạn 2: Kernel core logic (porting)
- 2.1 ✅ **Completed**: `PELoader.cs` → `pe_loader.pas`
  - 4 exported functions: ValidateHeaders, CopySections, ApplyRelocations, FindAppMainExport
  - 256 C# lines → 321 Pascal lines (logic chi tiết hơn, bounds checks)
  - Commit 5b223e8: 9/9 smoke test pass
- 2.2 ⏳ `Kernel.cs` → pending (1300 lines, boot sequence)
- 2.3 ⏳ `Syscall.cs` → pending (syscall dispatch)
- 2.4 ⏳ `FAT16.cs` → pending (cluster chain walk, GetFatEntry/SetFatEntry)
- 2.5 ⏳ `ATA.cs` → pending (ATA register I/O wrapper)

### Giai đoạn 2: Port kernel core logic (theo thứ tự dependency)
**Mỗi bước**: port logic → compile Pascal → update build.sh ldflags → rebuild → smoke test

| Bước | C# file | Pascal unit (new) | Logic chính |
|---|---|---|---|
| 2.1 | `PELoader.cs` | `pe_loader.pas` | PE/ELF parsing, relocation |
| 2.2 | `Kernel.cs` | `kernel_main.pas` | Boot sequence, init modules |
| 2.3 | `Syscall.cs` | `syscall_dispatch.pas` | Syscall table, IPC dispatch |
| 2.4 | `FAT16.cs` | fat16 protocol I/O glue (fat16 already has helpers) | Cluster chain walk, GetFatEntry/SetFatEntry |
| 2.5 | `ATA.cs` | `ata_io.pas` | ATA register I/O wrapper (port-specific) |

### Giai đoạn 3: Port userland apps
| Bước | C# file | Pascal unit (new) |
|---|---|---|
| 3.1 | `Shell.cs` | `shell_app.pas` |
| 3.2 | `Login.cs` | `login_app.pas` |
| 3.3 | `FAT16_Driver.cs` | FatResponseData formatting |
| 3.4 | `acpi.cs` | `acpi.pas` |

### Giai đoạn 4: Chuyển build đầy đủ sang FPC
| Bước | Công việc |
|---|---|
| 4.1 | ⏳ Thử build Kernel.exe toàn bộ bằng FPC (không qua bflat) |
| 4.2 | Thử build Shell.exe, FAT16.exe, SysLogon.exe bằng FPC |
| 4.3 | Gỡ bỏ từng target ra khỏi bflat |

## Rủi ro & Giải pháp

| Rủi ro | Giải pháp |
|---|---|
| ABI mismatch giữa C# struct và Pascal record | Dùng `{$packRecords 1}` và kiểm tra size bằng compile-time assertions |
| Calling convention không match (Win64 x64) | FPC -Twin64 + cdecl matches bflat extern calling convention |
| Linker symbol names khác nhau | Dùng `cdecl; public name '...'` để match |
| Kernel panic khi port lỗi | Smoke test ngay sau mỗi module; dùng git bisect để tìm lỗi |
| FAT16_Driver struct layout khác kernel | Driver struct đã có OwnerUID/GID/Permissions ở custom offsets — document rõ trong Pascal |

## Quy trình làm việc (mỗi migration bước)
1. Đọc C# file, xác định logic có thể tách ra (pure functions, no I/O)
2. Tạo `src/kernel/pas/<module>.pas`
3. Thêm module vào `PASCAL_MODULES` trong `compile_pascal.sh`
4. Thêm `--ldflags` vào build.sh cho target cần link
5. Thêm DllImport shim `[DllImport("*", EntryPoint="..._Pas")]` trong C#
6. Build → `python3 test/automation/smoke_test.py` → 9/9 pass
7. Commit + push

## Validation
- **Công cụ**: `test/automation/smoke_test.py` (QEMU headless, 9 steps)
- **Mỗi migration bước** phải pass 9/9 trước khi merge
- **Lint gate**: `grep -rn '\[DllImport(' src/kernel src/drivers src/apps` — chỉ được phép `_Pas` shims
- Kiểm tra `build/asm/ppas.sh` luôn được revert trước commit

## Câu hỏi mở (chưa quyết định)
1. Có nên giữ lại bflat cho Boot.cs (EFI stub) không? — Không, FPC có thể compile UEFI app nhưng cần setup thunk riêng
2. Kernel.cs có ~1300 dòng logic phức tạp — port từng phần hay một lần? — Gợi ý: từng module nhỏ (PELoader đầu tiên)
3. ARM64 prep (#4 AGENTS.md) sẽ chạm vào lệp vực nào? — Chưa rõ, cần ARCHITECTURE.md §5 chi tiết hơn
