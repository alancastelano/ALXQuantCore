//+------------------------------------------------------------------+
//|                                                     ALXPanel.mqh |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Controls/Dialog.mqh>
#include <Controls/SpinEdit.mqh>
#include <Controls/Label.mqh>

//+------------------------------------------------------------------+
//| CLASSE DO PAINEL                                                 |
//+------------------------------------------------------------------+
class CALXPanel : public CAppDialog
{
private:
public:
   CLabel    m_lbls[5];
   CSpinEdit m_spns[5];

   CALXPanel() {}
   void Init(string title);
   
   virtual bool Create(const long chart, const string name, const int subwin, const int x1, const int y1, const int x2, const int y2);
   
   // ✅ ADICIONAR ESTE MÉTODO para interceptar eventos ANTES do CAppDialog
   virtual void ChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
   {
      Print("🎛️ [PAINEL] ChartEvent interceptado! id=", id, " sparam='", sparam, "'");
      
      // Chamar OnEvent manualmente
      OnEvent(id, lparam, dparam, sparam);
      
      // E depois chamar a classe pai
      CAppDialog::ChartEvent(id, lparam, dparam, sparam);
   }
   
   virtual bool OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam);
   
private:
   bool AddRow(int i, string txt, int y, int val, int minV, int maxV);
};

/*
//+------------------------------------------------------------------+
//| CLASSE DO PAINEL - MANTÉM OS SPINS VIVOS                        |
//+------------------------------------------------------------------+
class CALXPanel : public CAppDialog
 {
private:
public:
   CLabel    m_lbls[5];
   CSpinEdit m_spns[5];

   CALXPanel() {}
   void Init(string title);
   
   virtual bool Create(const long chart, const string name, const int subwin, const int x1, const int y1, const int x2, const int y2);
   virtual bool OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam);
private:
   bool AddRow(int i, string txt, int y, int val, int minV, int maxV);
};
*/



//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
void CALXPanel::Init(string title)
{
   g_prefix          = "alx_" + (string)ChartID() + "_";
   g_MinRange        = MinRange;
   g_MaxRange        = MaxRange;
   g_HighLowFilter   = HighLowFilter;
   g_MaxHistoryBars  = MaxHistoryBars;
   g_StopPips        = SimulatedStopPips;

   if(!Create(0,title, 0, 20, 20, 280, 250)) return;
   CALXPanel::Run();
}

bool CALXPanel::Create(const long chart, const string name, const int subwin, const int x1, const int y1, const int x2, const int y2)
{
   if(!CAppDialog::Create(chart, name, subwin, x1, y1, x2, y2)) return false;
   int y=20;
   AddRow(0, "Min Range", y, g_MinRange, 1, 50); y+=30;
   AddRow(1, "Max Range", y, g_MaxRange, 1, 100); y+=30;
   AddRow(2, "H/L Filter", y, g_HighLowFilter, 1, 100); y+=30;
   AddRow(3, "History Bars", y, g_MaxHistoryBars, 50, 5000); y+=30;
   AddRow(4, "Stop (pips)", y, g_StopPips, 1, 500);
   return true;
}

bool CALXPanel::AddRow(int i, string txt, int y, int val, int minV, int maxV)
{
   string   font     = "Verdana";
   int      fontsize = 8;


   m_lbls[i].Create(m_chart_id, m_name+"_l"+(string)i, 0, 10, y, 120, y+20);
   m_lbls[i].Text(txt);
   m_lbls[i].Font(font);
   m_lbls[i].FontSize(fontsize);
   Add(m_lbls[i]);
   
   m_spns[i].Create(m_chart_id, m_name+"_s"+(string)i, 0, 100, y, 180, y+20);
   m_spns[i].MinValue(minV);
   m_spns[i].MaxValue(maxV);
   m_spns[i].Value(val);
   Add(m_spns[i]);

   return true;
}

