//+------------------------------------------------------------------+
//|                                                       Design.mqh |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
*/

#resource "\\Images\\alxquant_logo.bmp";    // Caminho da imagem

enum ENUM_LINE_TYPE { LINE_BUY, LINE_SELL, LINE_SL, LINE_TP, LINE_BE };
enum ENUM_PNL_MODE  { PNL_USD, PNL_PCT, PNL_POINTS };


class CDesign
  {
private:
   //--- Tokyo Night UI Palette -----------------------------------------------
   color    TN_BG;     
   color    TN_BG2;      
   color    TN_PANEL;
   color    TN_BORDER;
   
   color    TN_FG;         
   color    TN_COMMENT;   
   
   color    TN_ORANGE;
   color    TN_ORANGE_LIGHT;
   color    TN_ORANGE_GLOW;
   color    TN_GOLD;
   
   color    TN_BULL;
   color    TN_BEAR;
   
   color    TN_CYAN;
   color    TN_PURPLE;
   color    TN_YELLOW;

   string   m_logoName; // Nome do objeto do logo para limpeza

   //--- Métodos Privados (SEM o CDesign:: aqui dentro)
   void     ApplyChartColors();
   void     CreateLogo();               

public:
            CDesign();  // Construtor
           ~CDesign();  // Destructor

   //--- Método de Inicialização (Adicionado flag para controlar a aplicação do tema)
   bool     Init(bool applyTheme = true); 
   
   //void     DeleteTradeLines(string prefix); 
   
   /*
   
   // No OnTick(), depois de abrir a posição:
      DrawTradeLine("trend_", 123456, LINE_BUY,  entry_price, "XAUUSD", 125.50, PNL_USD);
      DrawTradeLine("trend_", 123456, LINE_SL,   sl_price,    "XAUUSD", -80.00, PNL_USD);
      DrawTradeLine("trend_", 123456, LINE_TP,   tp_price,    "XAUUSD", 250.00, PNL_USD);
      DrawTradeLine("trend_", 123456, LINE_BE,   entry_price, "XAUUSD", 0.0,    PNL_USD);
      
      // No OnDeinit():
      DeleteTradeLines("trend_");
   */
   
   
                    
  };
//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CDesign::CDesign() : m_logoName("ALX_LOGO")
  {
   // Inicializa cores com valores padrão (safety)
   TN_BG = C'8,8,10';
   // ...
  }
//+------------------------------------------------------------------+
//| Destructor - LIMPEZA OBRIGATÓRIA                                 |
//+------------------------------------------------------------------+
CDesign::~CDesign()
  {
   // Ao fechar o EA, remove o logo do gráfico para não deixar sujeira
   ObjectDelete(0, m_logoName);
   ChartRedraw(0);
  }
