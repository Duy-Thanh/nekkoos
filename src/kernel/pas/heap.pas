{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: Heap - Dynamic Memory Allocator (Pascal Implementation)
  PURPOSE: Architecture-independent first-fit linked-list heap allocator
           with block splitting and coalescing. Uses raw pointer arithmetic
           to avoid RTTI generation (no Pascal record types).
  =========================================================================
}

unit heap;

{$mode objfpc}
{$h+}
{$M-}

interface

const
  HEAP_OK = 0;
  HEAP_OOM = 1;
  HEAP_CORRUPTION = 2;
  HEAP_INVALID_PTR = 3;
  HEAP_DOUBLE_FREE = 4;
  HEAP_OVERFLOW = 5;

{ HeapBlock field offsets (C struct layout, 32 bytes total) }
const
  HEAP_BLOCK_SIZE_OFFSET = 0;      { QWord, 8 bytes }
  HEAP_BLOCK_ISFREE_OFFSET = 8;    { Byte, 1 byte }
  HEAP_BLOCK_MAGIC_OFFSET = 12;    { Cardinal, 4 bytes (after 3 padding bytes) }
  HEAP_BLOCK_EXACTSIZE_OFFSET = 16; { QWord, 8 bytes }
  HEAP_BLOCK_NEXT_OFFSET = 24;     { Pointer, 8 bytes }
  HEAP_BLOCK_SIZE = 32;            { Total struct size }

procedure Heap_SetState(aHead: Pointer; aHeapStart: Pointer; aHeapTotalSize: QWord); cdecl; public name 'Heap_SetState_Pas';
function Heap_AllocBlock(size: Cardinal; out userRam: Pointer): Byte; cdecl; public name 'Heap_AllocBlock_Pas';
function Heap_FreeBlock(ptr: Pointer): Byte; cdecl; public name 'Heap_FreeBlock_Pas';

implementation

const
  HEAP_MAGIC = $DEADBEEF;

var
  Head: Pointer = nil;
  HeapStart: Pointer = nil;
  HeapTotalSize: QWord = 0;

procedure Arch_CompilerFence; cdecl; external name 'Arch_CompilerFence';
procedure Arch_StoreFence; cdecl; external name 'Arch_StoreFence';
procedure MemSet_Pas(dest: PByte; val: Byte; count: Cardinal); cdecl; external name 'MemSet_Pas';

{ Helper: read QWord at block + offset }
function GetBlockQWord(block: Pointer; offset: Integer): QWord; inline;
begin
  GetBlockQWord := PQWord(PByte(block) + offset)^;
end;

{ Helper: write QWord at block + offset }
procedure SetBlockQWord(block: Pointer; offset: Integer; value: QWord); inline;
begin
  PQWord(PByte(block) + offset)^ := value;
end;

{ Helper: read Byte at block + offset }
function GetBlockByte(block: Pointer; offset: Integer): Byte; inline;
begin
  GetBlockByte := PByte(PByte(block) + offset)^;
end;

{ Helper: write Byte at block + offset }
procedure SetBlockByte(block: Pointer; offset: Integer; value: Byte); inline;
begin
  PByte(PByte(block) + offset)^ := value;
end;

{ Helper: read Cardinal at block + offset }
function GetBlockCardinal(block: Pointer; offset: Integer): Cardinal; inline;
begin
  GetBlockCardinal := PCardinal(PByte(block) + offset)^;
end;

{ Helper: write Cardinal at block + offset }
procedure SetBlockCardinal(block: Pointer; offset: Integer; value: Cardinal); inline;
begin
  PCardinal(PByte(block) + offset)^ := value;
end;

{ Helper: read Pointer at block + offset }
function GetBlockPointer(block: Pointer; offset: Integer): Pointer; inline;
begin
  GetBlockPointer := PPointer(PByte(block) + offset)^;
end;

{ Helper: write Pointer at block + offset }
procedure SetBlockPointer(block: Pointer; offset: Integer; value: Pointer); inline;
begin
  PPointer(PByte(block) + offset)^ := value;
end;

procedure Heap_SetState(aHead: Pointer; aHeapStart: Pointer; aHeapTotalSize: QWord); cdecl;
begin
  Head := aHead;
  HeapStart := aHeapStart;
  HeapTotalSize := aHeapTotalSize;
end;

function Heap_AllocBlock(size: Cardinal; out userRam: Pointer): Byte; cdecl;
var
  current: Pointer;
  requiredSize, remainder, blockSize, newBlockSize: QWord;
  isFree: Byte;
  magic: Cardinal;
  newBlock: Pointer;
  newBlockAddr: QWord;
  canaryPtr: PCardinal;
