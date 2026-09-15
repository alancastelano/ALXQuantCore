//+------------------------------------------------------------------+
//|                                  BrokerQualityAnalyzer.mqh       |
//|                  Análise de Qualidade Multi-Estilo de Trading     |
//|                     VERSÃO CORRIGIDA E OTIMIZADA                  |
//+------------------------------------------------------------------+
#property version "2.03"

//+------------------------------------------------------------------+
//| ENUMS                                                             |
//+------------------------------------------------------------------+
enum ENUM_TRADING_STYLE
{
   STYLE_HFT = 0,
   STYLE_SCALPER = 1,
   STYLE_DAYTRADER = 2,
   STYLE_SWINGTRADER = 3,
   STYLE_POSITION = 4,
   STYLE_INVESTOR = 5
};

enum ENUM_BROKER_GRADE
{
   GRADE_EXCELLENT = 0,
   GRADE_VERY_GOOD = 1,
   GRADE_GOOD = 2,
   GRADE_FAIR = 3,
   GRADE_POOR = 4,
   GRADE_UNSUITABLE = 5
};

enum ENUM_ANOMALY_TYPE
{
   ANOMALY_NONE = 0,
   ANOMALY_LATENCY_SPIKE = 1,
   ANOMALY_SLIPPAGE_SPIKE = 2,
   ANOMALY_SPREAD_SPIKE = 3,
   ANOMALY_DATA_INCONSISTENT = 4,
   ANOMALY_CLOCK_SKEW = 5,
   ANOMALY_NETWORK_LOSS = 6,
   ANOMALY_HIGH_REJECTION_RATE = 7
};

//+------------------------------------------------------------------+
//| ESTRUTURAS                                                        |
//+------------------------------------------------------------------+
struct StyleRequirements
{
   ENUM_TRADING_STYLE style;
   string name;
   double max_latency_p95;
   double max_slippage;
   double max_spread;
   double max_rejection_rate;
   double required_success_rate;
   double max_spread_variance;
};

struct StyleScore
{
   ENUM_TRADING_STYLE style;
   double score;
   ENUM_BROKER_GRADE grade;
   bool is_suitable;
   double latency_fit;
   double slippage_fit;
   double spread_fit;
   double stability_fit;
   string recommendation;
};

struct AnomalyEvent
{
   datetime timestamp;
   ENUM_ANOMALY_TYPE type;
   double value;
   double threshold;
   string description;
   double std_devs_from_mean;
};

struct Statistics
{
   double mean;
   double median;
   double std_dev;
   double min;
   double max;
   double p50;
   double p75;
   double p95;
   double p99;
   long count;
};

//+------------------------------------------------------------------+
//| CLASSE PRINCIPAL                                                  |
//+------------------------------------------------------------------+
class CBrokerQualityAnalyzer
{
private:
   double m_latency_history[];
   double m_slippage_history[];
   double m_spread_history[];
   
   int m_history_index;
   int m_max_history_size;
   int m_current_valid_count;
   
   Statistics m_latency_stats;
   Statistics m_slippage_stats;
   Statistics m_spread_stats;
   
   StyleRequirements m_style_requirements[6];
   StyleScore m_style_scores[6];
   AnomalyEvent m_anomalies[1000];
   int m_anomaly_count;
   
   long m_total_trades;
   long m_total_rejects;
   long m_total_requotes;

   void InitializeStyleRequirements();
   void UpdateStatistics();
   void CalculateStyleScores();
   void DetectAnomalies();
   
   double CalculateStdDev(double &arr[], int count, double mean);
   double CalculatePercentile(double &arr[], int count, double percentile);
   
   ENUM_BROKER_GRADE ScoreToGrade(double score);
   string GetStyleName(ENUM_TRADING_STYLE style);
   void CopyCircularBuffer(const double &source[], double &dest[], int count);

public:
   CBrokerQualityAnalyzer();
   ~CBrokerQualityAnalyzer();
   
   void Init(int history_size = 10000);
   
