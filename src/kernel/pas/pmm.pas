{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: PMM - Physical Memory Manager bitmap allocator (Pascal Implementation)
  PURPOSE: Pure, architecture-independent bitmap allocation algorithm ported
           from src/PMM.cs. Firmware/boot-protocol specific memory-map
           parsing (UEFI EFI_MEMORY_DESCRIPTOR walking) stays in Kernel-side
           C# (src/PMM.cs Init()) since that belongs to the boot-glue layer,
           not the CPU architecture layer - this module only owns the
           bitmap search/mark/clear algorithm, so it works unmodified on
           any future architecture as long as "physical page index" is a
           valid concept there.
  =========================================================================
}

unit pmm;

{$mode objfpc}
{$h+}
{$inline on}

interface

const
  PMM_INVALID_INDEX: QWord = QWord($FFFFFFFFFFFFFFFF);

{ [STATE] Được Init() bên C# gọi để đăng ký bitmap + kích thước bộ nhớ vật lý }
procedure PMM_SetState(aBitmap: PByte; aTotalPages: QWord; aBitmapSize: QWord; aFreePages: QWord); cdecl; public name 'PMM_SetState_Pas';
procedure PMM_SetFreePages(aFreePages: QWord); cdecl; public name 'PMM_SetFreePages_Pas';

{ [BITMAP OPS] Dùng nội bộ trong Init() để đánh dấu vùng nhớ free/reserved }
procedure PMM_SetBit(index: QWord); cdecl; public name 'PMM_SetBit_Pas';
procedure PMM_ClearBit(index: QWord); cdecl; public name 'PMM_ClearBit_Pas';
function PMM_TestBit(index: QWord): Byte; cdecl; public name 'PMM_TestBit_Pas';

{ [QUERIES] }
function PMM_GetTotalPages: QWord; cdecl; public name 'PMM_GetTotalPages_Pas';
function PMM_GetFreePages: QWord; cdecl; public name 'PMM_GetFreePages_Pas';

{ [ALLOCATOR CORE] Không tự khóa (locking do C# Spinlock đảm nhiệm bên ngoài).
  Trả về PMM_INVALID_INDEX nếu thất bại. }
function PMM_AllocatePageIndex: QWord; cdecl; public name 'PMM_AllocatePageIndex_Pas';
function PMM_AllocatePageBelow4GBIndex: QWord; cdecl; public name 'PMM_AllocatePageBelow4GBIndex_Pas';
function PMM_AllocateContiguousIndex(count: QWord): QWord; cdecl; public name 'PMM_AllocateContiguousIndex_Pas';

{ [FREE] Trả về: 0 = no-op (trang bảo vệ / ngoài phạm vi), 1 = free thành công,
  2 = double-free / trang chưa được cấp phát (C# sẽ in cảnh báo). }
function PMM_FreePageByIndex(index: QWord): Byte; cdecl; public name 'PMM_FreePageByIndex_Pas';

implementation

var
  Bitmap: PByte = nil;
  TotalPages: QWord = 0;
  FreePages: QWord = 0;
  BitmapSize: QWord = 0;
  LastUsedIndex: QWord = 0;

procedure PMM_SetState(aBitmap: PByte; aTotalPages: QWord; aBitmapSize: QWord; aFreePages: QWord); cdecl;
begin
  Bitmap := aBitmap;
  TotalPages := aTotalPages;
  BitmapSize := aBitmapSize;
  FreePages := aFreePages;
  LastUsedIndex := 0;
end;

procedure PMM_SetFreePages(aFreePages: QWord); cdecl;
begin
  FreePages := aFreePages;
end;

procedure PMM_SetBit(index: QWord); cdecl;
var
  byteIndex: QWord;
begin
  if index >= TotalPages then Exit;
  if Bitmap = nil then Exit;
  byteIndex := index div 8;
  if byteIndex >= BitmapSize then Exit;
  Bitmap[byteIndex] := Bitmap[byteIndex] or (Byte(1) shl (index mod 8));
end;

procedure PMM_ClearBit(index: QWord); cdecl;
var
  byteIndex: QWord;
begin
  if index >= TotalPages then Exit;
  if Bitmap = nil then Exit;
  byteIndex := index div 8;
  if byteIndex >= BitmapSize then Exit;
  Bitmap[byteIndex] := Bitmap[byteIndex] and not (Byte(1) shl (index mod 8));
end;

function PMM_TestBit(index: QWord): Byte; cdecl;
var
  byteIndex: QWord;
begin
  PMM_TestBit := 0;
  if index >= TotalPages then Exit;
  if Bitmap = nil then Exit;
  byteIndex := index div 8;
  if byteIndex >= BitmapSize then Exit;
  if (Bitmap[byteIndex] and (Byte(1) shl (index mod 8))) <> 0 then
    PMM_TestBit := 1;
end;

function PMM_GetTotalPages: QWord; cdecl;
begin
  PMM_GetTotalPages := TotalPages;
end;

function PMM_GetFreePages: QWord; cdecl;
begin
  PMM_GetFreePages := FreePages;
end;

{ [OPTIMIZATION] Next-Fit: quét từ LastUsedIndex đến cuối, rồi vòng lại từ 0 }
function PMM_AllocatePageIndex: QWord; cdecl;
var
  i: QWord;
begin
  PMM_AllocatePageIndex := PMM_INVALID_INDEX;
  if TotalPages = 0 then Exit;

  { Lượt 1: từ LastUsedIndex đến cuối }
  for i := LastUsedIndex to TotalPages - 1 do
  begin
    if PMM_TestBit(i) = 0 then
    begin
      PMM_SetBit(i);
      Dec(FreePages);
      LastUsedIndex := i;
      PMM_AllocatePageIndex := i;
      Exit;
    end;
  end;

  { Lượt 2: từ đầu đến LastUsedIndex (tránh QWord underflow khi LastUsedIndex=0) }
  if LastUsedIndex > 0 then
  begin
    for i := 0 to LastUsedIndex - 1 do
    begin
      if PMM_TestBit(i) = 0 then
      begin
        PMM_SetBit(i);
        Dec(FreePages);
        LastUsedIndex := i;
        PMM_AllocatePageIndex := i;
        Exit;
      end;
    end;
  end;
end;

{ [MEMORY CONSTRAINT] Cấp phát trang dưới 4GB cho SMP Trampoline (Protected Mode) }
function PMM_AllocatePageBelow4GBIndex: QWord; cdecl;
var
  maxPage, i: QWord;
begin
  PMM_AllocatePageBelow4GBIndex := PMM_INVALID_INDEX;

  maxPage := TotalPages;
  if maxPage > 1048576 then maxPage := 1048576; { 4GB / 4096 }
  if maxPage <= 10 then Exit;

  for i := 10 to maxPage - 1 do { Skip pages 0-9 (protected) }
  begin
    if PMM_TestBit(i) = 0 then
    begin
      PMM_SetBit(i);
      Dec(FreePages);
      PMM_AllocatePageBelow4GBIndex := i;
      Exit;
    end;
  end;
end;

{ [BƠM VIAGRA] Cấp phát count trang liền kề, không bao giờ chạm 16MB đầu tiên
  (Vùng Đất Cấm), tuyệt đối không fallback về page 0. }
function PMM_AllocateContiguousIndex(count: QWord): QWord; cdecl;
var
  i, j, startPage, consecutiveFree, searchStart: QWord;
begin
  PMM_AllocateContiguousIndex := PMM_INVALID_INDEX;
  if count = 0 then Exit;
  if count > 1024 * 1024 then Exit; { Giới hạn 4GB liền kề }
  if TotalPages = 0 then Exit;

  if LastUsedIndex > 4096 then searchStart := LastUsedIndex else searchStart := 4096;

  { [VÒNG QUÉT CHÍNH] Tiến lên đỉnh RAM }
  consecutiveFree := 0;
  startPage := 0;
  if searchStart < TotalPages then
  begin
    for i := searchStart to TotalPages - 1 do
    begin
      if PMM_TestBit(i) = 0 then
      begin
        if consecutiveFree = 0 then startPage := i;

        if consecutiveFree < PMM_INVALID_INDEX - count then
          Inc(consecutiveFree)
        else
        begin
          consecutiveFree := 0;
          Continue;
        end;

        if consecutiveFree = count then
        begin
          for j := startPage to startPage + count - 1 do
          begin
            if j < TotalPages then
            begin
              PMM_SetBit(j);
              Dec(FreePages);
            end;
          end;
          LastUsedIndex := startPage + count;
          PMM_AllocateContiguousIndex := startPage;
          Exit;
        end;
      end
      else consecutiveFree := 0;
    end;
  end;

  { [VÒNG QUÉT LẦN 2] Từ mốc 16MB (page 4096) đến searchStart - không bao giờ
    quét ngược về page 0. }
  if searchStart > 4096 then
  begin
    consecutiveFree := 0;
    for i := 4096 to searchStart - 1 do
    begin
      if PMM_TestBit(i) = 0 then
      begin
        if consecutiveFree = 0 then startPage := i;

        if consecutiveFree < PMM_INVALID_INDEX - count then
          Inc(consecutiveFree)
        else
        begin
          consecutiveFree := 0;
          Continue;
        end;

        if consecutiveFree = count then
        begin
          for j := startPage to startPage + count - 1 do
          begin
            if j < TotalPages then
            begin
              PMM_SetBit(j);
              Dec(FreePages);
            end;
          end;
          LastUsedIndex := startPage + count;
          PMM_AllocateContiguousIndex := startPage;
          Exit;
        end;
      end
      else consecutiveFree := 0;
    end;
  end;
end;

{ [THIẾT QUÂN LUẬT] Thu hồi 1 trang vật lý. Pages 0-9 (BIOS IVT + SMP
  Trampoline) không bao giờ được free. }
function PMM_FreePageByIndex(index: QWord): Byte; cdecl;
const
  minProtectedPage: QWord = 0;
  maxProtectedPage: QWord = 9;
begin
  PMM_FreePageByIndex := 0; { no-op mặc định }

  if (index >= minProtectedPage) and (index <= maxProtectedPage) then Exit;
  if index >= TotalPages then Exit;

  if PMM_TestBit(index) = 0 then
  begin
    PMM_FreePageByIndex := 2; { double-free / chưa cấp phát }
    Exit;
  end;

  PMM_ClearBit(index);
  Inc(FreePages);
  if FreePages > TotalPages then FreePages := TotalPages; { Sanity clamp }

  if index < LastUsedIndex then LastUsedIndex := index;

  PMM_FreePageByIndex := 1;
end;

end.