bool CALXPanel::OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   bool handled = CAppDialog::OnEvent(id, lparam, dparam, sparam);

   // ✅ ACEITAR id=10 e id=1009 que aparecem no seu log
   if(id == CHARTEVENT_OBJECT_ENDEDIT || 
      id == CHARTEVENT_OBJECT_CHANGE ||
      id == 10 ||        // WM_COMMAND
      id == 1009)        // Evento custom MT5
   {
      Print("✅ [PAINEL] Evento detectado! id=", id, " sparam='", sparam, "'");
      
      // ✅ PROCURAR por "Edit" no nome (que aparece no seu log)
      if(StringFind(sparam, "Edit") >= 0 || StringFind(sparam, "_s") >= 0)
      {
         Print("✅ [PAINEL] SpinEdit alterado! 002...");
         
         // Atualizar variáveis
         g_MinRange       = (int)m_spns[0].Value();
         g_MaxRange       = (int)m_spns[1].Value();
         g_HighLowFilter  = (int)m_spns[2].Value();
         g_MaxHistoryBars = (int)m_spns[3].Value();
         g_StopPips       = (int)m_spns[4].Value();

         if(g_MaxRange < g_MinRange)
         {
            g_MaxRange = g_MinRange;
            m_spns[1].Value(g_MaxRange);
         }

         Print("📊 Painel: Min=", g_MinRange, " Max=", g_MaxRange);

         EventChartCustom(ChartID(), 1001, 0, 0, "");
         
         return true;
      }
   }
   
   return handled;
}

