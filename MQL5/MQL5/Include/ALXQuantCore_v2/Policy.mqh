//+------------------------------------------------------------------+
//|                                                     Policy.mqh   |
//|                                                     ALX Quant v10|
//| v10.2.0 |
//+------------------------------------------------------------------+
#property copyright "ALXQuantCore Ltd."
#property version "10.2"
/*
    v.10.2 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    Changelog:
    v.10.0 - 2026-08-09 - Add: Reader do contrato binario policy_<SYM>.bin
                            (88 bytes little-endian) com union - ver
                            v10/policy.py (fonte da verdade do layout).
    v.10.1 - 2026-08-09 - Change: nome normalizado (CPolicyReader),
                            validacao CRC + stale na leitura.
    v.10.2 - 2026-08-09 - Fix: buffer dinamico (ArrayResize) no Read();
                            decode de symbol byte-a-byte (para o nulo);
                            remocao de union nao usado. Versao .mqh v10.1.2.

    CONTRATO (bytes little-endian, offsets fixos):
      0   magic            "ALXP"        (4s)
      4   format_version   10000         (u32)
      8   generated_at     unix ts seg   (i64)
      16  symbol           12 bytes ASCII null-padded
      28  go_flag          i32 1=opera / 0=bloqueado
      32  block_reason     u8  enum POL_BLOCK
      33  direction        u8  enum POL_DIRECTION
      34  risk_mode        u8  enum POL_RISK
      35  lot_mult_pct     u16 0-100
      37  max_orders       u8
      38  flat_weekend     u8
      39  sl_atr_mult       f32
      43  tp_atr_mult       f32
      47  is_trending      u8
      48  is_mean_reverting u8
      49  is_chaos          u8
      50  vol_burst         u8
      51  liquidity_state   i8
      52  momentum_state    i8
      53  hurst             f32
      57  r2                f32
      61  vwap_dist_atr     f32
      65  roro_z            f32
      69  roro_residual     f32
      73  risk_label        i8 (-1/0/1)
      74  dominant_risk     u8
      75  macro_weight      f32 (0/0.5/1)
      79  dna_mr_score      f32 (reservado)
      83  dna_regime        u8  (reservado)
      84  crc               u32 CRC-32 (poly 0xEDB88320) sobre bytes 0..83

    NOTA: NAO usar FileReadStruct (sem suporte a #pragma pack). Ler os 88
    bytes brutos e decodificar campo a campo via unions.
*/
#ifndef ALX_POLICY_MQH
#define ALX_POLICY_MQH

//--- onde o cerebro v10 grava os binarios (live)
#ifndef ALX_MQL5_DATA_DIR
#define ALX_MQL5_DATA_DIR          "C:\\ALXQuant\\data\\mql5\\"
#endif
#define POL_STALE_SECONDS          900      // 3 x cadencia de 5 min
#define POL_TOTAL_LEN              88
#define POL_CRC_OFFSET             84
#define POL_MAGIC                  "ALXP"
#define POL_FORMAT_VERSION         10000

//--- Kernel32: bypass do sandbox MQL5 p/ ler fora do data-folder (live)
#ifndef ALX_KERNEL32_READ
#define ALX_KERNEL32_READ
#import "kernel32.dll"
   HANDLE CreateFileW(const string file_name, uint desired_access, uint share_mode, PVOID security_attributes, uint creation_disposition, uint flags_and_attributes, HANDLE template_file);
   int    CloseHandle(HANDLE object);
   int    ReadFile(HANDLE file, uchar &buffer[], uint number_of_bytes_to_read, uint &number_of_bytes_read, PVOID overlapped);
   uint   GetFileSize(HANDLE file, long &file_size_high);
   uint   GetFileAttributesW(const string file_name);
#import
#endif

