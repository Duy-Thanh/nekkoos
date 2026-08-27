{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: FAT16 - Pure protocol helpers shared between kernel and userland
  PURPOSE: Sector scanning, BPB math, FAT cluster math. No I/O here.
  =========================================================================
}

unit fat16;

{$mode objfpc}
{$h+}
{$inline on}

interface

const
  FAT16_MAX_CLUSTER = $FFEF;
  FAT16_MIN_CLUSTER = $0002;
  FAT16_FREE_CLUSTER = $0000;
  FAT16_BAD_CLUSTER = $FFF7;
  FAT16_EOF_CLUSTER = $FFFF;

function FAT16_CheckSector_Pas(buf: Pointer; formattedName: PByte; outCluster: PWord; outSize: PCardinal; outAttr: PByte; outOwnerUID: PWord; outOwnerGID: PWord; outPerms: PWord): Byte; cdecl; public name 'FAT16_CheckSector_Pas';

function FAT16_ClusterLba_Pas(firstDataSector: Cardinal; cluster: Word; sectorsPerCluster: Byte): Cardinal; cdecl; public name 'FAT16_ClusterLba_Pas';

function FAT16_FatSectorForCluster_Pas(fatStartLba: Cardinal; reservedSectorCount: Word; cluster: Word): Cardinal; cdecl; public name 'FAT16_FatSectorForCluster_Pas';

procedure FAT16_ParseBPB_Pas(bpb: Pointer; outRootDirSectors: PCardinal; outRootDirLba: PCardinal; outFirstDataSector: PCardinal); cdecl; public name 'FAT16_ParseBPB_Pas';

function FAT16_FindFreeCluster_Pas(cluster: Word; fatBuf: Pointer; fatSectorOffset: Cardinal): Word; cdecl; public name 'FAT16_FindFreeCluster_Pas';

function FAT16_IsValidCluster_Pas(cluster: Word): Byte; cdecl; public name 'FAT16_IsValidCluster_Pas';

implementation

function FAT16_CheckSector_Pas(buf: Pointer; formattedName: PByte; outCluster: PWord; outSize: PCardinal; outAttr: PByte; outOwnerUID: PWord; outOwnerGID: PWord; outPerms: PWord): Byte; cdecl;
var
  p: PByte;
  i, j: Integer;
  nameMatch: Integer;
begin
  FAT16_CheckSector_Pas := 0;
  if (buf = nil) or (formattedName = nil) then Exit;

  p := PByte(buf);
  for i := 0 to 15 do
  begin
    if p[0] = 0 then
    begin
      FAT16_CheckSector_Pas := 2;
      Exit;
    end;
    if p[0] = $E5 then
    begin
      Inc(p, 32);
      Continue;
    end;
    if p[0] = $0F then
    begin
      Inc(p, 32);
      Continue;
    end;
    if (p[11] and $08) <> 0 then
    begin
      Inc(p, 32);
      Continue;
    end;

    nameMatch := 1;
    for j := 0 to 10 do
    begin
      if p[j] <> formattedName[j] then
      begin
        nameMatch := 0;
        Break;
      end;
    end;

    if nameMatch <> 0 then
    begin
      FAT16_CheckSector_Pas := 1;
      if outCluster <> nil then
        outCluster^ := PWord(p + 26)[0];
      if outSize <> nil then
        outSize^ := PCardinal(p + 28)[0];
      if outAttr <> nil then
        outAttr^ := p[11];
      if outOwnerUID <> nil then
        outOwnerUID^ := PWord(p + 20)[0];
      if outOwnerGID <> nil then
        outOwnerGID^ := PWord(p + 12)[0];
      if outPerms <> nil then
        outPerms^ := PWord(p + 18)[0];
      Exit;
    end;

    Inc(p, 32);
  end;

  FAT16_CheckSector_Pas := 0;
end;

function FAT16_ClusterLba_Pas(firstDataSector: Cardinal; cluster: Word; sectorsPerCluster: Byte): Cardinal; cdecl;
begin
  FAT16_ClusterLba_Pas := firstDataSector + Cardinal((cluster - 2) * sectorsPerCluster);
end;

function FAT16_FatSectorForCluster_Pas(fatStartLba: Cardinal; reservedSectorCount: Word; cluster: Word): Cardinal; cdecl;
var
  fatOffset: Cardinal;
begin
  fatOffset := Cardinal(cluster) * 2;
  FAT16_FatSectorForCluster_Pas := fatStartLba + reservedSectorCount + (fatOffset div 512);
end;

procedure FAT16_ParseBPB_Pas(bpb: Pointer; outRootDirSectors: PCardinal; outRootDirLba: PCardinal; outFirstDataSector: PCardinal); cdecl;
var
  bytesPerSector: Word;
  sectorsPerCluster: Byte;
  reservedSectorCount: Word;
  numFATs: Byte;
  fatSize16: Word;
  rootEntryCount: Word;
  rootDirSectors: Cardinal;
  fatStartLba: Cardinal;
begin
  if bpb = nil then Exit;

  bytesPerSector := PWord(bpb + 11)[0];
  sectorsPerCluster := PByte(bpb + 13)[0];
  reservedSectorCount := PWord(bpb + 14)[0];
  numFATs := PByte(bpb + 16)[0];
  fatSize16 := PWord(bpb + 22)[0];
  rootEntryCount := PWord(bpb + 17)[0];

  rootDirSectors := ((Cardinal(rootEntryCount) * 32) + bytesPerSector - 1) div bytesPerSector;
  fatStartLba := reservedSectorCount;
  if outRootDirSectors <> nil then
    outRootDirSectors^ := rootDirSectors;
  if outRootDirLba <> nil then
    outRootDirLba^ := fatStartLba + Cardinal(numFATs * fatSize16);
  if outFirstDataSector <> nil then
    outFirstDataSector^ := (outRootDirLba^ + rootDirSectors);
end;

function FAT16_FindFreeCluster_Pas(cluster: Word; fatBuf: Pointer; fatSectorOffset: Cardinal): Word; cdecl;
var
  p: PWord;
  i: Integer;
begin
  FAT16_FindFreeCluster_Pas := 0;
  if fatBuf = nil then Exit;

  p := PWord(fatBuf);
  for i := 0 to 255 do
  begin
    if p[i] = FAT16_FREE_CLUSTER then
    begin
      FAT16_FindFreeCluster_Pas := cluster + Word(i);
      Exit;
    end;
  end;
end;

function FAT16_IsValidCluster_Pas(cluster: Word): Byte; cdecl;
begin
  FAT16_IsValidCluster_Pas := 0;
  if (cluster >= FAT16_MIN_CLUSTER) and (cluster <= FAT16_MAX_CLUSTER) then
    FAT16_IsValidCluster_Pas := 1;
end;

end.