   void RecordExecution(ulong ticket, 
                       uint request_time_ms, 
                       uint execution_time_ms,
                       double slippage_pips,
                       double spread_pips,
                       bool rejected = false,
                       bool requote = false);
   
   StyleScore GetStyleScore(ENUM_TRADING_STYLE style);
   ENUM_BROKER_GRADE GetStyleGrade(ENUM_TRADING_STYLE style);
   ENUM_TRADING_STYLE GetBestSuitedStyle();
   
   string GetStyleCompatibilityReport();
   string GetDetailedAnalysisReport();
   string GetAnomalyReport();
   string GetBrokerCard();
   
   Statistics GetLatencyStats() { return m_latency_stats; }
   Statistics GetSlippageStats() { return m_slippage_stats; }
   Statistics GetSpreadStats() { return m_spread_stats; }
   double GetOverallScore();
   double GetRejectionRate();
};

//+------------------------------------------------------------------+
//| Construtor                                                        |
//+------------------------------------------------------------------+
CBrokerQualityAnalyzer::CBrokerQualityAnalyzer()
{
   m_max_history_size = 10000;
   m_anomaly_count = 0;
   m_total_trades = 0; 
   m_total_rejects = 0; 
   m_total_requotes = 0;
   m_history_index = 0; 
   m_current_valid_count = 0;
   
   ArrayResize(m_latency_history, m_max_history_size);
   ArrayResize(m_slippage_history, m_max_history_size);
   ArrayResize(m_spread_history, m_max_history_size);
   
   InitializeStyleRequirements();
}

CBrokerQualityAnalyzer::~CBrokerQualityAnalyzer() {}

void CBrokerQualityAnalyzer::Init(int history_size = 10000)
{
   m_max_history_size = history_size;
   ArrayResize(m_latency_history, history_size);
   ArrayResize(m_slippage_history, history_size);
   ArrayResize(m_spread_history, history_size);
}