//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
bool CDesign::Init(bool applyTheme = true)
{
   TN_BG       = C'8,8,10' ;       
   TN_BG2      = C'15,15,18';      
   TN_PANEL    = C'20,20,24';
   TN_BORDER   = C'45,45,50';
   
   TN_FG       = C'220,220,220';   
   TN_COMMENT  = C'140,140,145';   
   
   TN_ORANGE   = C'255,140,0';
   TN_ORANGE_LIGHT = C'255,170,40';
   TN_ORANGE_GLOW  = C'255,110,0';
   TN_GOLD         = C'255,190,60';
   
   TN_BULL     = C'255,150,30';
   TN_BEAR     = C'190,60,60';
   
   TN_CYAN     = C'0,190,255';
   TN_PURPLE   = C'140,90,255';
   TN_YELLOW   = C'255,220,80';

   // Só aplica as cores no gráfico se o flag estiver ligado
   if(applyTheme)
   {
      ApplyChartColors();
      CreateLogo();
   }
   
   
  Print(__FUNCTION__ + " - The initial design module has been successfully initialized!"); 
  return(true); 
   
}
//+------------------------------------------------------------------+
//| Apply Tokyo Night palette to the chart                           |
//+------------------------------------------------------------------+
void CDesign::ApplyChartColors()
{
   long cid = ChartID();

   // Estrutura
   ChartSetInteger(cid, CHART_SHOW_GRID, false);
   ChartSetInteger(cid, CHART_SHOW_VOLUMES, CHART_VOLUME_HIDE);
   ChartSetInteger(cid, CHART_SHOW_TICKER, false);
   ChartSetInteger(cid, CHART_SHOW_ONE_CLICK, false);

   // Background
   ChartSetInteger(cid, CHART_COLOR_BACKGROUND, 0, TN_BG);
   ChartSetInteger(cid, CHART_COLOR_FOREGROUND, 0, TN_FG);

   // Grid e bordas
   ChartSetInteger(cid, CHART_COLOR_GRID, 0, TN_BORDER);

   // Candles
   ChartSetInteger(cid, CHART_COLOR_CHART_UP, 0, TN_BULL);
   ChartSetInteger(cid, CHART_COLOR_CHART_DOWN, 0, TN_BEAR);

   ChartSetInteger(cid, CHART_COLOR_CANDLE_BULL, 0, TN_BULL);
   ChartSetInteger(cid, CHART_COLOR_CANDLE_BEAR, 0, TN_BEAR);

   // Linha
   ChartSetInteger(cid, CHART_COLOR_CHART_LINE, 0, TN_ORANGE_LIGHT);

   // Volume
   ChartSetInteger(cid, CHART_COLOR_VOLUME, 0, TN_ORANGE);

   // Bid / Ask
   ChartSetInteger(cid, CHART_COLOR_BID, 0, TN_CYAN);
   ChartSetInteger(cid, CHART_COLOR_ASK, 0, TN_ORANGE);

   // Last / Stop
   ChartSetInteger(cid, CHART_COLOR_LAST, 0, TN_GOLD);
   ChartSetInteger(cid, CHART_COLOR_STOP_LEVEL, 0, TN_PURPLE);

   // Linhas
   ChartSetInteger(cid, CHART_SHOW_BID_LINE, true);
   ChartSetInteger(cid, CHART_SHOW_ASK_LINE, true);
}
//+------------------------------------------------------------------+
//| Create Logo                                                      |
//+------------------------------------------------------------------+
void CDesign::CreateLogo()
{
   // Verifica se o logo já existe para não recriar se for chamado mais de uma vez
   if(ObjectFind(0, m_logoName) >= 0) return; 

   ObjectCreate(0, m_logoName, OBJ_BITMAP_LABEL, 0, 0, 0);    
   ObjectSetString(0, m_logoName, OBJPROP_BMPFILE, "::Images\\alxquant_logo.bmp");    
   ObjectSetInteger(0, m_logoName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);    
   ObjectSetInteger(0, m_logoName, OBJPROP_XDISTANCE, 150);    
   ObjectSetInteger(0, m_logoName, OBJPROP_YDISTANCE, 5);
   ObjectSetInteger(0, m_logoName, OBJPROP_BACK, false);    
   ObjectSetInteger(0, m_logoName, OBJPROP_SELECTABLE, false);    
   ObjectSetInteger(0, m_logoName, OBJPROP_HIDDEN, true);    
}
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| DrawTradeLine — Linha estilizada no gráfico                      |
//+------------------------------------------------------------------+

//--- Helper: preço ? Y em pixels
int PriceToY(double price)
{
   int x = 0, y = 0;
   datetime time = iTime(_Symbol, PERIOD_CURRENT, 0);
   ChartTimePriceToXY(0, 0, time, price, x, y);
   return y;
}

//--- Helper: formata P&L
string FormatPnL(double val, ENUM_PNL_MODE mode, string &mode_str)
{
   string sign = (val >= 0) ? "+" : "";
   switch(mode)
   {
      case PNL_USD:    mode_str = "fin";  return sign + "$" + DoubleToString(val, 2);
      case PNL_PCT:    mode_str = "pct";  return sign + DoubleToString(val, 2) + "%";
      case PNL_POINTS: mode_str = "pts";  return sign + DoubleToString(val, 1) + " pts";
   }
   return "";
}

