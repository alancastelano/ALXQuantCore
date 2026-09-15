//+------------------------------------------------------------------+
//|                                                     Telegram.mqh |
//|                                  Copyright 2025, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//| v10.0.0 |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version "10.0"
/*
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.10.0 - 2026-08-24 - Change: Renumber to major 10 platform alignment.
    v.7.12 - 2026-07-29 - Normalizado para macro v7 release.
    v.7.13 - 2026-08-20 - Fix: emojis reconstruídos (arquivo original
            corrompido para ANSI/Windows-1252, perdendo os caracteres
            UTF-8 dos ícones). Token/chat_id movidos para "input" em vez
            de hardcoded no código-fonte.
            Fix: Startup() agora ENVIA via Send() (antes só montava a
            string e não entregava) e não imprime mais o ruído no log.
            IMPORTANTE: salve este arquivo em UTF-8 no MetaEditor para
            os emojis não corromperem de novo.
    v.7.20 - 2026-08-20 - Add: OrderOpened()/OrderClosed() com dados
            completos de abertura/fechamento (fill, volume, SL/TP, P/L,
            hold time) p/ notificacao de trades do EA QUantFX v3.3.0.
*/

input group    "== Telegram - @ALXFundAletsBot =="
      string   m_token                 = "8230213755:AAFPw1p6WcYMsRxnX01lbcFnmf9-QvpPuW4";
      string   m_chat_id               = "418677499";
input bool     InpTelegram_init        = true;
input bool     InpTelegram_Deinit      = false;
input bool     InpTelegram_orders      = true;
input bool     InpTelegram_modify      = false;
input bool     InpTelegram_pend        = false;
input bool     InpTelegram_dash        = true;

class CTelegram
{
private:
    string m_token;
    string m_chat_id;

    // Função para adicionar sinal + ou - nos números
    string Sgn(double val, int dec=2) { return (val >= 0 ? "+" : "") + DoubleToString(val, dec); }

public:
    // Construtor: Configure aqui ou ao instanciar
    CTelegram(string token, string chat_id)
    {
        m_token = token;
        m_chat_id = chat_id;
    }