begin
  Heap_AllocBlock := HEAP_OOM;
  userRam := nil;

  if size = 0 then Exit;
  if QWord(size) >= HeapTotalSize then Exit;
  if size > $100000 then Exit;

  requiredSize := QWord(size) + 4;
  remainder := requiredSize mod 8;
  if remainder <> 0 then
    requiredSize := requiredSize + (8 - remainder);

  current := Head;
  while current <> nil do
  begin
    Arch_CompilerFence();

    magic := GetBlockCardinal(current, HEAP_BLOCK_MAGIC_OFFSET);
    if magic <> HEAP_MAGIC then
    begin
      Heap_AllocBlock := HEAP_CORRUPTION;
      Exit;
    end;

    isFree := GetBlockByte(current, HEAP_BLOCK_ISFREE_OFFSET);
    blockSize := GetBlockQWord(current, HEAP_BLOCK_SIZE_OFFSET);

    if (isFree = 1) and (blockSize >= requiredSize) then
    begin
      newBlockAddr := QWord(current) + HEAP_BLOCK_SIZE + requiredSize;
      if newBlockAddr + HEAP_BLOCK_SIZE > QWord(HeapStart) + HeapTotalSize then
      begin
        current := GetBlockPointer(current, HEAP_BLOCK_NEXT_OFFSET);
        continue;
      end;

      if blockSize > requiredSize + HEAP_BLOCK_SIZE + 8 then
      begin
        newBlock := Pointer(PByte(current) + HEAP_BLOCK_SIZE + requiredSize);
        newBlockSize := blockSize - requiredSize - HEAP_BLOCK_SIZE;

        SetBlockQWord(newBlock, HEAP_BLOCK_SIZE_OFFSET, newBlockSize);
        SetBlockByte(newBlock, HEAP_BLOCK_ISFREE_OFFSET, 1);
        SetBlockCardinal(newBlock, HEAP_BLOCK_MAGIC_OFFSET, HEAP_MAGIC);
        SetBlockQWord(newBlock, HEAP_BLOCK_EXACTSIZE_OFFSET, 0);
        SetBlockPointer(newBlock, HEAP_BLOCK_NEXT_OFFSET, GetBlockPointer(current, HEAP_BLOCK_NEXT_OFFSET));

        Arch_CompilerFence();

        SetBlockQWord(current, HEAP_BLOCK_SIZE_OFFSET, requiredSize);
        SetBlockPointer(current, HEAP_BLOCK_NEXT_OFFSET, newBlock);

        Arch_StoreFence();
      end;

      SetBlockByte(current, HEAP_BLOCK_ISFREE_OFFSET, 0);
      SetBlockQWord(current, HEAP_BLOCK_EXACTSIZE_OFFSET, size);

      userRam := Pointer(PByte(current) + HEAP_BLOCK_SIZE);
      MemSet_Pas(PByte(userRam), 0, size);

      canaryPtr := PCardinal(PByte(userRam) + size);
      canaryPtr^ := HEAP_MAGIC;

      Arch_StoreFence();

      Heap_AllocBlock := HEAP_OK;
      Exit;
    end;

    current := GetBlockPointer(current, HEAP_BLOCK_NEXT_OFFSET);
  end;
end;

function Heap_FreeBlock(ptr: Pointer): Byte; cdecl;
var
  block, current, nextBlock: Pointer;
  tailCanary, magic: Cardinal;
  isFree, nextIsFree: Byte;
  exactSize, blockSize, nextSize, newSize: QWord;
begin
  Heap_FreeBlock := HEAP_INVALID_PTR;

  if ptr = nil then
  begin
    Heap_FreeBlock := HEAP_OK;
    Exit;
  end;

  if (QWord(ptr) and $7) <> 0 then Exit;

  if (PByte(ptr) < PByte(HeapStart) + HEAP_BLOCK_SIZE) or
     (PByte(ptr) >= PByte(HeapStart) + HeapTotalSize - HEAP_BLOCK_SIZE - 4) then
    Exit;

  block := Pointer(PByte(ptr) - HEAP_BLOCK_SIZE);

  magic := GetBlockCardinal(block, HEAP_BLOCK_MAGIC_OFFSET);
  if magic <> HEAP_MAGIC then
  begin
    Heap_FreeBlock := HEAP_CORRUPTION;
    Exit;
  end;

  isFree := GetBlockByte(block, HEAP_BLOCK_ISFREE_OFFSET);
  if isFree = 1 then
  begin
    Heap_FreeBlock := HEAP_DOUBLE_FREE;
    Exit;
  end;

  exactSize := GetBlockQWord(block, HEAP_BLOCK_EXACTSIZE_OFFSET);
  tailCanary := PCardinal(PByte(ptr) + exactSize)^;
  if tailCanary <> HEAP_MAGIC then
  begin
    Heap_FreeBlock := HEAP_OVERFLOW;
    Exit;
  end;

  SetBlockByte(block, HEAP_BLOCK_ISFREE_OFFSET, 1);
  Arch_StoreFence();

  current := Head;
  while current <> nil do
  begin
    Arch_CompilerFence();

    magic := GetBlockCardinal(current, HEAP_BLOCK_MAGIC_OFFSET);
    if magic <> HEAP_MAGIC then
    begin
      Heap_FreeBlock := HEAP_CORRUPTION;
      Exit;
    end;

    isFree := GetBlockByte(current, HEAP_BLOCK_ISFREE_OFFSET);
    nextBlock := GetBlockPointer(current, HEAP_BLOCK_NEXT_OFFSET);

    if (isFree = 1) and (nextBlock <> nil) then
    begin
      nextIsFree := GetBlockByte(nextBlock, HEAP_BLOCK_ISFREE_OFFSET);
      if nextIsFree = 1 then
      begin
        magic := GetBlockCardinal(nextBlock, HEAP_BLOCK_MAGIC_OFFSET);
        if magic <> HEAP_MAGIC then
        begin
          Heap_FreeBlock := HEAP_CORRUPTION;
          Exit;
        end;

        blockSize := GetBlockQWord(current, HEAP_BLOCK_SIZE_OFFSET);
        nextSize := GetBlockQWord(nextBlock, HEAP_BLOCK_SIZE_OFFSET);
        newSize := blockSize + nextSize + HEAP_BLOCK_SIZE;

        if newSize > HeapTotalSize then
        begin
          current := nextBlock;
          continue;
        end;

        SetBlockQWord(current, HEAP_BLOCK_SIZE_OFFSET, newSize);
        SetBlockPointer(current, HEAP_BLOCK_NEXT_OFFSET, GetBlockPointer(nextBlock, HEAP_BLOCK_NEXT_OFFSET));

        Arch_StoreFence();
      end
      else
        current := nextBlock;
    end
    else
      current := nextBlock;
  end;

  Heap_FreeBlock := HEAP_OK;
end;

end.