//+------------------------------------------------------------------+
//| Inicialização de Requisitos (Corrigido sem chaves {})             |
//+------------------------------------------------------------------+
void CBrokerQualityAnalyzer::InitializeStyleRequirements()
{
   // HFT
   m_style_requirements[STYLE_HFT].style = STYLE_HFT;
   m_style_requirements[STYLE_HFT].name = "HFT (Ultra-Fast)";
   m_style_requirements[STYLE_HFT].max_latency_p95 = 1.0;
   m_style_requirements[STYLE_HFT].max_slippage = 0.3;
   m_style_requirements[STYLE_HFT].max_spread = 0.5;
   m_style_requirements[STYLE_HFT].max_rejection_rate = 0.5;
   m_style_requirements[STYLE_HFT].required_success_rate = 99.5;
   m_style_requirements[STYLE_HFT].max_spread_variance = 0.1;
   
   // SCALPER
   m_style_requirements[STYLE_SCALPER].style = STYLE_SCALPER;
   m_style_requirements[STYLE_SCALPER].name = "Scalper (Fast)";
   m_style_requirements[STYLE_SCALPER].max_latency_p95 = 5.0;
   m_style_requirements[STYLE_SCALPER].max_slippage = 0.5;
   m_style_requirements[STYLE_SCALPER].max_spread = 1.0;
   m_style_requirements[STYLE_SCALPER].max_rejection_rate = 1.0;
   m_style_requirements[STYLE_SCALPER].required_success_rate = 99.0;
   m_style_requirements[STYLE_SCALPER].max_spread_variance = 0.3;
   
   // DAY TRADER
   m_style_requirements[STYLE_DAYTRADER].style = STYLE_DAYTRADER;
   m_style_requirements[STYLE_DAYTRADER].name = "Day Trader";
   m_style_requirements[STYLE_DAYTRADER].max_latency_p95 = 50.0;
   m_style_requirements[STYLE_DAYTRADER].max_slippage = 1.0;
   m_style_requirements[STYLE_DAYTRADER].max_spread = 2.0;
   m_style_requirements[STYLE_DAYTRADER].max_rejection_rate = 2.0;
   m_style_requirements[STYLE_DAYTRADER].required_success_rate = 98.0;
   m_style_requirements[STYLE_DAYTRADER].max_spread_variance = 0.5;
   
   // SWING TRADER
   m_style_requirements[STYLE_SWINGTRADER].style = STYLE_SWINGTRADER;
   m_style_requirements[STYLE_SWINGTRADER].name = "Swing Trader";
   m_style_requirements[STYLE_SWINGTRADER].max_latency_p95 = 500.0;
   m_style_requirements[STYLE_SWINGTRADER].max_slippage = 2.0;
   m_style_requirements[STYLE_SWINGTRADER].max_spread = 5.0;
   m_style_requirements[STYLE_SWINGTRADER].max_rejection_rate = 3.0;
   m_style_requirements[STYLE_SWINGTRADER].required_success_rate = 95.0;
   m_style_requirements[STYLE_SWINGTRADER].max_spread_variance = 1.0;
   
   // POSITION TRADER
   m_style_requirements[STYLE_POSITION].style = STYLE_POSITION;
   m_style_requirements[STYLE_POSITION].name = "Position Trader";
   m_style_requirements[STYLE_POSITION].max_latency_p95 = 5000.0;
   m_style_requirements[STYLE_POSITION].max_slippage = 5.0;
   m_style_requirements[STYLE_POSITION].max_spread = 10.0;
   m_style_requirements[STYLE_POSITION].max_rejection_rate = 5.0;
   m_style_requirements[STYLE_POSITION].required_success_rate = 90.0;
   m_style_requirements[STYLE_POSITION].max_spread_variance = 2.0;
   
   // INVESTOR
   m_style_requirements[STYLE_INVESTOR].style = STYLE_INVESTOR;
   m_style_requirements[STYLE_INVESTOR].name = "Investor";
   m_style_requirements[STYLE_INVESTOR].max_latency_p95 = 60000.0;
   m_style_requirements[STYLE_INVESTOR].max_slippage = 10.0;
   m_style_requirements[STYLE_INVESTOR].max_spread = 20.0;
   m_style_requirements[STYLE_INVESTOR].max_rejection_rate = 10.0;
   m_style_requirements[STYLE_INVESTOR].required_success_rate = 80.0;
   m_style_requirements[STYLE_INVESTOR].max_spread_variance = 5.0;
}

//+------------------------------------------------------------------+
//| Registro de Execução                                              |
//+------------------------------------------------------------------+
void CBrokerQualityAnalyzer::RecordExecution(ulong ticket, 
                                             uint request_time_ms, 
                                             uint execution_time_ms,
                                             double slippage_pips,
                                             double spread_pips,
                                             bool rejected = false,
                                             bool requote = false)
{
   double latency_ms = (double)(execution_time_ms - request_time_ms);
   if(latency_ms < 0.1) latency_ms = 0.1;
   
   if(m_history_index >= m_max_history_size) m_history_index = 0;
   
   m_latency_history[m_history_index] = latency_ms;
   m_slippage_history[m_history_index] = MathAbs(slippage_pips);
   m_spread_history[m_history_index] = spread_pips;
   
   m_history_index++;
   if(m_current_valid_count < m_max_history_size) m_current_valid_count++;
   
   m_total_trades++;
   if(rejected) m_total_rejects++;
   if(requote) m_total_requotes++;
   
   if(m_total_trades % 100 == 0)
   {
      UpdateStatistics();
      CalculateStyleScores();
      DetectAnomalies();
   }
}

//+------------------------------------------------------------------+
//| Cópia do Buffer Circular                                          |
//+------------------------------------------------------------------+
void CBrokerQualityAnalyzer::CopyCircularBuffer(const double &source[], double &dest[], int count)
{
   ArrayResize(dest, count);
   int start_idx = m_history_index - count;
   if(start_idx < 0) start_idx += m_max_history_size;
   
   for(int i = 0; i < count; i++)
   {
      int src_idx = (start_idx + i) % m_max_history_size;
      dest[i] = source[src_idx];
   }
   ArraySort(dest);
}

