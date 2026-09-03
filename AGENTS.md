# AGENTS.md — NekkoOS working notes for AI assistants

## Trạng thái hiện tại (cập nhật 2026-08-27)
- Toolchain x86_64 đã cài đủ trên openSUSE Tumbleweed: bflat v10 (~/bflat),
  fpc 3.2.2, mingw64-cross-binutils. Build: `./build.sh` (cần
  `export PATH="$HOME/bflat:/usr/sbin:$PATH"`).
- Kiến trúc 4 lớp đã tách xong: `src/{boot,kernel(+pas),apps,arch,drivers}`.
  Hợp đồng AAL = `src/arch/Arch.cs` (+ twin `arch_interface.pas`),
  **lint gate trong build.sh cấm mọi DllImport ngoài src/arch/** (trừ shim
  `_Pas`, AppMainAsm, và boot Out8/In8 standalone). Vi phạm = build fail.
- Đã port Pascal: heap ipc kerncrypto libc pmm prng rtc strandscheduler
  terminal fat16 (+ arch_interface + HAL impls). libc.pas mới thêm:
  FormatFATName_Pas, FatNameValid_Pas, OctalStrToUInt_Pas,
  SplitTwoArgs_Pas, MemSet_Pas delegation, StrCmp_Pas, StrStartsWith_Pas.
  fat16.pas cung cấp 6 helper protocol thuần: CheckSector_Pas,
  ClusterLba_Pas, FatSectorForCluster_Pas, ParseBPB_Pas,
  FindFreeCluster_Pas, IsValidCluster_Pas.
- FAT16 protocol đã tách khỏi raw I/O path: mọi cluster-LBA/FAT-sector/BPB
  math trong kernel FAT16.cs và userland FAT16_Driver.cs hiện gọi qua
  fat16.pas. 25+ call sites đã wire (ClusterLba_Pas, FatSectorForCluster_Pas,
  ParseBPB_Pas, FindFreeCluster_Pas). Kernel FindFreeCluster inner loop
  thay thế bằng FindFreeCluster_Pas. Init/AppMain thay 3 dòng BPB math
  bằng ParseBPB_Pas (đã xử lý BytesPerSector=0 default).
- Login/Shell đã normalize hết helper chuỗi lên libc.pas (roadmap #1 XONG).
  Lưu ý: bản ClearBuffer cũ có bug ABI 2 tham số vs 3 — đã fix trong phiên
  2026-08-27 (commit 9ac1100).
- AddressSpaces.cs (class Mem) = facade duy nhất scheduler/loader thao tác
  address space; TCB field là `AddrSpace` (handle mờ).
- **Test tự động**: có `test/automation/smoke_test.py` chạy QEMU headless,
  poll serial, gõ phím, verify pass/fail, dọn dẹp.

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
