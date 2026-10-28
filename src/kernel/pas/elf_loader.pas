{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: elf_loader - load a static ELF64 executable as a user process.

  The counterpart of pe_loader for architectures whose user programs are ELF
  (ARM64). The image is untrusted: every header field is bounds-checked
  against the buffer, segments must lie in user address space
  (>= Hal_UserVaMin, canonical), and each is copied page by page into freshly
  allocated frames mapped through arch_hal.
  =========================================================================
}
unit elf_loader;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Parse and load `image` (size bytes) and start it as a user thread named
  `name` (UTF-16). Flags as for PELoader_LoadAndRun. Returns the thread id, or
  -1 when the image is rejected or memory runs out; nothing is left allocated
  on failure. }
function ElfLoader_Spawn(image: PByte; size: QWord; runInBackground, isJailed,
  forceRoot: Boolean; name: PWord; priority: Byte): Integer;

implementation

uses arch_hal, pmm, scheduler, libc;

const
  PAGE = 4096;
  EI_CLASS = 4;
  ELFCLASS64 = 2;
  EI_DATA = 5;
  ELFDATA2LSB = 1;
  ET_EXEC = 2;
  PT_LOAD = 1;
  MAX_SEGMENTS = 16;
  MAX_PAGES = 4096;          { 16 MiB per image }

function Rd16(p: PByte): Word;
begin
  Rd16 := Word(p[0]) or (Word(p[1]) shl 8);
end;

function Rd32(p: PByte): Cardinal;
begin
  Rd32 := Cardinal(Rd16(p)) or (Cardinal(Rd16(p + 2)) shl 16);
end;

function Rd64(p: PByte): QWord;
begin
  Rd64 := QWord(Rd32(p)) or (QWord(Rd32(p + 4)) shl 32);
end;

function ElfLoader_Spawn(image: PByte; size: QWord; runInBackground, isJailed,
  forceRoot: Boolean; name: PWord; priority: Byte): Integer;
var
  phoff, phentsize, phnum, entry: QWord;
  i, mapped: Integer;
  ph: PByte;
  ptype: Cardinal;
  off, vaddr, filesz, memsz, va, pageVa, pageEnd, copyFrom, n, total: QWord;
  space: QWord;
  frame: PByte;
  pagesUsed: Cardinal;
  lo, hi: QWord;

  { Return everything allocated so far. }
  procedure Abort;
  begin
    if space <> 0 then Hal_DestroyAddressSpace(space);
  end;

begin
  ElfLoader_Spawn := -1;
  space := 0;
  pagesUsed := 0;
  if (image = nil) or (size < 64) then Exit;
  if (image[0] <> $7F) or (image[1] <> Ord('E')) or (image[2] <> Ord('L')) or
     (image[3] <> Ord('F')) then Exit;
  if (image[EI_CLASS] <> ELFCLASS64) or (image[EI_DATA] <> ELFDATA2LSB) then Exit;
  if (Rd16(image + 16) <> ET_EXEC) or (Rd16(image + 18) <> Hal_ElfMachine) then Exit;

  entry := Rd64(image + 24);
  phoff := Rd64(image + 32);
  phentsize := Rd16(image + 54);
  phnum := Rd16(image + 56);
  if (phentsize < 56) or (phnum = 0) or (phnum > MAX_SEGMENTS) then Exit;
  if (phoff > size) or (phnum * phentsize > size - phoff) then Exit;

  space := Hal_CreateUserAddressSpace;
  if space = 0 then Exit;

  lo := High(QWord);
  hi := 0;
  for i := 0 to Integer(phnum) - 1 do
  begin
    ph := image + phoff + QWord(i) * phentsize;
    ptype := Rd32(ph);
    if ptype <> PT_LOAD then Continue;
    off := Rd64(ph + 8);
    vaddr := Rd64(ph + 16);
    filesz := Rd64(ph + 32);
    memsz := Rd64(ph + 40);

    if (filesz > memsz) or (off > size) or (filesz > size - off) then begin Abort; Exit; end;
    if memsz = 0 then Continue;
    if (vaddr < Hal_UserVaMin) or (memsz > QWord(MAX_PAGES) * PAGE) then begin Abort; Exit; end;
    if vaddr + memsz < vaddr then begin Abort; Exit; end;               { wrap }
    if (not Hal_IsCanonical(vaddr)) or (not Hal_IsCanonical(vaddr + memsz - 1)) then
    begin Abort; Exit; end;

    pageVa := vaddr and not QWord(PAGE - 1);
    pageEnd := (vaddr + memsz + PAGE - 1) and not QWord(PAGE - 1);
    total := (pageEnd - pageVa) div PAGE;
    if pagesUsed + total > MAX_PAGES then begin Abort; Exit; end;

    va := pageVa;
    while va < pageEnd do
    begin
      frame := PByte(Pmm_AllocatePage);       { zero-filled }
      if frame = nil then begin Abort; Exit; end;
      Hal_MapPageIn(QWord(frame), va, HAL_MAP_USER_RW, space);
      Inc(pagesUsed);

      { Bytes of this segment's file data that fall inside this page. }
      if (va + PAGE > vaddr) and (va < vaddr + filesz) then
      begin
        if vaddr > va then copyFrom := vaddr else copyFrom := va;
        n := vaddr + filesz;
        if n > va + PAGE then n := va + PAGE;
        n := n - copyFrom;
        MemCopy(frame + (copyFrom - va), image + off + (copyFrom - vaddr), Cardinal(n));
        Hal_SyncCode(QWord(frame) + (copyFrom - va), n);
      end;
      Inc(va, PAGE);
    end;
    if pageVa < lo then lo := pageVa;
    if pageEnd > hi then hi := pageEnd;
  end;

  if (hi = 0) or (entry < lo) or (entry >= hi) then begin Abort; Exit; end;

  mapped := Sched_CreateUserTask(entry, space, not runInBackground, isJailed, forceRoot,
    name, pagesUsed, priority);
  if mapped < 0 then begin Abort; Exit; end;
  ElfLoader_Spawn := mapped;
end;

end.
