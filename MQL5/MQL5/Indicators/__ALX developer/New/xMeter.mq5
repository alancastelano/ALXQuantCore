//+------------------------------------------------------------------+
//|                                                     xMeterMTF.mq5|
//|                          x Meter System™ ©GPL                    |
//|   Original (MQL4): Hartono Setiono / forex-tsd, 2007             |
//+------------------------------------------------------------------+
#property copyright "x Meter System™ ©GPL"
#property link      "forex-tsd dot com"
#property indicator_chart_window
#property indicator_buffers 0
#property indicator_plots   0    // painel 100% baseado em objetos (o aviso do compilador é inofensivo)

#define TABSIZE   11               // tabela de notas (o original declarava 19, mas só usava 11 valores)
#define MAX_TRADE 10               // limite do array aIndex[][10]

//--- parâmetros
input string InpSymbolSuffix = ""; // Sufixo dos símbolos da corretora ("m" = IBFX mini, ".r", "_m" etc.)

//--- configuração (pode editar)
string aTradePair[] = {"GBPJPY"};
string aPair[]      = {"EURUSD","GBPUSD","AUDUSD","NZDUSD","USDJPY","USDZAR","USDCHF","USDCAD","EURCAD","USDSEK","GBPCAD","USDMXN",
                       "EURJPY","EURGBP","EURCHF","EURAUD","EURNZD","GBPJPY","GBPCHF","USDNOK","EURNOK","USDTRY","EURTRY","EURSEK"};
string aMajor[]     = {"USD","EUR","GBP","CHF","CAD","AUD","NZD","JPY","NOK","SEK","TRY","MXN","ZAR"};
int    aMajorPos[]  = {250,230,210,190,170,150,130,110,90,70,50,30,10};   // posição X de cada moeda

//--- estado
string Id = "xmeter2";
int    PairCount = 0, CurrencyCount = 0;
double aMeter[], aHigh[], aLow[], aBid[], aAsk[], aRatio[], aRange[], aLookup[], aStrength[];
bool   aValid[];
int    aIndex[2][MAX_TRADE];
int    aTable[TABSIZE] = {0,3,10,25,40,50,60,75,90,97,100};   // notas 0..9

//+------------------------------------------------------------------+
//| Inicialização                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   PairCount     = ArraySize(aPair);
   CurrencyCount = ArraySize(aMajor);
   if(CurrencyCount != ArraySize(aMajorPos))
      Print("aMajor e aMajorPos devem ter o mesmo tamanho");

   ArrayResize(aMeter,    CurrencyCount);
   ArrayResize(aHigh,     PairCount);
   ArrayResize(aLow,      PairCount);
   ArrayResize(aBid,      PairCount);
   ArrayResize(aAsk,      PairCount);
   ArrayResize(aRatio,    PairCount);
   ArrayResize(aRange,    PairCount);
   ArrayResize(aLookup,   PairCount);
   ArrayResize(aStrength, PairCount);
   ArrayResize(aValid,    PairCount);

   //--- registra os símbolos no Market Watch e verifica disponibilidade
   for(int i = 0; i < PairCount; i++)
     {
      aValid[i] = SymbolSelect(aPair[i] + InpSymbolSuffix, true);
      if(!aValid[i])
         Print("xMeter: símbolo indisponível: ", aPair[i] + InpSymbolSuffix);
     }

   init_tradepair_index();
   initGraph();

   EventSetTimer(1);      // atualiza 1x/s, mesmo sem ticks no gráfico atual
   UpdateMeter();
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Finalização                                                      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeleteExistingLabels();
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| Tick do gráfico (equivale ao start() original)                   |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   UpdateMeter();
   return(rates_total);
  }
//+------------------------------------------------------------------+
//| Timer: atualiza mesmo sem ticks (substitui o loop infinito)      |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      objectBlank();               // sem conexão: apaga o painel (como no original)
      ChartRedraw();
      return;
     }
   UpdateMeter();
  }
