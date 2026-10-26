{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: acpi_app - Ring-3 ACPI / power-management daemon.
  PORTED FROM: src/apps/acpi.cs (deleted).

  At start it walks the firmware tables the bootloader found (RSDP -> XSDT or
  RSDT -> MADT, FADT, DSDT) and reports what the kernel needs to bring the
  machine up: the local APIC address, the I/O APIC address(es) and the CPU
  count. The kernel blocks until it has them (see kernel_main.pas).

  It then stays resident as the only process allowed to actually power the
  machine off or reset it. The kernel asks over IPC:
      0xDEAD  shut down (ACPI sleep state S5)
      0xBEEF  reboot   (FADT reset register, else 0xCF9, else the 8042)

  Table structures are read at fixed byte offsets rather than through
  records: a record in the interface makes FPC emit RTTI that lld cannot
  resolve (AGENTS.md section 6.3), and the layouts are fixed by the ACPI spec.
  =========================================================================
}
unit acpi_app;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ PE entry point. The loader looks for this symbol by name. }
procedure AppMain; cdecl; public name 'AppMain';

implementation

uses app_api, kstring, acpi_parse;

const
  { RSDP 2.0 (36 bytes). }
  RSDP_REVISION = 15;
  RSDP_RSDT     = 16;
  RSDP_XSDT     = 24;
  RSDP_SIZE     = 36;

  { Common SDT header (36 bytes). }
  SDT_LENGTH = 4;
  SDT_HEADER_SIZE = 36;

  { MADT: header, then LocalApicAddress, Flags, then variable entries. }
  MADT_LOCAL_APIC = 36;
  MADT_ENTRIES    = 44;

  { FADT offsets (packed, ACPI 2.0+). }
  FADT_DSDT       = 40;
  FADT_SMI_CMD    = 48;
  FADT_ACPI_ENABLE = 52;
  FADT_PM1A_CTL   = 64;
  FADT_FLAGS      = 112;
  FADT_RESET_SPACE = 116;
  FADT_RESET_ADDR = 120;
  FADT_RESET_VALUE = 128;
  FADT_X_DSDT     = 140;
  FADT_HAS_RESET_MIN_LEN = 129;
  FADT_HAS_XDSDT_MIN_LEN = 148;

  { FADT flag: the reset register is supported. }
  FADT_FLAG_RESET_REG_SUP = 1 shl 10;

  IPC_SHUTDOWN = $DEAD;
  IPC_REBOOT   = $BEEF;

  { Hardware report types the kernel understands (syscall 13). }
  HW_LOCAL_APIC = 1;
  HW_CORE_COUNT = 2;
  HW_IOAPIC     = 3;

var
  PM1aControlPort: Cardinal = 0;
  SmiCommandPort: Cardinal = 0;
  AcpiEnableCmd: Byte = 0;

  AcpiFlags: Cardinal = 0;
  ResetSpace: Byte = 0;
  ResetAddress: QWord = 0;
  ResetValueData: Byte = 0;

  SlpTypA: Word = 0;
  SlpTypB: Word = 0;
  S5Parsed: Boolean = False;

{ ── Printing ─────────────────────────────────────────────────────────────── }

procedure Say(const msg: AnsiString);
begin
  App_Print(W(msg));
end;

procedure PrintHex(number: QWord);
const
  Digits: array[0..15] of Word = (
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 65, 66, 67, 68, 69, 70);
var
  buf: array[0..18] of Word;
  i: Integer;
begin
  buf[0] := Ord('0');
  buf[1] := Ord('x');
  for i := 0 to 15 do
    buf[2 + i] := Digits[(number shr ((15 - i) * 4)) and $F];
  buf[18] := 0;
  App_Print(@buf[0]);
end;

{ ── Raw table access ─────────────────────────────────────────────────────── }

function Rd8(p: PByte; off: Integer): Byte; inline;
begin
  Rd8 := p[off];
end;

function Rd16(p: PByte; off: Integer): Word; inline;
begin
  Rd16 := PWord(p + off)^;
end;

function Rd32(p: PByte; off: Integer): Cardinal; inline;
begin
  Rd32 := PCardinal(p + off)^;
end;

function Rd64(p: PByte; off: Integer): QWord; inline;
begin
  Rd64 := PQWord(p + off)^;
end;

function SigIs(p: PByte; a, b, c, d: Char): Boolean; inline;
begin
  SigIs := (p[0] = Ord(a)) and (p[1] = Ord(b)) and (p[2] = Ord(c)) and (p[3] = Ord(d));