//+------------------------------------------------------------------+
//| Atualização de Estatísticas                                       |
//+------------------------------------------------------------------+
void CBrokerQualityAnalyzer::UpdateStatistics()
{
   int size = m_current_valid_count;
   if(size <= 0) return;
   
   double lat_arr[], slip_arr[], spread_arr[];
   
   CopyCircularBuffer(m_latency_history, lat_arr, size);
   CopyCircularBuffer(m_slippage_history, slip_arr, size);
   CopyCircularBuffer(m_spread_history, spread_arr, size);
   
   // LATÊNCIA
   m_latency_stats.count = size;
   m_latency_stats.min = lat_arr[0];
   m_latency_stats.max = lat_arr[size-1];
   m_latency_stats.p50 = CalculatePercentile(lat_arr, size, 0.50);
   m_latency_stats.p75 = CalculatePercentile(lat_arr, size, 0.75);
   m_latency_stats.p95 = CalculatePercentile(lat_arr, size, 0.95);
   m_latency_stats.p99 = CalculatePercentile(lat_arr, size, 0.99);
   m_latency_stats.median = m_latency_stats.p50;
   
   double sum = 0; for(int i=0; i<size; i++) sum += lat_arr[i];
   m_latency_stats.mean = sum / size;
   m_latency_stats.std_dev = CalculateStdDev(lat_arr, size, m_latency_stats.mean);
   
   // SLIPPAGE
   m_slippage_stats.count = size;
   m_slippage_stats.min = slip_arr[0];
   m_slippage_stats.max = slip_arr[size-1];
   m_slippage_stats.p95 = CalculatePercentile(slip_arr, size, 0.95);
   m_slippage_stats.p99 = CalculatePercentile(slip_arr, size, 0.99);
   m_slippage_stats.median = CalculatePercentile(slip_arr, size, 0.50);
   
   sum = 0; for(int i=0; i<size; i++) sum += slip_arr[i];
   m_slippage_stats.mean = sum / size;
   m_slippage_stats.std_dev = CalculateStdDev(slip_arr, size, m_slippage_stats.mean);
   
   // SPREAD
   m_spread_stats.count = size;
   m_spread_stats.min = spread_arr[0];
   m_spread_stats.max = spread_arr[size-1];
   m_spread_stats.p95 = CalculatePercentile(spread_arr, size, 0.95);
   m_spread_stats.median = CalculatePercentile(spread_arr, size, 0.50);
   
   sum = 0; for(int i=0; i<size; i++) sum += spread_arr[i];
   m_spread_stats.mean = sum / size;
   m_spread_stats.std_dev = CalculateStdDev(spread_arr, size, m_spread_stats.mean);
}

//+------------------------------------------------------------------+
//| Cálculo de Scores                                                 |
//+------------------------------------------------------------------+
void CBrokerQualityAnalyzer::CalculateStyleScores()
{
   double rejection_rate = GetRejectionRate();
   double success_rate = 100.0 - rejection_rate;
   
   for(int i = 0; i < 6; i++)
   {
      StyleRequirements req = m_style_requirements[i];
      StyleScore score;
      score.style = (ENUM_TRADING_STYLE)i;
      
      score.latency_fit = (m_latency_stats.p95 <= req.max_latency_p95) ? 100.0 : 
                          (m_latency_stats.p95 <= req.max_latency_p95 * 2.0) ? 50.0 : 
                          MathMax(0, 100.0 - (m_latency_stats.p95 / req.max_latency_p95 * 50.0));
                          
      score.slippage_fit = (m_slippage_stats.mean <= req.max_slippage) ? 100.0 : 
                           (m_slippage_stats.mean <= req.max_slippage * 1.5) ? 75.0 : 
                           MathMax(0, 100.0 - (m_slippage_stats.mean / req.max_slippage * 50.0));
                           
      score.spread_fit = (m_spread_stats.mean <= req.max_spread) ? 100.0 : 
                         (m_spread_stats.mean <= req.max_spread * 1.5) ? 75.0 : 
                         MathMax(0, 100.0 - (m_spread_stats.mean / req.max_spread * 50.0));
                         
      score.stability_fit = ((rejection_rate <= req.max_rejection_rate) ? 50.0 : 0.0) + 
                            ((success_rate >= req.required_success_rate) ? 50.0 : 0.0);
                            
      score.score = (score.latency_fit * 0.35 + score.slippage_fit * 0.25 + 
                    score.spread_fit * 0.25 + score.stability_fit * 0.15);
                    
      score.is_suitable = (score.score >= 70.0);
      score.grade = ScoreToGrade(score.score);
      
      if(score.score >= 90) score.recommendation = "Excelente para " + req.name;
      else if(score.score >= 70) score.recommendation = "Bom para " + req.name;
      else if(score.score >= 50) score.recommendation = "Marginal para " + req.name;
      else score.recommendation = "Não recomendado";
      
      m_style_scores[i] = score;
   }
}

