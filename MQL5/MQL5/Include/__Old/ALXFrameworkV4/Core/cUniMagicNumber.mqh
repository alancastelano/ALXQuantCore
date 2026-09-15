//+------------------------------------------------------------------+
//|                                               UniMagicNumber.mqh |
//|                                           Copyright 2017, Progid |
//|                             https://www.mql5.com/ru/users/progid |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| 
//| This class helps to get unique magic number, using:
//| 1) Symbol name;
//| 2) TF;
//| 3) Prefix number (need to that you could get several unique magic numbers for the same chart);
//| 
//| The magic number has a size of 64 bits, type is ulong.
//| [64 bits] = [Symbol name(48 bits, first 8 characters)] + [tf(5 bits)] + [prefix number(11 bits, can be from 0 to 2047)].
//| 
//+------------------------------------------------------------------+
class cUniMagicNumber
{
public:
   static ulong   GetMagicNumber(ushort prefix,//Prefix number (need to that you could get several unique magic numbers for the same chart)
                                 string symbol,//Symbol name
                                 ENUM_TIMEFRAMES tf);//Timeframe
            
private:
   static uchar   GetSymbolCode(ushort code);
   static uchar   GetTFCode(ENUM_TIMEFRAMES tf);
   static void    FromByte(uchar val,bool & bits[],int bits_count=8);
   static void    FromUshort(ushort val,bool & bits[],int bits_count=16);
   static ulong   ToUlong(bool & bits[],int bits_count=64);
};


//+------------------------------------------------------------------+ 
//| Symbol(first 8 characters) + TF     + Prefix[0,2047]
//| 48 bits                      5 bits   11 bits
//+------------------------------------------------------------------+
ulong cUniMagicNumber::GetMagicNumber (ushort prefix,//prefix number [0,2047]
                                       string symbol,//symbol name
                                       ENUM_TIMEFRAMES tf)//timeframe
{
   ulong Res = 0;
   
   bool Bits16[16]; ArrayInitialize(Bits16, false);
   bool Bits64[64]; ArrayInitialize(Bits64, false);
   
   int BitsCount = 0;
      
//---Symbol[48 bits]
   if (!StringToLower(symbol)) 
      return 0;
   
   ushort SymbolCodesShort[];
   
   StringToShortArray(symbol, SymbolCodesShort);

   const int CodesCount = fmin(8, ArraySize(SymbolCodesShort));
   
   for (int i=0; i<CodesCount; ++i)
   {
      uchar ActUchar = GetSymbolCode(SymbolCodesShort[i]);
      
      FromByte(ActUchar, Bits16, 6);
      
      ArrayCopy(Bits64, Bits16, BitsCount);
      
      BitsCount += 6;
   }
   
   BitsCount = 11 + 48;
   
//---TF[5 bits]
   FromByte(GetTFCode(tf), Bits16, 5);
   
   ArrayCopy(Bits64, Bits16, BitsCount);
   
   BitsCount += 5;
   
//---Symbol + TF
   Res = ToUlong(Bits64, 64);
   
//---Symbol + TF + prefix
   prefix = fmin(fmax(prefix, (ushort)0), (ushort)2047);
      
   Res += prefix;
   
   return Res;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
uchar cUniMagicNumber::GetSymbolCode(ushort code)
{
   //a-z (1-26)
   if (code >= 97 && code <= 122)
      return uchar(1 + code-97);

   //0-9 (27-36)
   if (code >= 48 && code <= 57)
      return uchar(27 + code-48);

   //(37-63)
   switch (code)
   {
      case ' ': return 37;
      case '#': return 38;
      case '.': return 39;
      case '-': return 40;
      case '_': return 41;
      case '=': return 42;
      case '+': return 43;
      case '/': return 44;
      case '[': return 45;
      case ']': return 46;
      case '<': return 47;
      case '>': return 48;
      case '{': return 49;
      case '}': return 50;
      case ',': return 51;
      case '*': return 52;
      case '&': return 53;
      case '^': return 54;
      case '%': return 55;
      case '$': return 56;
      case '@': return 57;
      case '!': return 58;
      case '~': return 59;
      case '|': return 60;
      case '\\':return 61;
      case ';': return 62;
      case ':': return 63;
      
      default: break;
   }
   
   return 0;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
uchar cUniMagicNumber::GetTFCode(ENUM_TIMEFRAMES tf)
{
   uchar TfIndex = 0;
   
   switch(tf)
   {
      case PERIOD_CURRENT: break;
      
      case PERIOD_M1:  TfIndex = 1; break;
      case PERIOD_M2:  TfIndex = 2; break;
      case PERIOD_M3:  TfIndex = 3; break;
      case PERIOD_M4:  TfIndex = 4; break;
      case PERIOD_M5:  TfIndex = 5; break;
      case PERIOD_M6:  TfIndex = 6; break;
      case PERIOD_M10: TfIndex = 7; break;
      case PERIOD_M12: TfIndex = 8; break;
      case PERIOD_M15: TfIndex = 9; break;
      case PERIOD_M20: TfIndex = 10; break;
      case PERIOD_M30: TfIndex = 11; break;
      case PERIOD_H1:  TfIndex = 12; break;
      case PERIOD_H2:  TfIndex = 13; break;
      case PERIOD_H3:  TfIndex = 14; break;
      case PERIOD_H4:  TfIndex = 15; break;
      case PERIOD_H6:  TfIndex = 16; break;
      case PERIOD_H8:  TfIndex = 17; break;
      case PERIOD_H12: TfIndex = 18; break;
      case PERIOD_D1:  TfIndex = 19; break;
      case PERIOD_W1:  TfIndex = 20; break;
      case PERIOD_MN1: TfIndex = 21; break;
      
      default: break;
   }
   
   return TfIndex;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void cUniMagicNumber::FromByte(uchar val,bool & bits[],int bits_count=8)
{
   for (uchar i=0; i<bits_count; ++i) 
      bits[i] = (val & ((uchar)1<<i)) != 0;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void cUniMagicNumber::FromUshort(ushort val,bool & bits[],int bits_count=16)
{
   for (ushort i=0; i<bits_count; ++i) 
      bits[i] = (val & ((ushort)1<<i)) != 0;
}
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
ulong cUniMagicNumber::ToUlong(bool & bits[],int bits_count=64)
{
   ulong Res = 0;
   
   for (ulong i=0; i<(ulong)bits_count; ++i) 
      if (bits[(uint)i]) 
         Res |= (ulong)1 << i;
   
   return Res;
}