      // --- FORMATAR: INICIALIZAÇÃO DO EA ---
      string Startup(string eaName, string vr)
      {
          string m = "🚀 <b>EA INICIALIZADO COM SUCESSO</b> 🚀\n";
          m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
          m += "🤖 <b>Expert:</b> " + eaName + " v" + vr + "\n";
           m += "🏦 <b>Corretora:</b> " + AccountInfoString(ACCOUNT_COMPANY) + "\n";
           m += "🖥 <b>Servidor:</b> " + AccountInfoString(ACCOUNT_SERVER) + "\n"; // Sugestão: Saber se é Real ou Demo
           m += "🆔 <b>Conta:</b> <code>" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) + "</code>\n";
           m += "💰 <b>Saldo:</b> " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
           m += "📊 <b>Alavancagem:</b> 1:" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LEVERAGE)) + "\n"; // Sugestão: Conferir margem
          m += "📅 <b>Data:</b> " + TimeToString(TimeLocal(), TIME_DATE|TIME_SECONDS) + "\n";
          m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
          m += "✅ <i>O sistema já está monitorando o mercado!</i>";

          Send(m);
          return m;
      }


    // --- 1. SINAL DE COMPRA ---
    string FormatBuy(string sym, double price, double sl, double tp)
    {
        string m = "🟢 <b>SINAL DE COMPRA</b> 📈\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "💱 <b>Ativo:</b> " + sym + "\n";
        m += "🎯 <b>Entrada:</b> " + DoubleToString(price, _Digits) + "\n";
        m += "✅ <b>Take Profit:</b> " + (tp > 0 ? DoubleToString(tp, _Digits) : "---") + "\n";
        m += "🛑 <b>Stop Loss:</b> " + (sl > 0 ? DoubleToString(sl, _Digits) : "---") + "\n";
        m += "⏰ <b>Hora:</b> " + TimeToString(TimeCurrent(), TIME_SECONDS);
        return m;
    }

    // --- 2. SINAL DE VENDA ---
    string FormatSell(string sym, double price, double sl, double tp)
    {
        string m = "🔴 <b>SINAL DE VENDA</b> 📉\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "💱 <b>Ativo:</b> " + sym + "\n";
        m += "🎯 <b>Entrada:</b> " + DoubleToString(price, _Digits) + "\n";
        m += "✅ <b>Take Profit:</b> " + (tp > 0 ? DoubleToString(tp, _Digits) : "---") + "\n";
        m += "🛑 <b>Stop Loss:</b> " + (sl > 0 ? DoubleToString(sl, _Digits) : "---") + "\n";
        m += "⚠️ <i>Maneje seu risco!</i>";
        return m;
    }

    // --- 3. RESULTADO (LUCRO/PREJUÍZO) ---
    string FormatResult(double profit, string sym)
    {
        string m;
        if(profit >= 0) {
            m = "🏆 <b>META ATINGIDA!</b> 🎉\n";
            m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
            m += "✅ <b>Resultado:</b> +" + AccountInfoString(ACCOUNT_CURRENCY) + " " + DoubleToString(profit, 2) + "\n";
            m += "💱 <b>Ativo:</b> " + sym + "\n";
            m += "🎯 <i>Hora de fechar o gráfico!</i>";
        } else {
            m = "❌ <b>STOP LOSS ATINGIDO</b> ⚠️\n";
            m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
            m += "📉 <b>Perda:</b> " + DoubleToString(profit, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
            m += "🧘 <i>Mantenha o emocional focado.</i>";
        }
        return m;
    }

    // --- 4. DASHBOARD COMPLETO (ESTATÍSTICAS) ---
    string FormatDashboard()
    {
        double buyVol=0, sellVol=0, buyPL=0, sellPL=0;
        int buyCount=0, sellCount=0;

        int posTotal = PositionsTotal();
        for(int i = 0; i < posTotal; i++)
        {
            ulong ticket = PositionGetTicket(i);
            if(ticket == 0) continue;
            if(!PositionSelectByTicket(ticket)) continue;
            double net = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double vol = PositionGetDouble(POSITION_VOLUME);
            if(ptype == POSITION_TYPE_BUY)  { buyCount++; buyVol += vol; buyPL += net; }
            if(ptype == POSITION_TYPE_SELL) { sellCount++; sellVol += vol; sellPL += net; }
        }

        double wkPL=0, mtPL=0, gProfit=0, gLoss=0, maxDD=0, peak=AccountInfoDouble(ACCOUNT_BALANCE);
        int wins=0, losses=0, streaks=0, lastRes=-1;
        datetime wkS = TimeCurrent()-(86400*7), mtS = TimeCurrent()-(86400*30);

        HistorySelect(0, TimeCurrent());
        int dealTotal = HistoryDealsTotal();
        for(int i = dealTotal - 1; i >= 0; i--)
        {
            ulong ticket = HistoryDealGetTicket(i);
            if(ticket == 0) continue;
            long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
            if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) continue;
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            double swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
            double net = profit + commission + swap;
            datetime closeTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
            if(closeTime == 0) continue;
            if(closeTime >= wkS) wkPL += net;
            if(closeTime >= mtS) mtPL += net;
            if(net >= 0) { gProfit += net; wins++; if(lastRes<=0) streaks++; lastRes=1; }
            else { gLoss += MathAbs(net); losses++; if(lastRes>=1) streaks++; lastRes=0; }
            double bal = AccountInfoDouble(ACCOUNT_BALANCE);
            if(bal > peak) peak = bal;
            if((peak - bal) > maxDD) maxDD = (peak - bal);
        }

        double pf = (gLoss>0) ? gProfit/gLoss : gProfit;
        double rrr = (losses>0 && wins>0) ? (gProfit/wins)/(gLoss/losses) : 0;

        string m = "📊 <b>PAINEL DE CONTROLE</b>\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "📈 <b>POSIÇÕES ABERTAS</b>\n";
        m += "🟢 Compras: " + (string)buyCount + " (" + DoubleToString(buyVol,2) + ")\n";
        m += "🔴 Vendas:  " + (string)sellCount + " (" + DoubleToString(sellVol,2) + ")\n";
        m += "💰 <b>PL: " + Sgn(buyPL+sellPL) + " (" + DoubleToString(((buyPL+sellPL)/AccountInfoDouble(ACCOUNT_BALANCE))*100, 2) + "%)</b>\n\n";
        m += "📐 Profit Factor: <code>" + DoubleToString(pf, 2) + "</code>\n";
        m += "⚖️ RRR Médio: <code>" + DoubleToString(rrr, 2) + "</code>\n";
        m += "📉 Max DD: <code>" + DoubleToString(maxDD, 2) + "</code>\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "🟢 <i>Status: Operacional</i> ✅";
        return m;
    }

    // --- O MOTOR DE ENVIO (Sincronizado com o seu script funcional) ---
    void Send(string msg)
    {
        string url = "https://api.telegram.org/bot" + m_token + "/sendMessage";
        string params = "chat_id=" + m_chat_id + "&parse_mode=HTML&text=" + msg;

        char data[], result[];
        string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
        string result_headers;

        int len = StringToCharArray(params, data, 0, WHOLE_ARRAY, CP_UTF8);
        if(len > 0) ArrayResize(data, len - 1);

        int res = WebRequest("POST", url, headers, 5000, data, result, result_headers);

        if(res != 200)
            Print("❌ Erro Classe Telegram: ", res, " Erro MT4: ", GetLastError());
    }

    // --- WRAPPER: Shutdown ---
    string Shutdown(string eaName, string version, int reasonCode)
    {
        string reasonText;
        switch(reasonCode)
        {
            case REASON_REMOVE:      reasonText = "EA removido do grafico"; break;
            case REASON_CHARTCLOSE:  reasonText = "Grafico fechado"; break;
            case REASON_CHARTCHANGE: reasonText = "Ativo/Timeframe alterado"; break;
            case REASON_ACCOUNT:     reasonText = "Conta trocada"; break;
            case REASON_CLOSE:       reasonText = "Terminal fechado"; break;
            default:                 reasonText = "Outro motivo (" + (string)reasonCode + ")"; break;
        }
        string m = "🔴 <b>EA ENCERRADO / DESATIVADO</b> 🔴\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "🤖 <b>Expert:</b> " + eaName + " v" + version + "\n";
        m += "🏦 <b>Corretora:</b> " + AccountInfoString(ACCOUNT_COMPANY) + "\n";
        m += "🆔 <b>Conta:</b> <code>" + IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) + "</code>\n";
        m += "💰 <b>Saldo Final:</b> " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + "\n";
        m += "📝 <b>Motivo:</b> " + reasonText + "\n";
        m += "📅 <b>Data:</b> " + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "🛑 <i>O sistema parou de monitorar este ativo.</i>";
        Send(m);
        return m;
    }

    // --- WRAPPER: Buy ---
    string Buy(string sym, double price, double sl, double tp)
    {
        string m = FormatBuy(sym, price, sl, tp);
        Send(m);
        return m;
    }

    // --- WRAPPER: Sell ---
    string Sell(string sym, double price, double sl, double tp)
    {
        string m = FormatSell(sym, price, sl, tp);
        Send(m);
        return m;
    }

    // --- WRAPPER: Result ---
    string Result(double profit, string sym)
    {
        string m = FormatResult(profit, sym);
        Send(m);
        return m;
    }

    // --- WRAPPER: OrderOpened (abertura real detectada via DEAL_ENTRY_IN) ---
    string OrderOpened(ulong ticket, string sym, string side, double volume,
                       double price, double sl, double tp, datetime t)
    {
        string m = "🟢 <b>ORDEM ABERTA</b> 🟢\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "💱 <b>Ativo:</b> " + sym + "\n";
        m += "📈 <b>Direção:</b> " + side + "\n";
        m += "⚖️ <b>Volume:</b> " + DoubleToString(volume, 2) + "\n";
        m += "🎯 <b>Entrada:</b> " + DoubleToString(price, _Digits) + "\n";
        m += "🛑 <b>SL:</b> " + (sl > 0 ? DoubleToString(sl, _Digits) : "---") + "\n";
        m += "✅ <b>TP:</b> " + (tp > 0 ? DoubleToString(tp, _Digits) : "---") + "\n";
        m += "🆔 <b>Ticket:</b> " + (string)ticket + "\n";
        m += "⏰ <b>Hora:</b> " + TimeToString(t, TIME_DATE|TIME_SECONDS);
        Send(m);
        return m;
    }

    // --- WRAPPER: OrderClosed (fechamento + P/L completo) ---
    string OrderClosed(ulong ticket, string sym, string side, double volume,
                       double openPrice, double closePrice, double netPL,
                       double balance, datetime t, string hold)
    {
        string pct = (balance > 0) ? " (" + DoubleToString(netPL / balance * 100.0, 2) + "%)" : "";
        string m = "🔵 <b>ORDEM FECHADA</b> 🔵\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "💱 <b>Ativo:</b> " + sym + "\n";
        m += "📉 <b>Direção:</b> " + side + "\n";
        m += "⚖️ <b>Volume:</b> " + DoubleToString(volume, 2) + "\n";
        m += "🚪 <b>Entrada -> Saída:</b> " + DoubleToString(openPrice, _Digits) + " -> " + DoubleToString(closePrice, _Digits) + "\n";
        m += "💰 <b>P/L:</b> " + Sgn(netPL) + pct + "\n";
        m += "⏱ <b>Hold:</b> " + hold + "\n";
        m += "🆔 <b>Ticket:</b> " + (string)ticket + "\n";
        m += "⏰ <b>Hora:</b> " + TimeToString(t, TIME_DATE|TIME_SECONDS);
        Send(m);
        return m;
    }

    // --- WRAPPER: OrderModified ---
    string OrderModified(int ticket, double oldSL, double newSL)
    {
        string m = "✏️ <b>ORDEM MODIFICADA</b> ✏️\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "🆔 <b>Ticket:</b> " + (string)ticket + "\n";
        m += "📉 <b>SL Antigo:</b> " + DoubleToString(oldSL, _Digits) + "\n";
        m += "📈 <b>SL Novo:</b> " + DoubleToString(newSL, _Digits);
        Send(m);
        return m;
    }

    // --- WRAPPER: PendingOrderModified ---
    string PendingOrderModified(int ticket, double oldP, double newP, double oldSL, double newSL)
    {
        string m = "⏳ <b>PENDENTE MODIFICADA</b> ⏳\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "🆔 <b>Ticket:</b> " + (string)ticket + "\n";
        m += "💲 <b>Preço Antigo:</b> " + DoubleToString(oldP, _Digits) + "\n";
        m += "💲 <b>Preço Novo:</b> " + DoubleToString(newP, _Digits) + "\n";
        m += "🛡 <b>SL Antigo:</b> " + DoubleToString(oldSL, _Digits) + "\n";
        m += "🛡 <b>SL Novo:</b> " + DoubleToString(newSL, _Digits);
        Send(m);
        return m;
    }

    // --- WRAPPER: Dashboard ---
    string Dashboard()
    {
        string m = FormatDashboard();
        Send(m);
        return m;
    }

    // --- WRAPPER: Info ---
    void Info(string titulo, string mensagem)
    {
        string m = "ℹ️ <b>" + titulo + "</b>\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += mensagem;
        Send(m);
    }

    // --- WRAPPER: Warning ---
    void Warning(string titulo, string mensagem)
    {
        string m = "⚠️ <b>" + titulo + "</b> ⚠️\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "⚠️ " + mensagem;
        Send(m);
    }

    // --- WRAPPER: Critical ---
    void Critical(string titulo, string mensagem)
    {
        string m = "🚨 <b>" + titulo + "</b> 🚨\n";
        m += "▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬\n";
        m += "🔥 " + mensagem + "\n";
        m += "🕐 " + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
        Send(m);
    }
};