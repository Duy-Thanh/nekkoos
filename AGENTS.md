# AGENTS.md — NekkoOS working notes for AI assistants

## Trạng thái hiện tại (cập nhật 2026-08-26)
- Toolchain x86_64 đã cài đủ trên openSUSE Tumbleweed: bflat v10 (~/bflat),
  fpc 3.2.2, mingw64-cross-binutils. Build: `./build.sh` (cần
  `export PATH="$HOME/bflat:/usr/sbin:$PATH"`).
- Kiến trúc 4 lớp đã tách xong: `src/{boot,kernel(+pas),apps,arch,drivers}`.
  Hợp đồng AAL = `src/arch/Arch.cs` (+ twin `arch_interface.pas`),
  **lint gate trong build.sh cấm mọi DllImport ngoài src/arch/** (trừ shim
  `_Pas`, AppMainAsm, và boot Out8/In8 standalone). Vi phạm = build fail.
- Đã port Pascal: heap ipc kerncrypto libc pmm prng rtc strandscheduler
  terminal (+ arch_interface + HAL impls). libc.pas mới thêm:
  FormatFATName_Pas, FatNameValid_Pas, OctalStrToUInt_Pas,
  SplitTwoArgs_Pas, MemSet_Pas delegation.
- AddressSpaces.cs (class Mem) = facade duy nhất scheduler/loader thao tác
  address space; TCB field là `AddrSpace` (handle mờ).

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

## Việc tiếp theo (đề xuất, thứ tự ưu tiên)
1. Chuẩn hóa helper chuỗi còn lại giữa Login/Shell về libc.pas
2. Tách protocol FAT16 daemon khỏi port-I/O raw path
3. Terminal API vẽ bảng cho ls (đã align cột 12, có thể nâng cấp bảng đẹp hơn)
4. ARM64 port theo checklist ARCHITECTURE.md §5 (khung đã đầy đủ)
