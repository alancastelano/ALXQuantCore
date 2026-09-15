//+------------------------------------------------------------------+
//|                                                         Core.mqh |
//|                                Copyright 2026, ALXQuantCore Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, ALXQuantCore Ltd."
#property link      "https://www.mql5.com"
#property version   "10.00"
#property strict

class CCore
  {
private:

public:
                     CCore();
                    ~CCore();
    ulong   AutoMagicID(string ea_name, string version="1.0");
    string  GenerateRegimeComment();                
                    
  };
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
CCore::CCore()
  {
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
CCore::~CCore()
  {
  }
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Gera Magic Number Único por Conta, Ativo e Timeframe             |
//+------------------------------------------------------------------+
ulong CCore::AutoMagicID(string ea_name, string version="1.0")
{
   // Adicionamos o Account Login para garantir unicidade absoluta entre contas
   ulong accountLogin = (ulong)AccountInfoInteger(ACCOUNT_LOGIN);
   string key = ea_name + "|" + version + "|" + _Symbol + "|" + IntegerToString(_Period) + "|" + IntegerToString(accountLogin);
   
   ulong hash = 5381;
   for(int i = 0; i < StringLen(key); i++)
      hash = ((hash << 5) + hash) + StringGetCharacter(key, i);

   // Mantém o mask 0x7FFFFFFF para garantir que seja um inteiro positivo válido (max ~2.14 bilhões)
   return hash & 0x7FFFFFFF;
}

//+------------------------------------------------------------------+
//| Gera Comentário da Ordem com Dados do Regime (Anti-Compliance)   |
//+------------------------------------------------------------------+
string CCore::GenerateRegimeComment()
{
   // 1. Sufixo único da conta (últimos 4 dígitos do login)
   ulong accLogin = AccountInfoInteger(ACCOUNT_LOGIN);
   int uniqueSuffix = (int)(accLogin % 9999);
   
   // 2. Obter dados do regime no exato momento da entrada
   // NOTA: Substitua 'GetHurst()' e 'GetR2()' pelos nomes reais 
   // dos métodos públicos da sua classe CMacroRegimeEngine
   double hurstVal = m_regime.GetLastHurst();      // Ex: 0.522
   double r2Val    = m_regime.GetConfidence();     // Ex: 0.64
   
   // 3. Formatar para 2 casas decimais (economiza espaço e padroniza)
   string hStr = DoubleToString(hurstVal, 2);
   string rStr = DoubleToString(r2Val, 2);
   
   // 4. Montar string compacta e profissional (Ex: "QFX_H0.52_R20.64_8492")
   // StringFormat é mais seguro e rápido que concatenação com '+'
   return StringFormat("QFX_H%s_R%s_%04d", hStr, rStr, uniqueSuffix);
}

