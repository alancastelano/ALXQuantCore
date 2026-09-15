//+------------------------------------------------------------------+
//|                                                        Enums.mqh |
//|                                  Copyright 2023, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"


//+------------------------------------------------------------------+
//| Enum Lor or Risk                                                 |
//+------------------------------------------------------------------+
enum ENUM_LOT_OR_RISK
  {
   lot=0,   // Lote Fixo
   risk=1,  // Risco % sobre capital
  };
  
enum enDirection
   {
      Dir0=0, // Compra & Venda
      Dir1=1, // Somente comprado
      Dir2=2  // Somente vendido
   };  