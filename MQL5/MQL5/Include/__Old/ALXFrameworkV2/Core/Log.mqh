//+------------------------------------------------------------------+
//|                                                          Log.mqh |
//|                                  Copyright 2023, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#define MAX_CACHE_SIZE	   10000 // Cache max size (number of files)
#define MAX_FILE_SIZEMB	   10    // Max file size in megabytes

enum LOG_TYPE
  {
   LOG_INFO=0,
   LOG_WARNING,
   LOG_ERROR,
   LOG_TRADE
  };

/*
   - System
   - Trade
   - Error
*/

class CLog
  {
private:
   string            project,file;              // Name of project and log file
   string            logCache[MAX_CACHE_SIZE];  // Cache max size
   int               sizeCache;                 // Cache counter
   int               cacheTimeLimit;            // Caching time
   datetime          cacheTime;                 // Time of cache last flush into file
   int               handleFile;                // Handle of log file
   string            defCategory;               // Default category
   
   
   void  writeLog(string log_msg);
   void  flush(void);


public:
                     CLog() { cacheTimeLimit=0; cacheTime=0; sizeCache=0;};

      void init(void);
      void write(LOG_TYPE category,string msg,string value);


  };

      //Comment:|:222,222,222:|:23:59:59    file: testlogger.mq5   line: 39   log:


void CLog::write(LOG_TYPE category,string msg,string value)
  {
   string msg_cat;
   string msg_log;
   if(category==LOG_INFO)     { msg_cat="Information";  } 
   if(category==LOG_WARNING)  { msg_cat="Warning";      } 
   if(category==LOG_ERROR)    { msg_cat="Error";        } 
   if(category==LOG_TRADE)    { msg_cat="Trade";        } 

   StringConcatenate(msg_log,msg_cat,":|:",TimeToString(TimeCurrent(),TIME_SECONDS),"    ",msg,"    ",value);
   writeLog(msg_log);
  }
//+------------------------------------------------------------------+
//|  Initialization                                                  |
//+------------------------------------------------------------------+
void CLog::init(void)
  {
   project = "ALXBot";                          // Project name
   file    = MQLInfoString(MQL_PROGRAM_NAME);   // File name
   cacheTimeLimit = 0;                         // Caching time

   string path;
   MqlDateTime date;
   int i=0;
   TimeToStruct(TimeCurrent(),date);                                                            // Get current time
   StringConcatenate(path,"log\\log_",project,"\\log_",file,"_",date.day,"_",date.mon,"_",date.year);   // Generate path and file name
  
   handleFile=FileOpen(path+".txt",FILE_WRITE|FILE_READ|FILE_UNICODE|FILE_TXT|FILE_SHARE_READ); // Open or create file
   while(FileSize(handleFile)>(MAX_FILE_SIZEMB*1000000))                                        // Check file size
     {
      // Open or create new log file
      i++;
      FileClose(handleFile);
      handleFile=FileOpen(path+"_"+(string)i+".txt",FILE_WRITE|FILE_READ|FILE_UNICODE|FILE_TXT|FILE_SHARE_READ);
     }
   FileSeek(handleFile,0,SEEK_END);                            // Set pointer to the end of file
  }

//+------------------------------------------------------------------+
//|   Write message into file of cache                               |
//+------------------------------------------------------------------+
void CLog::writeLog(string log_msg)
  {
   if(cacheTimeLimit!=0)   // Check if cache is enabled
     {
      if((sizeCache<MAX_CACHE_SIZE-1 && TimeCurrent()-cacheTime<cacheTimeLimit) || sizeCache==0)  // Check if cache time is out or if cache limit is reached
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
      flush();
      FileClose(handleFile);
     }
  }
  
//+------------------------------------------------------------------+
//|    Flush cache into file                                         |
//+------------------------------------------------------------------+
void CLog::flush(void)
  {
   for(int i=0;i<sizeCache;i++)  // In loop write all messages into file
     {
      FileWrite(handleFile,logCache[i]);
     }
   sizeCache=0;                  // Reset cache counter
   cacheTime=TimeCurrent();      // Set time of reseting cache
  }
//+------------------------------------------------------------------+
  