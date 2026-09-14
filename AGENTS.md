# AGENTS.md — NekkoOS working notes for AI assistants

## Yêu cầu cốt lõi
- Khi làm bất cứ việc gì, phải tạo ra các agents riêng và giao việc cụ thể cho các agents đó. Bạn làm sếp của các agents, các agents sẽ được phân công các nhiệm vụ cụ thể và hiệu quả cao
- Lưu ý, các agents có thể bị sập do upstream limit, cần handle chuẩn chỉ. Khi agents bị lỗi, phải nghiệm thu kết quả tới thời điểm agents xảy ra lỗi
- Chia nhỏ đầu việc và phân công công việc hợp lý cho từng agents để đạt hiệu quả cao nhất

## Trạng thái hiện tại (cập nhật 2026-09-14)
- Toolchain x86_64 đã cài đủ trên openSUSE Tumbleweed: bflat v10 (~/bflat),
  fpc 3.2.2, mingw64-cross-binutils. Build: `./build.sh` (cần
  `export PATH="$HOME/bflat:/usr/sbin:$PATH"`).
- Kiến trúc 4 lớp đã tách xong: `src/{boot,kernel(+pas),apps,arch,drivers}`.
  Hợp đồng AAL = `src/arch/Arch.cs` (+ twin `arch_interface.pas`),
  **lint gate trong build.sh cấm mọi DllImport ngoài src/arch/** (trừ shim
  `_Pas`, AppMainAsm, và boot Out8/In8 standalone). Vi phạm = build fail.
- **PORTABLE SYSCALL DISPATCH (commits 9c9927d..4aa8f8d)**: 16 syscalls đã
  delegate sang `IArcSyscall` interface trong `src/arch/Arch.cs`:
  - I/O-specific: 1 (print), 2 (pixel), 3 (clear), 4 (kbd), 7 (port), 12 (map phys),
    13 (hw report), 50 (map FB), 51 (FB dims), 52 (FB redirect), 60/61 (ATA lock), 399 (cursor)
  - Arch-specific paging: 6 (heap), 91/93 (set UID/GID + MPU trap),
    99 (global shmem), 101 (shmem pipeline)
  `X86SyscallImpl` chứa logic thật; `ARM64SyscallImpl` trả -1/no-op. Net: -180 dòng
  từ Syscall.cs, 9/9 smoke tests pass.
- **MEGA-CASE EXTRACTION (commits 21ce67a, b8d730a)**: Syscall 88 (Internal Shell)
  tách ra `src/kernel/InternalShell.cs` (197 dòng), Syscall 94 (Sudo) tách ra
  `src/kernel/Sudo.cs` (288 dòng). Syscall.cs giờ chỉ 611 dòng — chỉ làm dispatcher.
- Đã port Pascal: heap ipc kerncrypto libc pmm prng rtc strandscheduler
  terminal fat16 syscall_security memmap_scan scheduler_dispatch pe_loader
  acpi_parse passwd_parser internal_shell (+ arch_interface + HAL impls). libc.pas helpers:
  FormatFATName_Pas, FatNameValid_Pas, OctalStrToUInt_Pas,
  SplitTwoArgs_Pas, MemSet_Pas, StrCmp_Pas, StrStartsWith_Pas,
  Atoi_Pas, AppendDecimal_Pas, IsPrintableChar_Pas, StrEqWideBytes_Pas,
  StrCpyLimited_Pas, WideStrToBytes_Pas, MsToTicks_Pas, StrAppend_Pas,
  StrLen_Pas, MemCopy_Pas.
  ipc.pas adds: IsPrivilegedIpcType_Pas, HasMessageForReceiver_Pas.
  passwd_parser.pas: ParsePasswdLine_Pas, SudoersContains_Pas.
  internal_shell.pas: InternalShell_ParseCommand_Pas.
- Syscall.cs case 94 (sudo) parser loop + inline Atoi/OctalStrToUInt
  + inline StrCmp/char-copy/byte-filter đã chuyển sang Pascal.
- Syscall.cs case 14 (PID-by-name) char loop → StrEqWideBytes_Pas.
- Shell.cs 7+ inline path-copy loops → StrCpyLimited_Pas.
- top.cs/stresstest.cs AppendStr loops → StrAppend_Pas.
- FAT16_Driver.cs 9 inline copy loops + 3 Atoi digit loops → StrCpyLimited_Pas/Atoi_Pas.
- Login.cs PrintLineWithNum + MkdirAsIPC path builder → StrCpyLimited_Pas/AppendDecimal_Pas.
- FAT16.cs 11 inline copy loops + mode/owner encoding → StrCpyLimited_Pas/AppendDecimal_Pas/StrAppend_Pas.
- Shell.cs const copy + get len + append → StrCpyLimited_Pas/StrAppend_Pas.
- top.cs number-to-string + suffix → AppendDecimal_Pas/StrAppend_Pas.
- dsrv.cs 3 block copy loops → MemCopy_Pas.
- explorer.cs string length → StrLen_Pas.
- FAT16 protocol đã tách khỏi raw I/O path: 25+ call sites gọi qua
  fat16.pas (ClusterLba, FatSectorForCluster, ParseBPB, FindFreeCluster,
  GetNextCluster, FatEntryOffset).
- Login/Shell đã normalize hết helper chuỗi lên libc.pas (roadmap #1 XONG).
- AddressSpaces.cs (class Mem) = facade duy nhất scheduler/loader thao tác
  address space; TCB field là `AddrSpace` (handle mờ).
- **Test tự động**: `test/automation/smoke_test.py` 9/9 pass (boot→login→
  ls→LS→cd..→root listing→write→cat→shutdown).
- **PE Export Table Parsing Bug Fixed (2026-09-14)**: Bootloader nhảy sai vào
  0xB0000 (VGA memory) thay vì KernelMain do logic đọc ordinal table sai.
  Đã sửa GetKernelRealEntryPoint: ordinal phải là index vào addressOfFunctions,
  không phải trực tiếp dùng addressOfNameOrdinals[i] làm index.
  
  **ROOT CAUSE & SOLUTION**: Crash thực sự xảy ra khi tạo `new X86SyscallImpl()`.
  Lỗi là do vtable interface dispatch cần runtime function `RhpInitialDynamicInterfaceDispatch`
  nhưng build với `--stdlib zero` không có runtime này. Địa chỉ 0xB0000 là vtable pointer
  chưa được relocated hoặc uninitialized.
  
  **FIX APPLIED**: Đã xóa interface IArcSyscall và chuyển X86SyscallImpl sang static class
  với static methods. Syscall.cs gọi trực tiếp X86SyscallImpl.DispatchXXX() thay vì qua
  interface polymorphism. Kernel boot thành công, tất cả subsystems khởi tạo đúng.
  
  **LESSON LEARNED**: Với --stdlib zero trong bflat, KHÔNG dùng C# interface vì cần
  runtime support. Chỉ dùng static dispatch, function pointers hoặc manual vtable.

- **AUTO-REBOOT BUG FIXED (commit f2d002f, 2026-09-14)**: Hệ thống tự khởi động lại
  sau khi kernel boot thành công và ACPI daemon khởi động.
  
  **ROOT CAUSE**: Syscall.cs case 12 và case 50 dùng `return X86SyscallImpl.Dispatch...()`
  — hàm Dispatch trả về `1` (success code). IsrSyscall thực hiện `mov rsp, rax` → RSP=1
  → `iretq` crash → triple fault → CPU reset. Xảy ra ngay khi ACPI daemon gọi syscall 12
  (MapPhys) lần đầu tiên để map RSDP.
  
  **FIX**: Đổi `return DispatchMapPhysicalMemory(...)` và `return DispatchMapFramebuffer(...)`
  thành gọi hàm + `break` để SyscallHandler trả về `currentRsp` hợp lệ.
  
  **LESSON LEARNED**: Trong SyscallHandler, chỉ được `return` một giá trị là RSP hợp lệ
  (để IsrSyscall thực hiện `mov rsp, rax`). Chỉ `DispatchKeyboardRead` được phép return
  RSP thật vì nó có thể context switch. Mọi Dispatch khác phải dùng `break` không `return`.

## Quy trình port C# → Pascal (ARCHITECTURE.md §3)
1. Port logic sang unit .pas tương ứng, export cdecl tên `*_Pas`
2. compile_pascal.sh tự build (module nằm trong PASCAL_MODULES)
3. Link .o vào target qua --ldflags trong build.sh
4. C# giữ shim mỏng `[DllImport("*", EntryPoint="..._Pas")]`
5. Build → QEMU smoke test → commit ngắn gọn

## Bẫy đã biết khi test tự động
- Gõ phím qua QEMU monitor `sendkey`: PHẢI poll prompt trong serial log
  trước mỗi lần gõ; keystroke dồn trong lúc dispatch bị drop ở tầng 8042.
- Bash escaping: `"cd \\"` gửi 2 backslash — dùng single-quote khi cần `\`.
- `build/asm/ppas.sh` là artifact sinh ra mỗi build → luôn revert trước commit.
- pkill qemu có thể để mồ côi: kiểm tra `pgrep -f qemu-system` + xoá
  `hdd.img.lock` trước khi chạy VM mới.
- Shell.ClearBuffer có bug ABI 2 tham số vs 3 đối với `MemSet_Pas` —
  đã fix ở commit 9ac1100. Mọi shim `_Pas` mới phải so khớp signature với
  `*.pas` export (không thừa nhận/thiếu tham số).
- **RTTI trap**: FPC sinh RTTI cho record types + type aliases → lld không resolve
  `RTTI_$SYSTEM_*$indirect` symbols. Fix: dùng built-in types (Pointer, PByte, ...)
  trong exports, thêm `{$TYPEINFO OFF}` và `-CD` flag. Xem `heap.pas`.

## Chuyển đổi syscall thành portable architecture-agnostic design

### Vấn đề
Hiện tại `Syscall.cs` chứa rất nhiều logic I/O và phần cứng cụp trực tiếp:
- Keyboard polling (case 4)
- Physical memory mapping (case 12, case 50)
- Framebuffer management (case 50, case 51, case 52)
- Disk I/O via IPC (case 88 internal shell)
- Hardware reporting (case 13: APIC init, I/O APIC base)

Điều này khiến Syscall.cs khó port sang kiến trúc mới (ARM64, RISC-V).

### Giải pháp: Syscall dispatch theo kiến trúc (Architecture-Aware Syscall Dispatch)

**Cách hoạt động:**
1. Định nghĩa interface `IArcSyscall` trong `src/arch/Arch.cs` với các phương thức
   `DispatchSyscall(ulong syscallId, RegisterContext* ctx, int threadId, bool isKing)`.
2. Mỗi kiến trúc (x86_64, ARM64, RISC-V) implement interface trong
   `src/arch/{arch}/SyscallImpl.cs` (hoặc `.pas` tương đương).
3. Kernel generic syscall dispatcher gọi `ArchCtx.SyscallImpl.DispatchSyscall(...)`:
   - Nếu syscall là I/O-specific (4, 12, 50, 51, 52, 13): delegate đến ArchCtx implementation.
   - Nếu syscall không được hỗ trợ trên kiến trúc hiện tại: trả về lỗi -ENOSYS
     (`"Syscall này không hỗ trợ trên kiến trúc này"`).
   - Nếu syscall là generic (IPC, heap, process management): xử lý trong kernel.
4. Các syscall chung (IPC, heap, process management) giữ ở kernel generic.
5. Các syscall I/O-specific (keyboard, framebuffer, physical memory mapping)
   được delegate đến `ArchCtx` implementation.

**Lợi ích:**
- Port kiến trúc mới chỉ cần implement syscall vtable, không cần sửa Syscall.cs
- Rõ ràng phân tách generic logic vs architecture-specific I/O
- Hỗ trợ graceful degradation: syscall I/O không có trên arch nào đó được disable

### Phân loại syscall
- **I/O-specific** (delegate to arch): 4 (keyboard), 12 (map phys mem), 50 (map FB), 51 (FB dims), 52 (redirect FB), 13 (hardware report)
- **Generic** (kernel): 0 (exit), 1 (print), 2 (draw pixel - uses Terminal abstraction), 3 (clear screen), 5 (IPC send), 6 (heap alloc), 7 (I/O port grant - arch-specific but privileged), 8 (IPC receive), 10 (process info), 11 (ACPI RSDP), 14 (find PID by name), 88 (internal shell), 89-94 (auth), 100 (shared mem)

### Plan hành động refactor
1. Tạo interface `IArcSyscall` trong `src/arch/Arch.cs`
2. x86_64 implementation: `src/arch/x86_64/SyscallImpl.cs` (chứa cases 4, 12, 50, 51, 52, 13)
3. ARM64 skeleton: `src/arch/arm64/SyscallImpl.cs` (stub cho I/O syscalls, trả -ENOSYS)
4. RISC-V port sẽ inherit ARM64 stubs
5. Refactor Syscall.cs: generic cases ở lại, I/O-specific cases gọi qua `ArchCtx.SyscallImpl`
6. Build + smoke test để đảm bảo x86_64 vẫn hoạt động
## Việc tiếp theo (đề xuất, thứ tự ưu tiên)
1. ~~Chuẩn hóa helper chuỗi còn lại giữa Login/Shell vên libc.pas~~ ✅ XONG
2. ~~Tách protocol FAT16 daemon khỏi port-I/O raw path~~ ✅ XONG
3. ~~Cải thiện bảng ls: +permissions cột, name 16-char~~ ✅ XONG
4. ~~Port ACPI parsing sang Pascal (acpi_parse.pas)~~ ✅ XONG
5. ~~Port PELoader KASLR scan sang Pascal~~ ✅ XONG
6. ~~Port Atoi, AppendDecimal, GetNextCluster, FatEntryOffset sang Pascal~~ ✅ XONG
7. **REFACTOR: Implement portable syscall dispatch per-architecture** (xem chi tiết ở trên)
8. ARM64 port theo checklist ARCHITECTURE.md §5 (khung đã đầy đủ)
