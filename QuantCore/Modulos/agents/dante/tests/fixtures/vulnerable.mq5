//+------------------------------------------------------------------+
//| Vulnerable EA — DANTE test fixture                                |
//| Intentionally contains multiple MQL5 rule violations              |
//+------------------------------------------------------------------+
#property copyright "DANTE Test"
#property version   "1.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

input int MagicNumber = 12345;      // MQL5-6.3: hardcoded magic
input double RiskPercent = 2.0;

CTrade trade;
CPositionInfo position;

int handleATR;
double atrBuffer[];

// MQL5-6.9: direct reference to global without null check
// MQL5-6.14: missing OnDeinit protection

int OnInit()
{
    handleATR = iATR(_Symbol, PERIOD_H1, 14);
    ArraySetAsSeries(atrBuffer, true);
    return(INIT_SUCCEEDED);
}

// MQL5-6.10: commented-out code block
// void OldFunction()
// {
//     Print("This is dead code");
// }

void OnTick()
{
    double vol = 0;  // MQL5-6.1: zeroed inside loop

    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(position.SelectByIndex(i))
        {
            vol = 0;  // MQL5-6.1: reset inside loop
            vol += position.Volume();
        }
    }

    // MQL5-6.2: fixed-size array never populated
    double levels[20];

    // MQL5-6.4: variable not zero-initialized
    int count;
    double avgPrice;

    // MQL5-6.5: division by zero potential
    avgPrice = count / count;

    // MQL5-6.7: OrderSend without return check
    trade.Buy(0.1, _Symbol, 0, 0, 0, "Test order");

    // MQL5-6.8: position count without max limit check
    int total = PositionsTotal();
    if(total > 0)
    {
        Print("Has positions");
    }

    // MQL5-6.12: OnTick + OnTimer with RefreshRates
    RefreshRates();

    // MQL5-6.15: FileOpen inside OnTick
    int handle = FileOpen("log.csv", FILE_WRITE|FILE_CSV);
    if(handle != INVALID_HANDLE)
    {
        FileWrite(handle, TimeToString(TimeCurrent()), vol);
        FileClose(handle);
    }

    // MQL5-6.16: hardcoded API token
    string api_key = "sk-1234567890abcdef1234567890abcdef";

    // MQL5-6.17: API key in WebRequest
    WebRequest("POST", "https://api.example.com/data?key=abcdef1234567890",
               NULL, NULL, NULL, NULL, NULL, 0, NULL, NULL);
}

void OnTimer()
{
    // MQL5-6.13: NewsFilter CSV read without validation
    int handle = FileOpen("calendar.csv", FILE_READ|FILE_CSV);
    string line = FileReadString(handle);
    FileClose(handle);
}
