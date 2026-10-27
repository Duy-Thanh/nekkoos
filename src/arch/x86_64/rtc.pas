unit rtc;

{ NekkoOS RTC/CMOS Reader (Pascal Port)

  Reads real-time clock values from x86 CMOS registers.
  Ported from src/RTC.cs. }

{$MODE FPC}
{$ASMMODE Intel}
{$M-}

interface

procedure RTC_PrintCurrentTime; cdecl; public name 'RTC_PrintCurrentTime_Pas';
function  RTC_GetSeconds: QWord; cdecl; public name 'RTC_GetSeconds_Pas';

implementation

uses
  terminal;

{ AAL Layer 1 Port I/O primitives }
procedure Arch_WritePort8(port: Word; value: Byte); cdecl; external name 'Arch_WritePort8';
function  Arch_ReadPort8(port: Word): Byte; cdecl; external name 'Arch_ReadPort8';

function GetRTCRegister(reg: Integer): Byte; inline;
begin
  { Send address (Set bit 7 = 0x80 to disable NMI during read) }
  Arch_WritePort8($70, Byte(reg or $80));
  GetRTCRegister := Arch_ReadPort8($71);
end;

function BCDToBinary(bcd: Byte): QWord; inline;
begin
  BCDToBinary := QWord((bcd and $0F) + ((bcd div 16) * 10));
end;

procedure RTC_PrintCurrentTime; cdecl;
const
  MSG_CMOS: array[0..24] of Word = (
    Ord('['), Ord('*'), Ord(']'), Ord(' '), Ord('H'), Ord('a'), Ord('r'), Ord('d'), Ord('w'), Ord('a'), Ord('r'), Ord('e'),
    Ord(' '), Ord('C'), Ord('M'), Ord('O'), Ord('S'), Ord(' '), Ord('T'), Ord('i'), Ord('m'), Ord('e'), Ord(':'), Ord(' '), 0
  );
  CHAR_ZERO: array[0..1] of Word = (Ord('0'), 0);
  SEP_SLASH: array[0..1] of Word = (Ord('/'), 0);
  SEP_SPACE: array[0..2] of Word = (Ord(' '), Ord(' '), 0);
  SEP_COLON: array[0..1] of Word = (Ord(':'), 0);
  CHAR_NL:   array[0..1] of Word = (10, 0);
var
  secTho, minTho, hourTho: Byte;
  dayTho, monthTho, yearTho: Byte;
  registerB: Byte;
  isBinary, is24Hour: Boolean;
  sec, min, hour, day, month, year: QWord;
begin
  { 1. Wait for RTC update to finish }
  while (GetRTCRegister($0A) and $80) <> 0 do ;

  { 2. Read raw registers }
  secTho   := GetRTCRegister($00);
  minTho   := GetRTCRegister($02);
  hourTho  := GetRTCRegister($04);
  dayTho   := GetRTCRegister($07);
  monthTho := GetRTCRegister($08);
  yearTho  := GetRTCRegister($09);

  { 3. Check Register B for formats }
  registerB := GetRTCRegister($0B);
  isBinary  := (registerB and $04) <> 0;
  is24Hour  := (registerB and $02) <> 0;

  { 4. Decode formats }
  if isBinary then
  begin
    sec   := secTho;
    min   := minTho;
    hour  := hourTho;
    day   := dayTho;
    month := monthTho;
    year  := yearTho;
  end
  else
  begin
    sec   := BCDToBinary(secTho);
    min   := BCDToBinary(minTho);
    hour  := BCDToBinary(Byte(hourTho and $7F));
    day   := BCDToBinary(dayTho);
    month := BCDToBinary(monthTho);
    year  := BCDToBinary(yearTho);
  end;

  { Convert 12h to 24h if necessary }
  if (not is24Hour) and ((hourTho and $80) <> 0) then
  begin
    hour := (hour + 12) mod 24;
  end;

  year := year + 2000;
  hour := (hour + 7) mod 24; { GMT+7 }

  { Print using terminal unit }
  Terminal_SetColor_Pas($00FFFF00);
  Terminal_Print_Pas(@MSG_CMOS[0]);

  if day < 10 then Terminal_Print_Pas(@CHAR_ZERO[0]);
  Terminal_PrintDec_Pas(day);
  Terminal_Print_Pas(@SEP_SLASH[0]);

  if month < 10 then Terminal_Print_Pas(@CHAR_ZERO[0]);
  Terminal_PrintDec_Pas(month);
  Terminal_Print_Pas(@SEP_SLASH[0]);

  Terminal_PrintDec_Pas(year);
  Terminal_Print_Pas(@SEP_SPACE[0]);

  if hour < 10 then Terminal_Print_Pas(@CHAR_ZERO[0]);
  Terminal_PrintDec_Pas(hour);
  Terminal_Print_Pas(@SEP_COLON[0]);

  if min < 10 then Terminal_Print_Pas(@CHAR_ZERO[0]);
  Terminal_PrintDec_Pas(min);
  Terminal_Print_Pas(@SEP_COLON[0]);

  if sec < 10 then Terminal_Print_Pas(@CHAR_ZERO[0]);
  Terminal_PrintDec_Pas(sec);
  Terminal_Print_Pas(@CHAR_NL[0]);

  Terminal_SetColor_Pas($00FFFFFF);
end;

function RTC_GetSeconds: QWord; cdecl;
var
  secTho, registerB: Byte;
  isBinary: Boolean;
begin
  while (GetRTCRegister($0A) and $80) <> 0 do ;

  secTho    := GetRTCRegister($00);
  registerB := GetRTCRegister($0B);
  isBinary  := (registerB and $04) <> 0;

  if isBinary then
    RTC_GetSeconds := secTho
  else
    RTC_GetSeconds := BCDToBinary(secTho);
end;

end.