//+------------------------------------------------------------------+
void DrawTradeLine(
   string          prefix,
   ulong           magic,
   ENUM_LINE_TYPE  line_type,
   double          price,
   string          label_text,
   double          pnl_value,
   ENUM_PNL_MODE   pnl_mode
)
{
   //if(!InpUI_lines)
   //   return;


   //--- Config por tipo
   color  line_color = clrNONE, dim_color = clrNONE, bg_color = clrNONE;
   string type_icon, type_label;
   ENUM_LINE_STYLE line_style = STYLE_SOLID;
   int line_width = 1;

   switch(line_type)
   {
      case LINE_BUY:
         line_color=clrLimeGreen; dim_color=clrForestGreen; bg_color=clrDarkGreen;
         type_icon="^ "; type_label="BUY";  line_width=2; break;
      case LINE_SELL:
         line_color=clrTomato;    dim_color=clrFireBrick;   bg_color=clrMaroon;
         type_icon="v "; type_label="SELL"; line_width=2; break;
      case LINE_SL:
         line_color=clrIndianRed; dim_color=clrBrown;       bg_color=clrDarkRed;
         type_icon="x "; type_label="SL";   line_style=STYLE_DOT; break;
      case LINE_TP:
         line_color=clrCyan;      dim_color=clrTeal;        bg_color=clrDarkSlateGray;
         type_icon="o "; type_label="TP";   break;
      case LINE_BE:
         line_color=clrGold;      dim_color=clrDarkGoldenrod; bg_color=clrSaddleBrown;
         type_icon="- "; type_label="BE";   line_style=STYLE_DASH; break;
   }

   //--- Nomes dos objetos
   string base       = prefix + type_label;
   string name_line  = base + "_line";
   string name_rect  = base + "_rect";
   string name_label = base + "_lbl";
   string name_magic = base + "_mgc";
   string name_pnl   = base + "_pnl";

   //--- Limpa anteriores
   ObjectDelete(0, name_line);
   ObjectDelete(0, name_rect);
   ObjectDelete(0, name_label);
   ObjectDelete(0, name_magic);
   ObjectDelete(0, name_pnl);

   //--- Converte preço para Y (pixel) — usado só pelos OBJ_LABEL e OBJ_RECTANGLE_LABEL
   int py = PriceToY(price);

   // ================================================================
   // 1. LINHA HORIZONTAL
   // ================================================================
   ObjectCreate(0, name_line, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name_line, OBJPROP_COLOR,      line_color);
   ObjectSetInteger(0, name_line, OBJPROP_STYLE,      line_style);
   ObjectSetInteger(0, name_line, OBJPROP_WIDTH,      line_width);
   ObjectSetInteger(0, name_line, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name_line, OBJPROP_BACK,       true);

   // ================================================================
   // 2. RETÂNGULO (OBJ_RECTANGLE_LABEL — coordenadas de pixel)
   // ================================================================
   ObjectCreate(0, name_rect, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name_rect, OBJPROP_XDISTANCE,  10);
   ObjectSetInteger(0, name_rect, OBJPROP_YDISTANCE,  py - 17);   // centralizado na linha
   ObjectSetInteger(0, name_rect, OBJPROP_XSIZE,      230);
   ObjectSetInteger(0, name_rect, OBJPROP_YSIZE,      34);
   ObjectSetInteger(0, name_rect, OBJPROP_BGCOLOR,    bg_color);
   ObjectSetInteger(0, name_rect, OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0, name_rect, OBJPROP_COLOR,      line_color);
   ObjectSetInteger(0, name_rect, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name_rect, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name_rect, OBJPROP_BACK,       false);

   // ================================================================
   // 3. TEXTO: Tipo + Label do ativo/estratégia
   // ================================================================
   string full_label = type_icon + type_label + (label_text != "" ? " | " + label_text : "");
   ObjectCreate(0, name_label, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name_label, OBJPROP_XDISTANCE,  18);
   ObjectSetInteger(0, name_label, OBJPROP_YDISTANCE,  py - 13);
   ObjectSetString (0, name_label, OBJPROP_TEXT,       full_label);
   ObjectSetInteger(0, name_label, OBJPROP_COLOR,      line_color);
   ObjectSetInteger(0, name_label, OBJPROP_FONTSIZE,   8);
   ObjectSetString (0, name_label, OBJPROP_FONT,       "Courier New");
   ObjectSetInteger(0, name_label, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name_label, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name_label, OBJPROP_BACK,       false);

   // ================================================================
   // 4. TEXTO: Magic Number
   // ================================================================
   ObjectCreate(0, name_magic, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name_magic, OBJPROP_XDISTANCE,  18);
   ObjectSetInteger(0, name_magic, OBJPROP_YDISTANCE,  py - 1);
   ObjectSetString (0, name_magic, OBJPROP_TEXT,       "ID:" + IntegerToString(magic));
   ObjectSetInteger(0, name_magic, OBJPROP_COLOR,      dim_color);
   ObjectSetInteger(0, name_magic, OBJPROP_FONTSIZE,   7);
   ObjectSetString (0, name_magic, OBJPROP_FONT,       "Courier New");
   ObjectSetInteger(0, name_magic, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name_magic, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name_magic, OBJPROP_BACK,       false);

   // ================================================================
   // 5. TEXTO: P&L (direita do retângulo)
   // ================================================================
   string mode_str  = "";
   string pnl_str   = FormatPnL(pnl_value, pnl_mode, mode_str);
   color  pnl_color = (pnl_value >= 0) ? clrLimeGreen : clrTomato;

   ObjectCreate(0, name_pnl, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name_pnl, OBJPROP_XDISTANCE,  155);
   ObjectSetInteger(0, name_pnl, OBJPROP_YDISTANCE,  py - 7);
   ObjectSetString (0, name_pnl, OBJPROP_TEXT,       pnl_str + "  " + mode_str);
   ObjectSetInteger(0, name_pnl, OBJPROP_COLOR,      pnl_color);
   ObjectSetInteger(0, name_pnl, OBJPROP_FONTSIZE,   8);
   ObjectSetString (0, name_pnl, OBJPROP_FONT,       "Courier New");
   ObjectSetInteger(0, name_pnl, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name_pnl, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name_pnl, OBJPROP_BACK,       false);

   ChartRedraw(0);
}

