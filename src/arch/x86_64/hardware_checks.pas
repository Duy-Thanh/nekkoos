{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: hardware_checks - boot-time platform authenticity gate.
  PORTED FROM: src/arch/x86_64/HardwareChecks.cs.

  x86_64 ONLY (fw_cfg ports 0x510/0x511, 8042 polling, APIC IPI).

  The platform has to present a key through the QEMU fw_cfg interface
  (entry "opt/nekko_key"). Without it the machine is frozen behind a screen
  that asks for the key by hand; the right answer resumes boot, the wrong one
  halts. Both the key and every screen message are stored XOR-obfuscated so
  neither shows up in `strings` of the image.
  =========================================================================
}
unit hardware_checks;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

procedure HwChecks_CheckHardwareError;

implementation

uses arch_interface, io, kstring, console, terminal, apic, input_drv, scheduler;

const
  C_ENCKEY: array[0..20] of Byte = (
    $EE, $FF, $F3, $F5, $FE, $E2, $EB, $E4, $E2, $F5, $E3, $F9,
    $F5, $FE, $E2, $EF, $F5, $E1, $E3, $E4, $ED
  );

  C_ENCFWNAME: array[0..12] of Byte = (
    $C5, $DA, $DE, $85, $C4, $CF, $C1, $C1, $C5, $F5, $C1, $CF,
    $D3
  );

  MSG_M1: array[0..9] of Byte = (
    $0D, $1E, $2B, $24, $31, $42, $5F, $68, $65, $76
  );

  MSG_M2: array[0..54] of Byte = (
    $27, $34, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $C4, $D1, $DE, $2B, $38, $05, $12,
    $77, $0D, $0B, $22, $24, $C1, $DF, $DF, $87, $F9, $8E, $8A,
    $92, $AE, $BC, $41, $4E, $48, $60, $79, $0D, $70, $19, $2F,
    $23, $C1, $D2, $CA, $EE, $FC, $CF
  );

  MSG_M3: array[0..54] of Byte = (
    $27, $34, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $C4, $D1, $DE, $2B, $38, $05, $12,
    $1F, $61, $74, $4B, $5E, $AD, $A0, $B7, $8A, $99, $EC, $E3,
    $F6, $C5, $D8, $2F, $22, $31, $04, $1B, $6E, $7D, $70, $47,
    $5A, $A9, $BC, $B3, $86, $B2, $CF
  );

  MSG_M4: array[0..61] of Byte = (
    $27, $34, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $C4, $B8, $AA, $2B, $51, $76, $12,
    $7E, $6C, $1F, $23, $37, $C5, $DF, $DB, $EB, $94, $82, $9C,
    $92, $A5, $B0, $22, $5B, $53, $09, $75, $0C, $00, $04, $4A,
    $23, $CC, $D8, $CD, $8B, $EB, $8A, $94, $8B, $BB, $B8, $54,
    $56, $2A
  );

  MSG_M5: array[0..63] of Byte = (
    $27, $34, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $B0, $B9, $BB, $2B, $4B, $7C, $61,
    $6B, $09, $14, $46, $3B, $C1, $DE, $BA, $E3, $F1, $95, $8B,
    $98, $BC, $B0, $46, $2F, $49, $67, $77, $16, $04, $15, $25,
    $25, $CD, $CB, $DB, $EF, $98, $8D, $93, $8D, $A8, $AE, $47,
    $41, $65, $27, $30
  );

  MSG_M6: array[0..47] of Byte = (
    $27, $34, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $C4, $D1, $DE, $44, $4A, $6C, $75,
    $76, $02, $18, $2A, $53, $C1, $D8, $CE, $EF, $FB, $93, $EE,
    $E1, $C8, $B1, $57, $56, $3C, $7D, $7E, $02, $1E, $15, $60
  );

  MSG_M7: array[0..52] of Byte = (
    $27, $34, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $C4, $D1, $DE, $47, $51, $66, $77,
    $71, $1F, $1C, $46, $20, $D4, $CC, $CE, $F2, $E7, $E1, $EE,
    $E1, $C8, $A0, $4C, $4E, $49, $7D, $7E, $0C, $02, $14, $30,
    $32, $C0, $9B, $94, $A1
  );

  MSG_M8: array[0..62] of Byte = (
    $27, $34, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $B4, $BD, $BB, $4A, $4B, $60, $12,
    $6B, $19, $0B, $28, $53, $CF, $CB, $DC, $87, $E4, $8E, $99,
    $9E, $BA, $D5, $4B, $42, $51, $6C, $72, $0A, $11, $09, $2F,
    $3B, $DD, $B1, $DF, $E5, $FC, $E5, $91, $90, $A2, $AD, $47,
    $50, $74, $27
  );

  MSG_M9: array[0..51] of Byte = (
    $27, $34, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $C4, $D1, $DE, $2B, $38, $05, $12,
    $1F, $6C, $79, $46, $53, $D4, $C5, $DF, $87, $F5, $94, $9A,
    $93, $A7, $A7, $22, $49, $53, $7B, $16, $02, $13, $1E, $2F,
    $24, $D7, $9B, $94
  );

  MSG_M12: array[0..35] of Byte = (
    $27, $34, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $DA, $D1, $BB, $45, $4C, $60, $60,
    $1F, $01, $16, $22, $36, $CC, $AD, $D1, $E2, $ED, $FB, $EE
  );

  MSG_MOK: array[0..45] of Byte = (
    $0D, $1E, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $C4, $D1, $DE, $2B, $38, $05, $12,
    $1F, $6C, $79, $46, $53, $A0, $AD, $BA, $87, $94, $E1, $EE,
    $9A, $AB, $B6, $47, $5F, $48, $6C, $72, $62, $5A
  );

  MSG_M_ENC: array[0..56] of Byte = (
    $0D, $1E, $01, $0E, $1B, $68, $75, $42, $4F, $5C, $A9, $B6,
    $83, $90, $9D, $EA, $F7, $C4, $D1, $DE, $2B, $38, $05, $12,
    $1F, $6C, $79, $27, $30, $C3, $C8, $C9, $F4, $94, $85, $8B,
    $95, $A1, $B0, $46, $2E, $3C, $7A, $6F, $10, $04, $18, $27,
    $57, $CC, $D0, $D2, $FF, $FD, $81, $FC, $D5
  );


  KEY_LEN = 21;
  FW_NAME_LEN = 13;
  FW_ENTRY_NAME_BYTES = 56;
  FW_MAX_ENTRIES = 1000;