//+------------------------------------------------------------------+
//| Enums (1:1 com v10/policy.py)                                    |
//+------------------------------------------------------------------+
enum POL_BLOCK
{
   POL_BLOCK_NONE              = 0,
   POL_BLOCK_CHAOS             = 1,
   POL_BLOCK_TREND             = 2,
   POL_BLOCK_BURST             = 3,
   POL_BLOCK_MOMENTUM          = 4,
   POL_BLOCK_LIQ_TOXIC         = 5,
   POL_BLOCK_RORO_EXTREME      = 6,
   POL_BLOCK_PERSISTENT_TREND  = 7,
   POL_BLOCK_FUNDING_CRISIS    = 8,
   POL_BLOCK_NEWS              = 9,
   POL_BLOCK_SESSION           = 10,
   POL_BLOCK_WEEKEND           = 11,
   POL_BLOCK_STALE             = 12,
   POL_BLOCK_ASSET_NOT_FIT     = 13
};

enum POL_DIRECTION
{
   POL_DIR_OFF       = 0,
   POL_DIR_BUY_ONLY  = 1,
   POL_DIR_SELL_ONLY = 2,
   POL_DIR_BOTH      = 3
};

enum POL_RISK
{
   POL_RISK_OFF       = 0,
   POL_RISK_DEFAULT   = 1,
   POL_RISK_NORMAL    = 2,
   POL_RISK_AGGRESSIVE = 3
};

//+------------------------------------------------------------------+
//| Unions de conversao (little-endian nativo x64)                   |
//+------------------------------------------------------------------+
union PolU16Conv  { uchar  b[2]; ushort v; }
union PolI32Conv  { uchar  b[4]; int v; }
union PolU32Conv  { uchar  b[4]; uint v; }
union PolI64Conv  { uchar  b[8]; long v; }
union PolF32Conv  { uchar  b[4]; float v; }

//+------------------------------------------------------------------+
//| Policy decodificada                                              |
//+------------------------------------------------------------------+
struct SPolicy
{
   string     symbol;
   datetime   generated_at;
   int        go_flag;
   POL_BLOCK  block_reason;
   POL_DIRECTION direction;
   POL_RISK   risk_mode;
   ushort     lot_mult_pct;
   uchar      max_orders;
   uchar      flat_weekend;
   float      sl_atr_mult;
   float      tp_atr_mult;
   uchar      is_trending;
   uchar      is_mean_reverting;
   uchar      is_chaos;
   uchar      vol_burst;
   char       liquidity_state;
   char       momentum_state;
   float      hurst;
   float      r2;
   float      vwap_dist_atr;
   float      roro_z;
   float      roro_residual;
   char       risk_label;
   uchar      dominant_risk;
   float      macro_weight;
   float      dna_mr_score;
   uchar      dna_regime;

   void Reset(void)
   {
      symbol          = "";
      generated_at    = 0;
      go_flag         = 0;
      block_reason    = POL_BLOCK_NONE;
      direction       = POL_DIR_BOTH;
      risk_mode       = POL_RISK_DEFAULT;
      lot_mult_pct    = 0;
      max_orders      = 1;
      flat_weekend    = 1;
      sl_atr_mult     = 2.0f;
      tp_atr_mult     = 2.0f;
      is_trending     = 0;
      is_mean_reverting = 0;
      is_chaos        = 0;
      vol_burst       = 0;
      liquidity_state = 0;
      momentum_state  = 0;
      hurst           = 0.5f;
      r2              = 0.0f;
      vwap_dist_atr   = 0.0f;
      roro_z          = 0.0f;
      roro_residual   = 0.0f;
      risk_label      = 0;
      dominant_risk   = 0;
      macro_weight    = 0.5f;
      dna_mr_score    = 0.5f;
      dna_regime      = 0;
   }
};

//+------------------------------------------------------------------+
//| CPolicyReader - le/valida/decodifica policy_<SYM>.bin            |
//+------------------------------------------------------------------+
class CPolicyReader
{
public:
   //--- leitura dual-path (Common no tester / kernel32 ao vivo)
   static bool Read(const string symbol, SPolicy &out)
   {
      out.Reset();
      uchar raw[];
      ArrayResize(raw, POL_TOTAL_LEN, 0);
      int size = 0;
      if(!ReadRaw(symbol, raw, size))   return false;
      return Decode(raw, out);
   }

