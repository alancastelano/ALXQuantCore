//+------------------------------------------------------------------+
//| Version.mqh — ALXQuant Platform Version & Compatibility        |
//| Generated: 2026-08-25 22:16:01 UTC          |
//| Platform: 10.2.0                                       |
//| DO NOT EDIT MANUALLY — generated from manifest.json            |
//+------------------------------------------------------------------+
#property strict
#property version "10.02"

//--- Platform version (3 segments) ---
#define ALX_PLATFORM_VERSION "10.2.0"
#define ALX_PLATFORM_MAJOR 10
#define ALX_PLATFORM_MINOR 2
#define ALX_PLATFORM_PATCH 0

//--- Contract versions ---
#define ALX_CONTRACT_POLICY_BIN_FORMAT_VERSION 10000

//--- Component versions ---
#define ALX_MODULE_MQL5_ALXQUANTCORE_VERSION "10.2.0"
#define ALX_MODULE_MQL5_ALXQUANTSTRATEGY_VERSION "10.0.0"
#define ALX_MODULE_MQL5_ACCOUNTPROTECTOR_VERSION "10.0.0"
#define ALX_MODULE_MQL5_CUSTOMINDICATORS_VERSION "10.0.0"
#define ALX_MODULE_MQL5_DATAMINER_VERSION "10.0.0"
#define ALX_MODULE_MQL5_DESIGN_VERSION "10.0.0"
#define ALX_MODULE_MQL5_EA_QUANTFX_VERSION "10.0.0"
#define ALX_MODULE_MQL5_EA_QUANT_COMMODITIES_VERSION "10.0.0"
#define ALX_MODULE_MQL5_ENUMS_VERSION "10.0.0"
#define ALX_MODULE_MQL5_EXECUTION_VERSION "10.0.1"
#define ALX_MODULE_MQL5_HUMANBEHAVIOR_VERSION "10.0.0"
#define ALX_MODULE_MQL5_IS_GREEN_LAB_VERSION "10.0.0"
#define ALX_MODULE_MQL5_MACROREGIMEENGINE_VERSION "10.1.0"
#define ALX_MODULE_MQL5_MEANREVERSAL_VERSION "10.0.0"
#define ALX_MODULE_MQL5_MEANREVERSALADVANCED_VERSION "10.0.0"
#define ALX_MODULE_MQL5_MEANREVERSALSTRATEGY_VERSION "10.0.0"
#define ALX_MODULE_MQL5_NEWSFILTER_VERSION "10.0.0"
#define ALX_MODULE_MQL5_PANEL_VERSION "10.0.0"
#define ALX_MODULE_MQL5_POLICY_VERSION "10.2.0"
#define ALX_MODULE_MQL5_PORTFOLIORISK_VERSION "10.0.0"
#define ALX_MODULE_MQL5_QUANT_NEWSFILTER_VERSION "10.0.0"
#define ALX_MODULE_MQL5_RANGEBREAKOUT_VERSION "10.0.0"
#define ALX_MODULE_MQL5_RISKMANAGER_VERSION "10.0.0"
#define ALX_MODULE_MQL5_RISKSENTIMENT_VERSION "10.0.0"
#define ALX_MODULE_MQL5_SESSIONBREAKOUT_VERSION "10.0.0"
#define ALX_MODULE_MQL5_SESSIONPROFILE_VERSION "10.0.0"
#define ALX_MODULE_MQL5_STATSTRACKER_VERSION "10.0.0"
#define ALX_MODULE_MQL5_STOPLOSS_VERSION "10.0.0"
#define ALX_MODULE_MQL5_TELEGRAM_VERSION "10.0.0"
#define ALX_MODULE_MQL5_TERMINAL_VERSION "10.0.0"
#define ALX_MODULE_MQL5_TIMEFILTER_VERSION "10.0.0"
#define ALX_MODULE_MQL5_TRAILINGSTOP_VERSION "10.0.0"
#define ALX_MODULE_MQL5_TRENDADAPTATIVE_VERSION "10.0.0"
#define ALX_MODULE_MQL5_TRENDFOLLOWING_VERSION "10.0.0"
#define ALX_MODULE_PYTHON_ALPHA_MINER_VERSION "10.0.0"
#define ALX_MODULE_PYTHON_ASSET_DNA_VERSION "10.3.3"
#define ALX_MODULE_PYTHON_DATAHOUSE_VERSION "10.2.0"
#define ALX_MODULE_PYTHON_POLICY_COMPILER_VERSION "10.1.0"
#define ALX_MODULE_PYTHON_RISK_SENTIMENT_VERSION "10.0.0"