var
  { Calibrated TSC offset slot, kept for the layout the C# class exposed. }
  HardwareTscOffset: QWord = 0;

procedure ClsFence; inline;
begin
  Arch_CompilerFence;
end;

{ fw_cfg: scan the file directory (selector 0x19) for an entry by name and
  return its selector, or 0. }
function GetFwCfgSelector(name: PWord; nameLen: Integer): Word;
var
  count, size, i: Cardinal;
  select, reserved: Word;
  j: Integer;
  b: Byte;
  expected: Word;
  nameMatch: Boolean;
begin
  GetFwCfgSelector := 0;
  if name = nil then
  begin
    Con_SetColor($00FF0000);
    Con_Print(W('[!] FATAL: Null pointer in GetFwCfgSelector!'#13#10));
    Exit;
  end;
  if (nameLen < 0) or (nameLen > FW_ENTRY_NAME_BYTES) then
  begin
    Con_SetColor($00FF0000);
    Con_Print(W('[!] FATAL: Invalid name length in GetFwCfgSelector!'#13#10));
    Exit;
  end;

  Io_Out16($510, $19);
  count := (Cardinal(Io_In8($511)) shl 24) or (Cardinal(Io_In8($511)) shl 16) or
           (Cardinal(Io_In8($511)) shl 8) or Cardinal(Io_In8($511));

  if count > FW_MAX_ENTRIES then
  begin
    Con_SetColor($00FF0000);
    Con_Print(W('[!] FATAL: Too many entries in GetFwCfgSelector!'#13#10));
    Exit;
  end;

  i := 0;
  while i < count do
  begin
    size := (Cardinal(Io_In8($511)) shl 24) or (Cardinal(Io_In8($511)) shl 16) or
            (Cardinal(Io_In8($511)) shl 8) or Cardinal(Io_In8($511));
    select := Word((Word(Io_In8($511)) shl 8) or Io_In8($511));
    reserved := Word((Word(Io_In8($511)) shl 8) or Io_In8($511));

    nameMatch := True;
    for j := 0 to FW_ENTRY_NAME_BYTES - 1 do
    begin
      b := Io_In8($511);
      if j < nameLen then expected := name[j] else expected := 0;
      if b <> expected then nameMatch := False;
    end;
    if nameMatch then
    begin
      GetFwCfgSelector := select;
      Exit;
    end;
    Inc(i);
  end;
end;

procedure PrintObf(const msg: array of Byte);
begin
  Terminal_PrintObfuscated_Pas(@msg[0], Length(msg));
end;

procedure HwChecks_CheckHardwareError;
var
  secretKey: array[0..KEY_LEN] of Word;
  fwName: array[0..FW_NAME_LEN] of Word;
  inputBuffer: array[0..63] of Word;
  inputLen, i, k, delay: Integer;
  isGenuine, isCorrect, match: Boolean;
  keySelector: Word;
  b: Byte;
  scanCode: Byte;
  c: Word;
begin
  HardwareTscOffset := 0;
  isGenuine := False;

  for i := 0 to KEY_LEN - 1 do secretKey[i] := Word(C_ENCKEY[i] xor $AA);
  secretKey[KEY_LEN] := 0;
  for i := 0 to FW_NAME_LEN - 1 do fwName[i] := Word(C_ENCFWNAME[i] xor $AA);
  fwName[FW_NAME_LEN] := 0;

  keySelector := GetFwCfgSelector(@fwName[0], FW_NAME_LEN);

  if keySelector <> 0 then
  begin
    Io_Out16($510, keySelector);
    match := True;
    for i := 0 to KEY_LEN - 1 do
    begin
      b := Io_In8($511);
      if b <> Byte(secretKey[i]) then
      begin
        match := False;
        Break;
      end;
    end;
    if match then isGenuine := True;
  end;

  if isGenuine then Exit;

  { Not genuine: freeze the other cores, stop scheduling, ask for the key. }
  if Apic_IsAwake then Apic_Write($300, $000C4400);

  Sched_SetReady(False);
  Io_Cli;

  Con_Clear($00000000);

  PrintObf(MSG_M1);

  Terminal_SetColor_Pas($00FFFFFF);
  PrintObf(MSG_M2);
  PrintObf(MSG_M3);

  PrintObf(MSG_M4);
  PrintObf(MSG_M5);

  PrintObf(MSG_M6);
  PrintObf(MSG_M7);

  Terminal_SetColor_Pas($00FF0000);
  PrintObf(MSG_M8);
  PrintObf(MSG_M9);

  Terminal_SetColor_Pas($00FFFFFF);
  PrintObf(MSG_M12);

  inputLen := 0;

  while True do
  begin
    { Poll the 8042; the fence stops the compiler caching the status read. }
    while (Io_In8($64) and 1) = 0 do ClsFence;

    scanCode := Io_In8($60);
    c := Kbd_ProcessScanCode(scanCode);

    if c = 0 then Continue;

    if (c = 10) or (c = 13) then
    begin
      inputBuffer[inputLen] := 0;

      isCorrect := True;
      if inputLen <> KEY_LEN then isCorrect := False
      else
        for k := 0 to KEY_LEN - 1 do
          if inputBuffer[k] <> secretKey[k] then
          begin
            isCorrect := False;
            Break;
          end;

      if isCorrect then
      begin
        Terminal_SetColor_Pas($0000FF00);
        PrintObf(MSG_MOK);

        for delay := 0 to 999999 do
        begin
          ClsFence;
          Io_In8($80);
        end;

        Con_Clear($00111111);
        Terminal_SetColor_Pas($00FFFFFF);

        Sched_SetReady(True);
        Io_Sti;

        if Apic_IsAwake then Apic_Write($300, $000C4500);
        Exit;
      end
      else
      begin
        Terminal_SetColor_Pas($00FF0000);
        PrintObf(MSG_M_ENC);
        Io_Cli;
        while True do Io_Hlt;
      end;
    end
    else if (c = 8) and (inputLen > 0) then
    begin
      Dec(inputLen);
      Con_Print(W(#8' '#8));
    end
    else if (c >= 32) and (c <= 126) and (inputLen < 63) then
    begin
      inputBuffer[inputLen] := c;
      Inc(inputLen);
      Con_Print(W('*'));
    end;
  end;
end;

procedure HwChecks_CheckHardwareError_Pas; cdecl; public name 'HwChecks_CheckHardwareError_Pas';
begin
  HwChecks_CheckHardwareError;
end;

end.