/*
bool CALXPanel::OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   bool handled = CAppDialog::OnEvent(id, lparam, dparam, sparam);

   // ✅ ACEITAR MÚLTIPLOS TIPOS DE EVENTO
   // id=10 pode ser WM_COMMAND do Windows
   // id=1009 é evento custom do MQL5
   // id=65537 = CHARTEVENT_OBJECT_CHANGE
   // id=65538 = CHARTEVENT_OBJECT_ENDEDIT
   
   if(id == CHARTEVENT_OBJECT_ENDEDIT || 
      id == CHARTEVENT_OBJECT_CHANGE ||
      id == 10 ||        // ← WM_COMMAND (Windows)
      id == 1009 ||      // ← Evento custom MT5
      id == CHARTEVENT_OBJECT_CLICK)
   {
      Print("✅ [PAINEL] Evento detectado! id=", id, " sparam='", sparam, "'");
      
      // ✅ BUSCA FLEXÍVEL: procura por "_s" no nome
      if(StringFind(sparam, "_s") >= 0)
      {
         Print("✅ [PAINEL] SpinEdit alterado! 002...");
         
         // Atualizar variáveis globais
         g_MinRange       = (int)m_spns[0].Value();
         g_MaxRange       = (int)m_spns[1].Value();
         g_HighLowFilter  = (int)m_spns[2].Value();
         g_MaxHistoryBars = (int)m_spns[3].Value();
         g_StopPips       = (int)m_spns[4].Value();

         // Validar Min/Max
         if(g_MaxRange < g_MinRange)
         {
            g_MaxRange = g_MinRange;
            m_spns[1].Value(g_MaxRange);
         }

         Print("📊 Painel: Min=", g_MinRange, " Max=", g_MaxRange);

         // Disparar evento para o indicador
         EventChartCustom(ChartID(), 1001, 0, 0, "");
         
         return true;
      }
   }
   
   return handled;
}

/*
bool CALXPanel::OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   bool handled = CAppDialog::OnEvent(id, lparam, dparam, sparam);

   // ✅ Aceitar múltiplos tipos de evento
   if(id == CHARTEVENT_OBJECT_ENDEDIT || 
      id == CHARTEVENT_OBJECT_CHANGE ||
      id == CHARTEVENT_OBJECT_CLICK)
   {
      // ✅ Busca flexível: procura por "_s" ou "Spin"
      if(StringFind(sparam, "_s") >= 0 || StringFind(sparam, "Spin") >= 0 || StringFind(sparam, m_name) >= 0)
      {
         Print("✅ [PAINEL] SpinEdit alterado! sparam='", sparam, "'");
         
         // Atualizar variáveis globais
         g_MinRange       = (int)m_spns[0].Value();
         g_MaxRange       = (int)m_spns[1].Value();
         g_HighLowFilter  = (int)m_spns[2].Value();
         g_MaxHistoryBars = (int)m_spns[3].Value();
         g_StopPips       = (int)m_spns[4].Value();

         // Validar Min/Max
         if(g_MaxRange < g_MinRange)
         {
            g_MaxRange = g_MinRange;
            m_spns[1].Value(g_MaxRange);
         }

         Print("📊 Painel: Min=", g_MinRange, " Max=", g_MaxRange);

         // Disparar evento
         EventChartCustom(ChartID(), 1001, 0, 0, "");
         
         return true;
      }
   }
   
   return handled;
}
/*
bool CALXPanel::OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   bool handled = CAppDialog::OnEvent(id, lparam, dparam, sparam);

   // ✅ Aceitar múltiplos tipos de evento
   if(id == CHARTEVENT_OBJECT_ENDEDIT || 
      id == CHARTEVENT_OBJECT_CHANGE ||
      id == CHARTEVENT_OBJECT_CLICK)
   {
      // ✅ Busca flexível: procura por "_s" ou "Spin"
      if(StringFind(sparam, "_s") >= 0 || StringFind(sparam, "Spin") >= 0 || StringFind(sparam, m_name) >= 0)
      {
         Print("✅ [PAINEL] SpinEdit alterado! sparam='", sparam, "'");
         
         // Atualizar variáveis globais
         g_MinRange       = (int)m_spns[0].Value();
         g_MaxRange       = (int)m_spns[1].Value();
         g_HighLowFilter  = (int)m_spns[2].Value();
         g_MaxHistoryBars = (int)m_spns[3].Value();
         g_StopPips       = (int)m_spns[4].Value();

         // Validar Min/Max
         if(g_MaxRange < g_MinRange)
         {
            g_MaxRange = g_MinRange;
            m_spns[1].Value(g_MaxRange);
         }

         Print("📊 Painel: Min=", g_MinRange, " Max=", g_MaxRange);

         // Disparar evento
         EventChartCustom(ChartID(), 1001, 0, 0, "");
         
         return true;
      }
   }
   
   return handled;
}

/*
bool CALXPanel::OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   bool handled = CAppDialog::OnEvent(id, lparam, dparam, sparam);

   Print("✅ [PAINEL] SpinEdit alterado! 001...");


   if(id == CHARTEVENT_OBJECT_ENDEDIT || id == CHARTEVENT_OBJECT_CHANGE)
   {
      // ✅ Só processa se for realmente um dos nossos spins
      if(StringFind(sparam, m_name + "_s") >= 0)
      {
      Print("✅ [PAINEL] SpinEdit alterado! 002...");
      
         // Atualizar variáveis globais
         g_MinRange       = (int)m_spns[0].Value();
         g_MaxRange       = (int)m_spns[1].Value();
         g_HighLowFilter  = (int)m_spns[2].Value();
         g_MaxHistoryBars = (int)m_spns[3].Value();
         g_StopPips       = (int)m_spns[4].Value();

         // ✅ Validar relação Min/Max para evitar erro lógico
         if(g_MaxRange < g_MinRange)
         {
            g_MaxRange = g_MinRange;
            m_spns[1].Value(g_MaxRange);  // Atualiza visual também
         }

         Print("🎛️ Painel: Min=", g_MinRange, " Max=", g_MaxRange, " H/L=", g_HighLowFilter);

         // Disparar evento para o indicador
         EventChartCustom(ChartID(), 1001, 0, 0, "");
         
         return true;  // ✅ Marcar como tratado para evitar propagação duplicada
      }
   }
   return handled;
}


/*
bool CALXPanel::OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // MUITO IMPORTANTE: deixa o dialog processar primeiro
   bool handled = CAppDialog::OnEvent(id, lparam, dparam, sparam);

   // Detecta mudança nos spins pelo nome
   if(id == CHARTEVENT_OBJECT_ENDEDIT || id == CHARTEVENT_OBJECT_CHANGE)
   {
      if(StringFind(sparam, "_s") >= 0) // qualquer spin
      {
         g_MinRange        = (int)m_spns[0].Value();
         g_MaxRange        = (int)m_spns[1].Value();
         g_HighLowFilter   = (int)m_spns[2].Value();
         g_MaxHistoryBars  = (int)m_spns[3].Value();
         g_StopPips        = (int)m_spns[4].Value();

         Print("Atualizado via painel: ", g_MinRange);

         EventChartCustom(ChartID(), 1001, 0, 0, "");
      }
   }

   return handled;
}

/*
bool CALXPanel::OnEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CUSTOM + ON_CHANGE)
    {
      g_MinRange        = (int)m_spns[0].Value();
      g_MaxRange        = (int)m_spns[1].Value();
      g_HighLowFilter   = (int)m_spns[2].Value();
      g_MaxHistoryBars  = (int)m_spns[3].Value();
      g_StopPips        = (int)m_spns[4].Value();
      EventChartCustom(ChartID(), 1001, 0, 0, "reset");
    }
   return CAppDialog::OnEvent(id, lparam, dparam, sparam);
}

*/