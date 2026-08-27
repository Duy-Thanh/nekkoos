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

## Việc tiếp theo (đề xuất, thứ tự ưu tiên)
1. ~~Chuẩn hóa helper chuỗi còn lại giữa Login/Shell vên libc.pas~~ ✅ XONG
2. ~~Tách protocol FAT16 daemon khỏi port-I/O raw path~~ ✅ XONG
3. ~~Cải thiện bảng ls: +permissions cột, name 16-char~~ ✅ XONG
4. ARM64 port theo checklist ARCHITECTURE.md §5 (khung đã đầy đủ)
5. **BƯỚC MỚI: Chuyển toàn bộ mã sang Pascal** (bflat EOL, không hỗ trợ RISCV64)
   - Xem kế hoạch chi tiết tại `.kilo/plans/1787720764054-pascal-migration-plan.md`
