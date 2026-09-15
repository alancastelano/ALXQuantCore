//+------------------------------------------------------------------+
//|                                    MacroOverlayReader.mqh         |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      "https://www.mql5.com"
#property version   "2.00"

class CMacroOverlayReader
{
private:
   string   m_symbol;
   bool     m_loaded;
   bool     m_allow_mr;
   string   m_regime;
   double   m_z_scores[];
   string   m_z_symbols[];
   double   m_corrs[];
   int      m_lags[];
   int      m_count;
   // DNA features
   double   m_dna_values[];
   string   m_dna_keys[];
   int      m_dna_count;

public:
   void Init(string symbol)
   {
      m_symbol = symbol;
      m_loaded = false;
      m_allow_mr = false;
      m_regime = "UNKNOWN";
      m_count = 0;
      m_dna_count = 0;
      ArrayResize(m_z_scores, 0);
      ArrayResize(m_z_symbols, 0);
      ArrayResize(m_corrs, 0);
      ArrayResize(m_lags, 0);
      ArrayResize(m_dna_values, 0);
      ArrayResize(m_dna_keys, 0);
      Load();
   }

   void Load()
   {
      string filename = "macro_overlay_" + m_symbol + ".txt";
      int handle = FileOpen(filename, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(handle == INVALID_HANDLE)
      {
         Print("[OVERLAY] Arquivo nao encontrado: ", filename);
         return;
      }

      while(!FileIsEnding(handle))
      {
         string line = FileReadString(handle);
         if(StringLen(line) == 0) continue;

         int eq = StringFind(line, "=");
         if(eq < 0) continue;

         string key = StringSubstr(line, 0, eq);
         string val = StringSubstr(line, eq + 1);

         if(key == "ALLOW_MR") { m_allow_mr = (val == "1"); }
         else if(key == "REGIME") { m_regime = val; }
         else if(StringFind(key, "DNA_") == 0)
         {
            string dna_key = StringSubstr(key, 4);
            int idx = m_dna_count;
            m_dna_count++;
            ArrayResize(m_dna_values, m_dna_count);
            ArrayResize(m_dna_keys, m_dna_count);
            m_dna_keys[idx] = dna_key;
            m_dna_values[idx] = StringToDouble(val);
         }
         else if(StringFind(key, "Z_") == 0)
         {
            string sym = StringSubstr(key, 2);
            int idx = m_count;
            m_count++;
            ArrayResize(m_z_scores, m_count);
            ArrayResize(m_z_symbols, m_count);
            ArrayResize(m_corrs, m_count);
            ArrayResize(m_lags, m_count);
            m_z_symbols[idx] = sym;
            m_z_scores[idx] = StringToDouble(val);
         }
         else if(StringFind(key, "CORR_") == 0)
         {
            string sym = StringSubstr(key, 5);
            for(int i = 0; i < m_count; i++)
            {
               if(m_z_symbols[i] == sym) { m_corrs[i] = StringToDouble(val); break; }
            }
         }
         else if(StringFind(key, "LAG_") == 0)
         {
            string sym = StringSubstr(key, 4);
            for(int i = 0; i < m_count; i++)
            {
               if(m_z_symbols[i] == sym) { m_lags[i] = (int)StringToInteger(val); break; }
            }
         }
      }
      FileClose(handle);
      m_loaded = true;
      Print("[OVERLAY] Carregado: ", m_count, " macro, ", m_dna_count, " DNA, MR=", m_allow_mr ? "ON" : "OFF");
   }

   bool     IsLoaded()      { return m_loaded; }
   bool     AllowMR()       { return m_allow_mr; }
   string   GetRegime()     { return m_regime; }
   int      Count()         { return m_count; }
   int      CountDNA()      { return m_dna_count; }

   double   GetDNA(string key)
   {
      for(int i = 0; i < m_dna_count; i++)
      {
         if(m_dna_keys[i] == key) return m_dna_values[i];
      }
      return 0.0;
   }

   double   GetZScore(string symbol)
   {
      for(int i = 0; i < m_count; i++)
      {
         if(m_z_symbols[i] == symbol)
            return m_z_scores[i];
      }
      return 0.0;
   }

   double   GetCorr(string symbol)
   {
      for(int i = 0; i < m_count; i++)
      {
         if(m_z_symbols[i] == symbol)
            return m_corrs[i];
      }
      return 0.0;
   }

   int      GetLag(string symbol)
   {
      for(int i = 0; i < m_count; i++)
      {
         if(m_z_symbols[i] == symbol)
            return m_lags[i];
      }
      return 0;
   }

   double   MacroRiskZ()
   {
      double sum = 0; int n = 0;
      for(int i = 0; i < m_count; i++)
      {
         if(StringFind(m_z_symbols[i], "VIX") >= 0 ||
            StringFind(m_z_symbols[i], "STLFSI4") >= 0 ||
            StringFind(m_z_symbols[i], "NFCI") >= 0)
         {
            sum += MathAbs(m_z_scores[i]);
            n++;
         }
      }
      return (n > 0) ? sum / n : 0.0;
   }

   double   MacroDxyZ()
   {
      for(int i = 0; i < m_count; i++)
      {
         if(m_z_symbols[i] == "DTWEXBGS")
            return m_z_scores[i];
      }
      return 0.0;
   }

   bool     TradeAllowed()
   {
      double risk_z = MacroRiskZ();
      double dxy_z  = MacroDxyZ();
      if(risk_z > 2.0 && dxy_z > 1.5) return false;
      return true;
   }
};