//--- Version compatibility checker ---
class CVersionCheck
{
public:
    // Parse version string 'X.Y.Z' -> (major, minor, patch)
    static bool ParseVersion(const string &ver, int &major, int &minor, int &patch)
    {
        int p1 = StringFind(ver, ".");
        if(p1 < 0) return false;
        int p2 = StringFind(ver, ".", p1 + 1);
        if(p2 < 0) p2 = StringLen(ver);
        major = (int)StringToInteger(StringSubstr(ver, 0, p1));
        minor = (int)StringToInteger(StringSubstr(ver, p1 + 1, p2 - p1 - 1));
        if(p2 < StringLen(ver))
            patch = (int)StringToInteger(StringSubstr(ver, p2 + 1));
        else
            patch = 0;
        return true;
    }

    // Check if version satisfies range spec: '>=10.0.0,<11.0.0'
    static bool CheckRange(const string &current_ver, const string &range_spec, const string &label)
    {
        int c_maj, c_min, c_pat;
        if(!ParseVersion(current_ver, c_maj, c_min, c_pat))
        {
            Print("[VERSION] ", label, ": invalid current version format: ", current_ver);
            return false;
        }
        // Split by comma for multiple constraints
        string specs[];
        int count = StringSplit(range_spec, ',', specs);
        for(int i = 0; i < count; i++)
        {
            string spec = StringTrimLeft(StringTrimRight(specs[i]));
            if(StringLen(spec) == 0) continue;
            // Parse operator + version
            string op = "";
            string ver = "";
            if(StringSubstr(spec, 0, 2) == ">=") { op = ">="; ver = StringSubstr(spec, 2); }
            else if(StringSubstr(spec, 0, 2) == "<=") { op = "<="; ver = StringSubstr(spec, 2); }
            else if(StringSubstr(spec, 0, 1) == ">") { op = ">"; ver = StringSubstr(spec, 1); }
            else if(StringSubstr(spec, 0, 1) == "<") { op = "<"; ver = StringSubstr(spec, 1); }
            else if(StringSubstr(spec, 0, 1) == "=") { op = "=="; ver = StringSubstr(spec, 1); }
            else { op = "=="; ver = spec; }
            int r_maj, r_min, r_pat;
            if(!ParseVersion(ver, r_maj, r_min, r_pat))
            {
                Print("[VERSION] ", label, ": invalid range spec: ", spec);
                return false;
            }
            bool ok = false;
            if(op == ">=") ok = (c_maj > r_maj) || (c_maj == r_maj && c_min > r_min) || (c_maj == r_maj && c_min == r_min && c_pat >= r_pat);
            else if(op == ">") ok = (c_maj > r_maj) || (c_maj == r_maj && c_min > r_min) || (c_maj == r_maj && c_min == r_min && c_pat > r_pat);
            else if(op == "<=") ok = (c_maj < r_maj) || (c_maj == r_maj && c_min < r_min) || (c_maj == r_maj && c_min == r_min && c_pat <= r_pat);
            else if(op == "<") ok = (c_maj < r_maj) || (c_maj == r_maj && c_min < r_min) || (c_maj == r_maj && c_min == r_min && c_pat < r_pat);
            else if(op == "==") ok = (c_maj == r_maj && c_min == r_min && c_pat == r_pat);
            if(!ok)
            {
                Print("[VERSION] INCOMPATIBLE: ", label, " v", current_ver, " does not satisfy ", spec, " (requires ", range_spec, ")");
                return false;
            }
        }
        return true;
    }

    // Convenience: validate a module against its declared requirement
    static bool ValidateModule(const string &module_name, const string &current_ver, const string &range_spec)
    {
        return CheckRange(current_ver, range_spec, module_name);
    }
};