end;

{ Map a physical range into this process, keeping the page offset so the
  caller gets exactly the address it asked for. Returns 0 on failure. }
function MapAcpi(physAddr: QWord; sizeBytes: Cardinal): QWord;
var
  offset, basePhys, numPages, virtBase: QWord;
begin
  offset := physAddr and $FFF;
  basePhys := physAddr and (not QWord($FFF));
  numPages := (QWord(sizeBytes) + offset + 4095) div 4096;
  virtBase := App_MapPhys(basePhys, numPages);
  if virtBase = 0 then MapAcpi := 0
  else MapAcpi := virtBase + offset;
end;

procedure Fatal(const msg: AnsiString);
begin
  Say(msg);
  App_Exit;
end;

{ ── Table handlers ───────────────────────────────────────────────────────── }

procedure HandleMadt(madt: PByte);
var
  length, cpuCores, ioApicCount: Cardinal;
  ptr, finish: PByte;
  etype, elen: Byte;
begin
  length := Rd32(madt, SDT_LENGTH);
  App_ReportHardware(HW_LOCAL_APIC, Rd32(madt, MADT_LOCAL_APIC), 0);

  Say('[+] MADT Parsed! Local APIC Base: ');
  PrintHex(Rd32(madt, MADT_LOCAL_APIC));
  Say(#10);

  cpuCores := 0;
  ioApicCount := 0;
  ScanMadtEntries_Pas(madt, length, cpuCores, ioApicCount);

  { Report each I/O APIC's address; ScanMadtEntries only counts them. }
  ptr := madt + MADT_ENTRIES;
  finish := madt + length;
  while ptr < finish do
  begin
    etype := ptr[0];
    elen := ptr[1];
    if elen = 0 then Break;
    if etype = 1 then App_ReportHardware(HW_IOAPIC, Rd32(ptr, 4), 0);
    ptr := ptr + elen;
  end;

  App_ReportHardware(HW_CORE_COUNT, cpuCores, 0);
end;

procedure HandleFadt(fadt: PByte);
var
  length: Cardinal;
  dsdtPhys: QWord;
  dsdtHdr, dsdtVirt: QWord;
  dsdtLen: Cardinal;
  dsdt: PByte;
  a, b: Word;
begin
  length := Rd32(fadt, SDT_LENGTH);
  PM1aControlPort := Rd32(fadt, FADT_PM1A_CTL);
  SmiCommandPort := Rd32(fadt, FADT_SMI_CMD);
  AcpiEnableCmd := Rd8(fadt, FADT_ACPI_ENABLE);

  if length >= FADT_HAS_RESET_MIN_LEN then
  begin
    AcpiFlags := Rd32(fadt, FADT_FLAGS);
    ResetSpace := Rd8(fadt, FADT_RESET_SPACE);
    ResetAddress := Rd64(fadt, FADT_RESET_ADDR);
    ResetValueData := Rd8(fadt, FADT_RESET_VALUE);
  end;

  { Both bytes of each register block: the port is 16-bit wide. }
  if PM1aControlPort <> 0 then
  begin
    App_GrantPort(Word(PM1aControlPort));
    App_GrantPort(Word(PM1aControlPort + 1));
  end;
  if SmiCommandPort <> 0 then
  begin
    App_GrantPort(Word(SmiCommandPort));
    App_GrantPort(Word(SmiCommandPort + 1));
  end;

  Say('[+] FADT Parsed! PM1a Port: ');
  PrintHex(PM1aControlPort);
  Say(#10);

  { Prefer the 64-bit X_Dsdt: OVMF places the DSDT above 4 GiB. }
  if (length >= FADT_HAS_XDSDT_MIN_LEN) and (Rd64(fadt, FADT_X_DSDT) <> 0) then
    dsdtPhys := Rd64(fadt, FADT_X_DSDT)
  else
    dsdtPhys := Rd32(fadt, FADT_DSDT);

  if dsdtPhys = 0 then Exit;

  dsdtHdr := MapAcpi(dsdtPhys, SDT_HEADER_SIZE);
  if dsdtHdr = 0 then Exit;
  dsdtLen := Rd32(PByte(dsdtHdr), SDT_LENGTH);

  dsdtVirt := MapAcpi(dsdtPhys, dsdtLen);
  if dsdtVirt = 0 then Exit;
  dsdt := PByte(dsdtVirt);

  if SigIs(dsdt, 'D', 'S', 'D', 'T') then
  begin
    a := 0; b := 0;
    if ParseS5FromDsdt_Pas(dsdt, Rd32(dsdt, SDT_LENGTH), a, b) <> 0 then
    begin
      SlpTypA := a;
      SlpTypB := b;
      S5Parsed := True;
      Say('[+] AML Hack: Found DSDT \_S5_. Dynamic Shutdown Armed!'#10);
    end;
  end;
end;

{ ── Power operations ─────────────────────────────────────────────────────── }

procedure DoShutdown;
var
  timeout, spin: Integer;
  pm1a: Word;
begin
  Say(#10'[!] ACPI Daemon: SHUTDOWN SEQUENCE INITIATED!'#10);

  { Switch the chipset into ACPI mode if firmware has not already. }
  if (SmiCommandPort <> 0) and (AcpiEnableCmd <> 0) then
  begin
    App_OutByte(Word(SmiCommandPort), AcpiEnableCmd);
    timeout := 5000;
    while ((App_InWord(Word(PM1aControlPort)) and 1) = 0) and (timeout > 0) do
    begin
      App_Yield;
      Dec(timeout);
    end;
  end;

  if PM1aControlPort <> 0 then
  begin
    if not S5Parsed then
    begin
      Say('    -> [!] DSDT \_S5_ not found! Overriding with QEMU/VBox S5 Standard (0x1400)...'#10);
      SlpTypA := 5 shl 10;
    end;

    pm1a := App_InWord(Word(PM1aControlPort));
    pm1a := pm1a and $00FF;

    { SLP_EN (bit 13) plus the sleep type. }
    App_OutWord(Word(PM1aControlPort), pm1a or SlpTypA or $2000);

    { QEMU acts on SLP_EN asynchronously; give the VM time to exit before
      concluding it failed. }
    for spin := 0 to 199 do App_Yield;
  end;

  Say('[!!!] ACPI DAEMON SHUTDOWN FAILED! HALTING.'#10);
  while True do App_WaitIPC;
end;

procedure DoReboot;
var
  delay: Integer;
  resetVirt: QWord;
  bus, slot, func, offset, pciAddr: Cardinal;
begin
  Say(#10'[!] ACPI Daemon: REBOOT SEQUENCE INITIATED!'#10);

  if ((AcpiFlags and FADT_FLAG_RESET_REG_SUP) <> 0) and (ResetAddress <> 0) then
  begin
    if ResetSpace = 1 then
    begin
      Say('    -> Routing via System I/O Bus...'#10);
      App_GrantPort(Word(ResetAddress));
      if ResetAddress = $CF9 then
      begin
        { 0xCF9 needs "arm" then "trigger": a single write resets the CPU but
          leaves the 8042 as it was, and the keyboard is dead after reboot. }
        App_OutByte($CF9, $02);
        for delay := 0 to 99999 do begin end;
      end;
      App_OutByte(Word(ResetAddress), ResetValueData);
    end
    else if ResetSpace = 0 then
    begin
      Say('    -> Routing via Memory-Mapped IO...'#10);
      resetVirt := MapAcpi(ResetAddress, 1);
      if resetVirt <> 0 then PByte(resetVirt)^ := ResetValueData;
    end
    else if ResetSpace = 2 then
    begin
      Say('    -> Routing via PCI Configuration Space...'#10);
      bus := 0;
      slot := Cardinal((ResetAddress shr 32) and $FFFF);
      func := Cardinal((ResetAddress shr 16) and $FFFF);
      offset := Cardinal(ResetAddress and $FFFF);

      pciAddr := Cardinal($80000000) or (bus shl 16) or (slot shl 11) or
                 (func shl 8) or (offset and $FC);

      for delay := $CF8 to $CFF do App_GrantPort(Word(delay));

      App_OutDword($CF8, pciAddr);
      App_OutByte(Word($CFC + (offset and 3)), ResetValueData);
    end;
  end
  else
  begin
    Say('    -> [!] FADT lacks Reset Register! Engaging Legacy PCI Reset...'#10);

    App_GrantPort($CF9);
    App_OutByte($CF9, $02);
    for delay := 0 to 99999 do begin end;
    App_OutByte($CF9, $06);

    Say('    -> [!] PCI Reset failed! Engaging PS/2 Keyboard Controller Hard-Reset...'#10);

    App_GrantPort($64);
    while (App_InByte($64) and $02) <> 0 do App_Yield;
    App_OutByte($64, $FE);
  end;

  Say('[!!!] ALL REBOOT METHODS FAILED! HALTING.'#10);
  while True do App_Yield;
end;

{ ── Entry ────────────────────────────────────────────────────────────────── }

procedure AppMain; cdecl;
var
  rsdpPhys, rsdpVirt, sdtPhys, sdtVirtTemp, sdtVirt, entryPhys, tempEntryVirt, entryVirt: QWord;
  useXsdt: Boolean;
  sdtRealLength, entryLen: Cardinal;
  entriesCount, i: Integer;
  entriesPtr, header: PByte;
  msg: array[0..5] of Cardinal;     { 24-byte IPC message: type, sender, receiver, lock, payload(8) }
begin
  AppApi_Init;

  Say(#10'[*] ACPI Daemon (Ring 3): Booting up Power Management Protocol...'#10);

  rsdpPhys := App_GetRsdp;
  if rsdpPhys = 0 then App_Exit;

  rsdpVirt := MapAcpi(rsdpPhys, RSDP_SIZE);
  if rsdpVirt = 0 then Fatal('[!] ACPI FATAL: Failed to map RSDP physical address!'#10);

  useXsdt := (Rd8(PByte(rsdpVirt), RSDP_REVISION) >= 2) and (Rd64(PByte(rsdpVirt), RSDP_XSDT) <> 0);
  if useXsdt then sdtPhys := Rd64(PByte(rsdpVirt), RSDP_XSDT)
  else sdtPhys := Rd32(PByte(rsdpVirt), RSDP_RSDT);

  if sdtPhys = 0 then Fatal('[!] ACPI FATAL: RSDP points to null XSDT/RSDT!'#10);

  { Read the header first for the table's real length. }
  sdtVirtTemp := MapAcpi(sdtPhys, SDT_HEADER_SIZE);
  if sdtVirtTemp = 0 then Fatal('[!] ACPI FATAL: Failed to map SDT header!'#10);

  sdtRealLength := Rd32(PByte(sdtVirtTemp), SDT_LENGTH);
  if (sdtRealLength < SDT_HEADER_SIZE) or (sdtRealLength > $100000) then
    Fatal('[!] ACPI FATAL: SDT length invalid!'#10);

  sdtVirt := MapAcpi(sdtPhys, sdtRealLength);
  if sdtVirt = 0 then Fatal('[!] ACPI FATAL: Failed to map full SDT!'#10);

  { Guard the subtraction: a length below the header would wrap and send the
    loop off the end of the mapping. }
  if sdtRealLength > SDT_HEADER_SIZE then
  begin
    if useXsdt then entriesCount := Integer((sdtRealLength - SDT_HEADER_SIZE) div 8)
    else entriesCount := Integer((sdtRealLength - SDT_HEADER_SIZE) div 4);
  end
  else
    entriesCount := 0;

  if entriesCount > 500 then
    Fatal('[!] ACPI FATAL: XSDT Length seems corrupted! Aborting.'#10);

  entriesPtr := PByte(sdtVirt) + SDT_HEADER_SIZE;

  for i := 0 to entriesCount - 1 do
  begin
    if useXsdt then entryPhys := Rd64(entriesPtr, i * 8)
    else entryPhys := Rd32(entriesPtr, i * 4);
    if entryPhys = 0 then Continue;

    tempEntryVirt := MapAcpi(entryPhys, SDT_HEADER_SIZE);
    if tempEntryVirt = 0 then Continue;
    entryLen := Rd32(PByte(tempEntryVirt), SDT_LENGTH);
    if (entryLen < SDT_HEADER_SIZE) or (entryLen > $10000) then Continue;

    entryVirt := MapAcpi(entryPhys, entryLen);
    if entryVirt = 0 then Continue;
    header := PByte(entryVirt);

    if SigIs(header, 'A', 'P', 'I', 'C') then HandleMadt(header);
    if SigIs(header, 'F', 'A', 'C', 'P') then HandleFadt(header);
    if SigIs(header, 'H', 'P', 'E', 'T') then
      Say('[+] HPET (High Precision Event Timer) Detected!'#10);
    if SigIs(header, 'M', 'C', 'F', 'G') then
      Say('[+] MCFG (PCI Express Config Space) Detected!'#10);
  end;

  Say('[+] ACPI Daemon Armed & Listening for IPC Commands...'#10);

  while True do
  begin
    for i := 0 to 5 do msg[i] := 0;
    if App_ReceiveIPC(@msg) = 1 then
    begin
      if App_MsgType(@msg) = IPC_SHUTDOWN then DoShutdown
      else if App_MsgType(@msg) = IPC_REBOOT then DoReboot;
    end
    else
      App_WaitIPC;
  end;
end;

end.