   //--- utilidades
   static bool IsStale(const SPolicy &p)
   {
      return (TimeCurrent() - p.generated_at) > POL_STALE_SECONDS;
   }

   static string BlockText(const POL_BLOCK b)
   {
      switch(b)
      {
         case POL_BLOCK_NONE:             return "NONE";
         case POL_BLOCK_CHAOS:            return "CHAOS";
         case POL_BLOCK_TREND:            return "TREND";
         case POL_BLOCK_BURST:            return "BURST";
         case POL_BLOCK_MOMENTUM:         return "MOMENTUM";
         case POL_BLOCK_LIQ_TOXIC:        return "LIQ_TOXIC";
         case POL_BLOCK_RORO_EXTREME:     return "RORO_EXTREME";
         case POL_BLOCK_PERSISTENT_TREND: return "PERSISTENT_TREND";
         case POL_BLOCK_FUNDING_CRISIS:   return "FUNDING_CRISIS";
         case POL_BLOCK_NEWS:             return "NEWS";
         case POL_BLOCK_SESSION:          return "SESSION";
         case POL_BLOCK_WEEKEND:          return "WEEKEND";
         case POL_BLOCK_STALE:            return "STALE";
         case POL_BLOCK_ASSET_NOT_FIT:    return "ASSET_NOT_FIT";
      }
      return "UNKNOWN";
   }

   //--- decodificador (exposto p/ teste)
   static bool Decode(const uchar &raw[], SPolicy &out);

private:
   static bool ReadRaw(const string symbol, uchar &raw[], int &size);
   static uint Crc32(const uchar &data[], int len);
};

