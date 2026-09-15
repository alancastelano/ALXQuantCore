//+------------------------------------------------------------------+
//|                                                      Clogger.mqh |
//|                                                             ProF |
//|                                                          http:// |
//+------------------------------------------------------------------+
#property copyright "ProF"
#property link      "http://"

// Cache max size (number of files)
#define MAX_CACHE_SIZE	 10000
// Max file size in megabytes
#define MAX_FILE_SIZEMB	10
//+------------------------------------------------------------------+
//|   Logger                                                         |
//+------------------------------------------------------------------+
class CLogger
  {
private:
   string            project,file;              // Name of project and log file
   string            logCache[MAX_CACHE_SIZE];  // Cache max size
   int               sizeCache;                 // Cache counter
   int               cacheTimeLimit;            // Caching time
   datetime          cacheTime;                 // Time of cache last flush into file
   int               handleFile;                // Handle of log file
   string            defCategory;               // Default category
   void              writeLog(string log_msg);  // Writing message into log or file, and flushing cache
public:
   void              CLogger(void){cacheTimeLimit=0; cacheTime=0; sizeCache=0;};// Constructor
   void             ~CLogger(void){};           // Destructor
   void              SetSetting(string project,string file_name,
                                string default_category="",int cache_time_limit=0);                // Settings
   void              init();                    // Initialization, open file for writing
   void              deinit();                  // Deinitialization, closing file
   void              write(string msg,string category="");                                         // Generating message
   void              write(string msg,string category,color colorOfMsg,string file="",int line=0); // Generating message
   void              write(string msg,string category,uchar red,uchar green,uchar blue,
                           string file="",int line=0);                                             // Generating message
   void              flush(void);               // Flushing cache into file

  };
//+------------------------------------------------------------------+
//|  Settings                                                        |
//+------------------------------------------------------------------+
void CLogger::SetSetting(string project_name,string file_name,
                        string default_category="",int cache_time_limit=0)
  {
   project=project_name;            // Project name
   file=file_name;                  // File name
   cacheTimeLimit=cache_time_limit; // Caching time
   if(default_category=="")         // Setting default category
     {  defCategory="Comment";   }
     else
     {defCategory = default_category;}
  }
//+------------------------------------------------------------------+
//|  Initialization                                                  |
//+------------------------------------------------------------------+
void CLogger::init(void)
  {
   string path;
   MqlDateTime date;
   int i=0;
   TimeToStruct(TimeCurrent(),date);                           // Get current time
   
   StringConcatenate(path,"log\\log_",project,"\\log_",file,"_",date.day,date.mon,date.year);             // Generate path and file name

   handleFile=FileOpen(path+".txt",FILE_WRITE|FILE_READ|
                       FILE_UNICODE|FILE_TXT|FILE_SHARE_READ); // Open or create file
   while(FileSize(handleFile)>(MAX_FILE_SIZEMB*1000000))       // Check file size
     {
      // Open or create new log file
      i++;
      FileClose(handleFile);
      handleFile=FileOpen(path+"_"+(string)i+".txt",
                          FILE_WRITE|FILE_READ|FILE_UNICODE|FILE_TXT|FILE_SHARE_READ);
     }
   FileSeek(handleFile,0,SEEK_END);                            // Set pointer to the end of file
  }
//+------------------------------------------------------------------+
//|   Deinitialization                                               |
//+------------------------------------------------------------------+
void CLogger::deinit(void)
  {
   FileClose(handleFile); // Close file
  }
//+------------------------------------------------------------------+
//|   Write message into file of cache                               |
//+------------------------------------------------------------------+
void CLogger::writeLog(string log_msg)
  {
   if(cacheTimeLimit!=0)   // Check if cache is enabled
     {
      if((sizeCache<MAX_CACHE_SIZE-1 && TimeCurrent()-cacheTime<cacheTimeLimit)
         || sizeCache==0)  // Check if cache time is out or if cache limit is reached
        {
         // Write message into cache
         logCache[sizeCache++]=log_msg;
        }
      else
        {
         // Write message into cache and flush cache into file
         logCache[sizeCache++]=log_msg;
         flush();
        }

     }
   else
     {
      // Cache is disabled, immediately write into file
      FileWrite(handleFile,log_msg);
     }
   if(FileTell(handleFile)>(MAX_FILE_SIZEMB*1000000)) // Check current file size
     {
      // File size exceeds allowed limit, close current file and open new one
      deinit();
      init();
     }
  }
//+------------------------------------------------------------------+
//|   Generate message and write into log                            |
//+------------------------------------------------------------------+
void CLogger::write(string msg,string category="")
  {
   string msg_log;
   if(category=="")                 // Check if passed category exists
     {   category=defCategory;   }  // Set default category

   // Generate line and call method to write message
   StringConcatenate(msg_log,category,":|:",TimeToString(TimeCurrent(),TIME_SECONDS),"    ",msg);
   writeLog(msg_log);
  }
//+------------------------------------------------------------------+
//|    Generate message and write into log                           |
//+------------------------------------------------------------------+
void CLogger::write(string msg,string category,color colorOfMsg,string file="",int line=0)
  {
   string msg_log;
   int red,green,blue;
   red=(colorOfMsg  &Red);             // Select red color from constant
   green=(colorOfMsg  &0x00FF00)>>8;   // Select green color from constant
   blue=(colorOfMsg  &Blue)>>16;       // Select blue color from constant
                                       // Check if file or line are passed, generate line and call method of writing message
   if(file!="" && line!=0)
     {
      StringConcatenate(msg_log,category,":|:",red,",",green,",",blue,
                        ":|:",TimeToString(TimeCurrent(),TIME_SECONDS),"    ",
                        "file: ",file,"   line: ",line,"   ",msg);
     }
   else
     {
      StringConcatenate(msg_log,category,":|:",red,",",green,",",blue,
                        ":|:",TimeToString(TimeCurrent(),TIME_SECONDS),"    ",msg);
     }
   writeLog(msg_log);
  }
//+------------------------------------------------------------------+
//|    Generate message and write into log                           |
//+------------------------------------------------------------------+
void CLogger::write(string msg,string category,uchar red,uchar green,uchar blue,string file="",int line=0)
  {
   string msg_log;

   // Check if file or line are passed, generate line and call method of writing message
   if(file!="" && line!=0)
     {
      StringConcatenate(msg_log,category,":|:",red,",",green,",",blue,
                        ":|:",TimeToString(TimeCurrent(),TIME_SECONDS),"    ",
                        "file: ",file,"   line: ",line,"   ",msg);
     }
   else
     {
      StringConcatenate(msg_log,category,":|:",red,",",green,",",blue,
                        ":|:",TimeToString(TimeCurrent(),TIME_SECONDS),"    ",msg);
     }
   writeLog(msg_log);
  }
//+------------------------------------------------------------------+
//|    Flush cache into file                                         |
//+------------------------------------------------------------------+
void CLogger::flush(void)
  {
   for(int i=0;i<sizeCache;i++)  // In loop write all messages into file
     {
      FileWrite(handleFile,logCache[i]);
     }
   sizeCache=0;                  // Reset cache counter
   cacheTime=TimeCurrent();      // Set time of reseting cache
  }
//+------------------------------------------------------------------+