//+------------------------------------------------------------------+
//| Centro de controle (função main() do original)                   |
//+------------------------------------------------------------------+
void UpdateMeter()
  {
   static uint lastRun = 0;
   if(GetTickCount() - lastRun < 500)   // no máximo ~2 atualizações por segundo
      return;
   lastRun = GetTickCount();

   //--- coleta os valores de cada par
   for(int index = 0; index < PairCount; index++)
     {
      if(!aValid[index])
         continue;
      string sym = aPair[index] + InpSymbolSuffix;

      MqlRates rates[];
      if(CopyRates(sym, PERIOD_D1, 0, 1, rates) < 1)
         continue;                                   // histórico D1 ainda sincronizando

      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(bid <= 0.0 || ask <= 0.0)
         continue;

      aHigh[index]     = rates[0].high;              // máxima do dia (MODE_HIGH)
      aLow[index]      = rates[0].low;               // mínima do dia  (MODE_LOW)
      aBid[index]      = bid;
      aAsk[index]      = ask;

      double point     = SymbolInfoDouble(sym, SYMBOL_POINT);
      aRange[index]    = MathMax((aHigh[index] - aLow[index]) / point, 1.0);
      aRatio[index]    = (aBid[index] - aLow[index]) / aRange[index] / point;
      aLookup[index]   = iLookup(aRatio[index] * 100.0);
      aStrength[index] = 9.9 - aLookup[index];
     }

   //--- média por moeda
   for(int p = 0; p < CurrencyCount; p++)
     {
      int    cnt   = 0;
      double cmeter = 0.0;
      for(int index = 0; index < PairCount; index++)
        {
         if(!aValid[index])
            continue;
         if(StringSubstr(aPair[index], 0, 3) == aMajor[p]) { cnt++; cmeter += aLookup[index];   }
         if(StringSubstr(aPair[index], 3, 3) == aMajor[p]) { cnt++; cmeter += aStrength[index]; }
        }
      aMeter[p] = (cnt > 0) ? NormalizeDouble(cmeter / cnt, 1) : -1;
     }

   //--- desenho
   objectBlank();
   for(int p = 0; p < CurrencyCount; p++)
      paintCurr(p, aMeter[p]);
   paintLine();
   ChartRedraw();
  }
//+------------------------------------------------------------------+
//| Índices das moedas dos pares negociáveis                         |
//+------------------------------------------------------------------+
void init_tradepair_index()
  {
   int n = MathMin(ArraySize(aTradePair), MAX_TRADE);
   for(int k = 0; k < n; k++)
     {
      string cpair = aTradePair[k];                  // correção: o original usava sempre aTradePair[0]
      string m1 = StringSubstr(cpair, 0, 3);
      string m2 = StringSubstr(cpair, 3, 3);
      aIndex[0][k] = -1;
      aIndex[1][k] = -1;
      for(int i = 0; i < CurrencyCount; i++)
        {
         if(m1 == aMajor[i]) aIndex[0][k] = i;
         if(m2 == aMajor[i]) aIndex[1][k] = i;
        }
      if(aIndex[0][k] == -1 || aIndex[1][k] == -1)
         Print("Currency Pair : ", cpair, " is not tradeable, check array definition!");
     }
  }
//+------------------------------------------------------------------+
//| Converte a posição no range (0-100) em nota 0-9                  |
//+------------------------------------------------------------------+
int iLookup(double ratio)
  {
   int index = -1;
   if(ratio <= aTable[0])
      index = 0;
   else
     {
      for(int i = 1; i < TABSIZE; i++)
         if(ratio < aTable[i]) { index = i - 1; break; }
      if(index == -1)
         index = 9;                                  // no original: "9.9" (truncado para 9)
     }
   return(index);
  }