//+------------------------------------------------------------------+
//| Detecção de Anomalias                                             |
//+------------------------------------------------------------------+
void CBrokerQualityAnalyzer::DetectAnomalies()
{
   if(m_latency_stats.std_dev <= 0) return;
   
   int last_idx = (m_history_index == 0) ? m_max_history_size - 1 : m_history_index - 1;
   double last_lat = m_latency_history[last_idx];
   
   double z_score = (last_lat - m_latency_stats.mean) / m_latency_stats.std_dev;
   
   if(z_score > 3.0 && m_anomaly_count < 1000)
   {
      m_anomalies[m_anomaly_count].timestamp = TimeCurrent();
      m_anomalies[m_anomaly_count].type = ANOMALY_LATENCY_SPIKE;
      m_anomalies[m_anomaly_count].value = last_lat;
      m_anomalies[m_anomaly_count].std_devs_from_mean = z_score;
      m_anomalies[m_anomaly_count].description = "Latency spike detected: " + DoubleToString(last_lat, 2) + "ms";
      m_anomaly_count++;
   }
}

//+------------------------------------------------------------------+
//| Funções Auxiliares                                                |
//+------------------------------------------------------------------+
ENUM_BROKER_GRADE CBrokerQualityAnalyzer::ScoreToGrade(double score)
{
   if(score >= 95) return GRADE_EXCELLENT;
   if(score >= 85) return GRADE_VERY_GOOD;
   if(score >= 70) return GRADE_GOOD;
   if(score >= 50) return GRADE_FAIR;
   if(score >= 30) return GRADE_POOR;
   return GRADE_UNSUITABLE;
}

double CBrokerQualityAnalyzer::CalculateStdDev(double &arr[], int count, double mean)
{
   if(count <= 1) return 0;
   double sum = 0;
   for(int i=0; i<count; i++) { double diff = arr[i] - mean; sum += diff * diff; }
   return MathSqrt(sum / (count - 1));
}

double CBrokerQualityAnalyzer::CalculatePercentile(double &arr[], int count, double percentile)
{
   if(count <= 0) return 0;
   int idx = (int)MathFloor(count * percentile);
   if(idx >= count) idx = count - 1;
   if(idx < 0) idx = 0;
   return arr[idx];
}

double CBrokerQualityAnalyzer::GetRejectionRate()
{
   if(m_total_trades <= 0) return 0;
   return ((double)m_total_rejects / (double)m_total_trades) * 100.0;
}

double CBrokerQualityAnalyzer::GetOverallScore()
{
   double sum = 0;
   for(int i=0; i<6; i++) sum += m_style_scores[i].score;
   return sum / 6.0;
}