//+------------------------------------------------------------------+
//| ReadRaw - le os 88 bytes (dual-path)                             |
//+------------------------------------------------------------------+
bool CPolicyReader::ReadRaw(const string symbol, uchar &raw[], int &size)
{
   size = 0;
   string fname = StringFormat("policy_%s.bin", symbol);
   if(MQLInfoInteger(MQL_TESTER))
   {
      int h = FileOpen(fname, FILE_READ | FILE_BIN | FILE_COMMON, 0);
      if(h == INVALID_HANDLE) return false;
      uint got = FileReadArray(h, raw, 0, POL_TOTAL_LEN);
      int err  = (got != POL_TOTAL_LEN) ? GetLastError() : 0;
      FileClose(h);
      if(got != POL_TOTAL_LEN)
      {
         Print("[Policy] tamanho inesperado no Common: ", fname,
               " (ard ", got, ") err=", err);
         return false;
      }
      size = (int)got;
      return true;
   }

   //--- live: kernel32
   string fullPath = ALX_MQL5_DATA_DIR + fname;
   HANDLE hFile = CreateFileW(fullPath, GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE,
                              NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
   if(hFile == INVALID_HANDLE_VALUE) return false;
   long sizeHi = 0;
   uint fileSize = GetFileSize(hFile, sizeHi);
   if(fileSize != POL_TOTAL_LEN)
   {
      Print("[Policy] tamanho inesperado: ", fullPath,
            " (" , fileSize, " bytes)");
      CloseHandle(hFile);
      return false;
   }
   uint bytesRead = 0;
   int  ret = ReadFile(hFile, raw, fileSize, bytesRead, NULL);
   CloseHandle(hFile);
   if(ret == 0 || bytesRead != fileSize) return false;
   size = (int)bytesRead;
   return true;
}

//+------------------------------------------------------------------+
//| Crc32 - IEEE refletido poly 0xEDB88320 (igual zlib) sobre bytes  |
//+------------------------------------------------------------------+
uint CPolicyReader::Crc32(const uchar &data[], int len)
{
   static uint table[256];
   static bool built = false;
   if(!built)
   {
      for(uint i = 0; i < 256; i++)
      {
         uint c = i;
         for(int k = 0; k < 8; k++)
            c = (c & 1) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
         table[i] = c;
      }
      built = true;
   }
   uint crc = 0xFFFFFFFF;
   for(int i = 0; i < len; i++)
      crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
   return ~crc;
}

//+------------------------------------------------------------------+
//| Decode - valida magic/version/CRC e decodifica os 88 bytes       |
//+------------------------------------------------------------------+
bool CPolicyReader::Decode(const uchar &raw[], SPolicy &out)
{
   //--- magic
   if(raw[0] != 'A' || raw[1] != 'L' || raw[2] != 'X' || raw[3] != 'P')
      return false;
   //--- format_version (u32 @4)
   PolU32Conv u32;
   for(int i = 0; i < 4; i++) u32.b[i] = raw[4 + i];
   if(u32.v != POL_FORMAT_VERSION) return false;
   //--- CRC @84
   uint stored = 0;
   for(int i = 0; i < 4; i++) stored |= (uint)raw[POL_CRC_OFFSET + i] << (8 * i);
   if(Crc32(raw, POL_CRC_OFFSET) != stored) return false;

   //--- i64 generated_at @8
   PolI64Conv i64;
   for(int i = 0; i < 8; i++) i64.b[i] = raw[8 + i];
   out.generated_at = (datetime)i64.v;

   //--- symbol @16 (12 ASCII null-padded)
   out.symbol = "";
   for(int i = 0; i < 12; i++)
   {
      uchar ch = raw[16 + i];
      if(ch == 0) break;
      out.symbol += CharToString((uchar)ch);
   }

   //--- i32 go_flag @28
   PolI32Conv i32;
   for(int i = 0; i < 4; i++) i32.b[i] = raw[28 + i];
   out.go_flag = (int)i32.v;

   out.block_reason    = (POL_BLOCK)raw[32];
   out.direction       = (POL_DIRECTION)raw[33];
   out.risk_mode       = (POL_RISK)raw[34];

   //--- u16 lot_mult_pct @35
   PolU16Conv u16;
   u16.b[0] = raw[35];
   u16.b[1] = raw[36];
   out.lot_mult_pct = (ushort)u16.v;

   out.max_orders   = raw[37];
   out.flat_weekend = raw[38];

   //--- floats (f32 pouco-endian)
   PolF32Conv f;
   f.b[0] = raw[39];  f.b[1] = raw[40];  f.b[2] = raw[41];  f.b[3] = raw[42];
   out.sl_atr_mult   = (float)f.v;
   f.b[0]=raw[43]; f.b[1]=raw[44]; f.b[2]=raw[45]; f.b[3]=raw[46];
   out.tp_atr_mult   = (float)f.v;

   out.is_trending      = raw[47];
   out.is_mean_reverting = raw[48];
   out.is_chaos         = raw[49];
   out.vol_burst        = raw[50];
   out.liquidity_state  = (char)raw[51];
   out.momentum_state   = (char)raw[52];

   f.b[0]=raw[53]; f.b[1]=raw[54]; f.b[2]=raw[55]; f.b[3]=raw[56];
   out.hurst           = (float)f.v;
   f.b[0]=raw[57]; f.b[1]=raw[58]; f.b[2]=raw[59]; f.b[3]=raw[60];
   out.r2              = (float)f.v;
   f.b[0]=raw[61]; f.b[1]=raw[62]; f.b[2]=raw[63]; f.b[3]=raw[64];
   out.vwap_dist_atr   = (float)f.v;
   f.b[0]=raw[65]; f.b[1]=raw[66]; f.b[2]=raw[67]; f.b[3]=raw[68];
   out.roro_z          = (float)f.v;
   f.b[0]=raw[69]; f.b[1]=raw[70]; f.b[2]=raw[71]; f.b[3]=raw[72];
   out.roro_residual   = (float)f.v;

   out.risk_label      = (char)raw[73];
   out.dominant_risk   = raw[74];

   f.b[0]=raw[75]; f.b[1]=raw[76]; f.b[2]=raw[77]; f.b[3]=raw[78];
   out.macro_weight    = (float)f.v;
   f.b[0]=raw[79]; f.b[1]=raw[80]; f.b[2]=raw[81]; f.b[3]=raw[82];
   out.dna_mr_score    = (float)f.v;

   out.dna_regime      = raw[83];
   return true;
}

#endif   // ALX_POLICY_MQH