//+------------------------------------------------------------------+
//| Criação do painel                                                |
//+------------------------------------------------------------------+
void initGraph()
  {
   DeleteExistingLabels();

   for(int p = 0; p < CurrencyCount; p++)
     {
      objectCreate(Id + aMajor[p] + "_1", aMajorPos[p],      43);
      objectCreate(Id + aMajor[p] + "_2", aMajorPos[p],      35);
      objectCreate(Id + aMajor[p] + "_3", aMajorPos[p],      27);
      objectCreate(Id + aMajor[p] + "_4", aMajorPos[p],      19);
      objectCreate(Id + aMajor[p] + "_5", aMajorPos[p],      11);
      objectCreate(Id + aMajor[p],        aMajorPos[p] + 2,  12, aMajor[p],            7, "Arial Narrow", clrSkyBlue);
      objectCreate(Id + aMajor[p] + "p",  aMajorPos[p] + 4,  21, DoubleToString(9, 1), 8, "Arial Narrow", clrSilver);
     }

   objectCreate(Id + "line",  15,  6, "-------------------------------------------------------------------------", 10, "Arial", clrDimGray);
   objectCreate(Id + "line1", 15, 27, "-------------------------------------------------------------------------", 10, "Arial", clrDimGray);
   objectCreate(Id + "line2", 15, 69, "-------------------------------------------------------------------------", 10, "Arial", clrDimGray);
   ChartRedraw();
  }
//+------------------------------------------------------------------+
void objectCreate(string name, int x, int y, string text = "-", int size = 42,
                  string font = "Arial", color colour = clrNONE)
  {
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_RIGHT_LOWER);   // corner 3 do MQL4
   ObjectSetInteger(0, name, OBJPROP_COLOR,      colour);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetString (0, name, OBJPROP_TEXT,       text);
   ObjectSetString (0, name, OBJPROP_FONT,       font);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   size);
  }
//+------------------------------------------------------------------+
void objectBlank()
  {
   for(int p = 0; p < CurrencyCount; p++)
     {
      for(int b = 1; b <= 5; b++)
         ObjectSetInteger(0, Id + aMajor[p] + "_" + IntegerToString(b), OBJPROP_COLOR, clrNONE);
      ObjectSetInteger(0, Id + aMajor[p],         OBJPROP_COLOR, clrNONE);
      ObjectSetInteger(0, Id + aMajor[p] + "p",   OBJPROP_COLOR, clrNONE);
     }
   ObjectSetInteger(0, Id + "line1", OBJPROP_COLOR, clrNONE);
   ObjectSetInteger(0, Id + "line2", OBJPROP_COLOR, clrNONE);
  }
//+------------------------------------------------------------------+
void paintCurr(int pindex, double value)
  {
   string base = Id + aMajor[pindex];
   if(value > 0) ObjectSetInteger(0, base + "_5", OBJPROP_COLOR, clrRed);
   if(value > 2) ObjectSetInteger(0, base + "_4", OBJPROP_COLOR, clrOrange);
   if(value > 4) ObjectSetInteger(0, base + "_3", OBJPROP_COLOR, clrGold);
   if(value > 6) ObjectSetInteger(0, base + "_2", OBJPROP_COLOR, clrYellowGreen);
   if(value > 7) ObjectSetInteger(0, base + "_1", OBJPROP_COLOR, clrLime);
   ObjectSetInteger(0, base,       OBJPROP_COLOR, clrSkyBlue);
   ObjectSetString (0, base + "p", OBJPROP_TEXT,  DoubleToString(value, 1));
  }
//+------------------------------------------------------------------+
void paintLine()
  {
   ObjectSetInteger(0, Id + "line1", OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, Id + "line2", OBJPROP_COLOR, clrDimGray);
  }
//+------------------------------------------------------------------+
void DeleteExistingLabels()
  {
   ObjectsDeleteAll(0, Id, -1, OBJ_LABEL);   // apaga tudo com o prefixo de uma vez
  }