// ================================================================
// DELETE: Remove todas as linhas de um prefixo
// ================================================================
void DeleteTradeLines(string prefix)
{
   string types[] = {"BUY","SELL","SL","TP","BE"};
   string objs[]  = {"_line","_rect","_lbl","_mgc","_pnl"};

   for(int t = 0; t < ArraySize(types); t++)
      for(int o = 0; o < ArraySize(objs); o++)
         ObjectDelete(0, prefix + types[t] + objs[o]);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Calcula P&L real de uma posição                                  |
//+------------------------------------------------------------------+

// Retorna o P&L atual da posição (já aberta)
double CalcCurrentPnL(ulong ticket, ENUM_PNL_MODE mode)
{
   if(!PositionSelectByTicket(ticket)) return 0.0;

   double profit     = PositionGetDouble(POSITION_PROFIT);   // P&L financeiro atual
   double swap       = PositionGetDouble(POSITION_SWAP);
   double volume     = PositionGetDouble(POSITION_VOLUME);
   double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
   double price_cur  = PositionGetDouble(POSITION_PRICE_CURRENT);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   switch(mode)
   {
      case PNL_USD:
         return profit + swap;  // P&L financeiro já pronto no MT5

      case PNL_PCT:
      {
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         if(balance <= 0) return 0.0;
         return ((profit + swap) / balance) * 100.0;
      }

      case PNL_POINTS:
      {
         double diff = (type == POSITION_TYPE_BUY)
                        ? (price_cur - price_open)
                        : (price_open - price_cur);
         return diff / point;
      }
   }
   return 0.0;
}

//+------------------------------------------------------------------+
// Calcula o que PERDE se o SL for atingido
//+------------------------------------------------------------------+
double CalcSLPnL(ulong ticket, ENUM_PNL_MODE mode)
{
   if(!PositionSelectByTicket(ticket)) return 0.0;

   double sl         = PositionGetDouble(POSITION_SL);
   if(sl == 0.0) return 0.0;

   double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume     = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   // Distância em pontos até o SL
   double dist_pts = (type == POSITION_TYPE_BUY)
                      ? (price_open - sl) / point
                      : (sl - price_open) / point;

   // Valor financeiro por ponto por lote
   double value_per_point = (tick_size > 0) ? (tick_value / tick_size) * point : 0.0;
   double loss_usd = dist_pts * value_per_point * volume * -1.0; // sempre negativo

   switch(mode)
   {
      case PNL_USD: return loss_usd;
      case PNL_PCT:
      {
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         return (balance > 0) ? (loss_usd / balance) * 100.0 : 0.0;
      }
      case PNL_POINTS: return dist_pts * -1.0;
   }
   return 0.0;
}

//+------------------------------------------------------------------+
// Calcula o que GANHA se o TP for atingido
//+------------------------------------------------------------------+
double CalcTPPnL(ulong ticket, ENUM_PNL_MODE mode)
{
   if(!PositionSelectByTicket(ticket)) return 0.0;

   double tp         = PositionGetDouble(POSITION_TP);
   if(tp == 0.0) return 0.0;

   double price_open = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume     = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   // Distância em pontos até o TP
   double dist_pts = (type == POSITION_TYPE_BUY)
                      ? (tp - price_open) / point
                      : (price_open - tp) / point;

   double value_per_point = (tick_size > 0) ? (tick_value / tick_size) * point : 0.0;
   double gain_usd = dist_pts * value_per_point * volume; // sempre positivo

   switch(mode)
   {
      case PNL_USD: return gain_usd;
      case PNL_PCT:
      {
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         return (balance > 0) ? (gain_usd / balance) * 100.0 : 0.0;
      }
      case PNL_POINTS: return dist_pts;
   }
   return 0.0;
}