string CBrokerQualityAnalyzer::GetStyleName(ENUM_TRADING_STYLE style)
{
   switch(style)
   {
      case STYLE_HFT:       return "HFT (< 1ms)";
      case STYLE_SCALPER:   return "Scalper (< 5ms)";
      case STYLE_DAYTRADER: return "Day Trader (< 50ms)";
      case STYLE_SWINGTRADER: return "Swing Trader (< 500ms)";
      case STYLE_POSITION:  return "Position Trader";
      case STYLE_INVESTOR:  return "Investor";
      default: return "Unknown";
   }
}

//+------------------------------------------------------------------+
//| Relatórios                                                        |
//+------------------------------------------------------------------+
string CBrokerQualityAnalyzer::GetStyleCompatibilityReport()
{
   string report = "\n=== BROKER STYLE COMPATIBILITY MATRIX ===\n";
   report += "Overall Score: " + DoubleToString(GetOverallScore(), 1) + "/100\n";
   report += "Best Suited: " + GetStyleName(GetBestSuitedStyle()) + "\n";
   report += "------------------------------------------\n";
   for(int i=0; i<6; i++)
   {
      StyleScore s = m_style_scores[i];
      string grade = ""; 
      switch(s.grade) 
      { 
         case GRADE_EXCELLENT: grade="A+"; break; 
         case GRADE_VERY_GOOD: grade="A"; break; 
         case GRADE_GOOD: grade="B"; break; 
         case GRADE_FAIR: grade="C"; break; 
         case GRADE_POOR: grade="D"; break; 
         default: grade="F"; 
      }
      string status = s.is_suitable ? "[OK]" : "[X]";
      report += GetStyleName((ENUM_TRADING_STYLE)i) + " -> " + DoubleToString(s.score,1) + "/100 (" + grade + ") " + status + "\n";
   }
   return report;
}

string CBrokerQualityAnalyzer::GetDetailedAnalysisReport()
{
   string report = "\n=== DETAILED BROKER ANALYSIS ===\n";
   report += "LATENCY (ms): Mean=" + DoubleToString(m_latency_stats.mean, 2) + " | P95=" + DoubleToString(m_latency_stats.p95, 2) + " | Max=" + DoubleToString(m_latency_stats.max, 2) + "\n";
   report += "SLIPPAGE (pips): Mean=" + DoubleToString(m_slippage_stats.mean, 2) + " | P95=" + DoubleToString(m_slippage_stats.p95, 2) + "\n";
   report += "SPREAD (pips): Mean=" + DoubleToString(m_spread_stats.mean, 2) + " | Max=" + DoubleToString(m_spread_stats.max, 2) + "\n";
   report += "EXECUTION: Trades=" + IntegerToString(m_total_trades) + " | Rej=" + DoubleToString(GetRejectionRate(), 2) + "%\n";
   return report;
}

string CBrokerQualityAnalyzer::GetAnomalyReport()
{
   return "\nANOMALY REPORT: " + IntegerToString(m_anomaly_count) + " anomalies detected.\n";
}

string CBrokerQualityAnalyzer::GetBrokerCard()
{
   return "\n=== BROKER CARD ===\nGrade: " + GetStyleName(GetBestSuitedStyle()) + "\nScore: " + DoubleToString(GetOverallScore(), 1) + "/100\n";
}

StyleScore CBrokerQualityAnalyzer::GetStyleScore(ENUM_TRADING_STYLE style) 
{ 
   if(style<0||style>5) return m_style_scores[0]; 
   return m_style_scores[style]; 
}

ENUM_BROKER_GRADE CBrokerQualityAnalyzer::GetStyleGrade(ENUM_TRADING_STYLE style) 
{ 
   if(style<0||style>5) return GRADE_UNSUITABLE; 
   return m_style_scores[style].grade; 
}

ENUM_TRADING_STYLE CBrokerQualityAnalyzer::GetBestSuitedStyle()
{
   double best=0; 
   ENUM_TRADING_STYLE best_style=STYLE_INVESTOR;
   for(int i=0; i<6; i++) 
   { 
      if(m_style_scores[i].score > best) 
      { 
         best = m_style_scores[i].score; 
         best_style = (ENUM_TRADING_STYLE)i; 
      } 
   }
   return best_style;
}