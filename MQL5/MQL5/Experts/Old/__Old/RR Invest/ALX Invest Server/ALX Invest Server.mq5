//+------------------------------------------------------------------+
//|                                            ALX Invest Server.mq5 |
//|                                      Copyright 2022, ALX Invest. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2022, ALX Invest."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include "socketlib.mqh"

//+------------------------------------------------------------------+
//| #inputs                                                          |
//+------------------------------------------------------------------+
input string Host    =  "127.0.0.1";   // Host
input ushort Port    =  8888;          // Porta
input int    Time    =  30;            // Tempo entre mensagens (segundos)
input bool   debug   =  false;         // Modo debug
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| #Variaveis                                                       |
//+------------------------------------------------------------------+
//-- AMERICAS
double US500 = 0.0;     //-- S&P500
double US100 = 0.0;     //-- NASDAQ
double US30  = 0.0;     //-- DOW JONES
double IBOV  = 0.0;     //-- BOVESPA

//-- EUROPA
double DAX30 = 0.0;     //-- DAX
double EUR50 = 0.0;     //-- EUR50

//-- ASIA
double HSI   = 0.0;     //-- Hang Seng
double N225  = 0.0;     //-- Japan Nikkei
double ASX200 = 0.0;    //-- Sydnei

//-- INDICES
double VIX   = 0.0;     //-- VIX
double DXY   = 0.0;     //-- DXY

//-- FUTURES
double us500 = 0.0;  //-- S&P500 Future
double us100 = 0.0;  //-- NASDAQ Future
double us30  = 0.0;  //-- DOW JONES Future
double VI    = 0.0;  //-- VIX Future
double DX    = 0.0;  //-- DXY Future


//+------------------------------------------------------------------+

SOCKET64 client=INVALID_SOCKET64; // client socket
ref_sockaddr srvaddr={};
//------------------------------------------------------------------	OnInit
int OnInit()
  {
// fill the structure for the server address
   char ch[]; StringToCharArray(Host,ch);
   sockaddr_in addrin;
   addrin.sin_family=AF_INET;
   addrin.sin_addr.u.S_addr=inet_addr(ch);
   addrin.sin_port=htons(Port);
   srvaddr.in=addrin;
   
   EventSetTimer(Time);

   return INIT_SUCCEEDED;
  }
//------------------------------------------------------------------	OnDeinit
void OnDeinit(const int reason) { CloseClean(); EventKillTimer();}
//------------------------------------------------------------------	OnTick
void OnTimer()
  {
   US500 = ALXSendServer("US500");
   US100 = ALXSendServer("US100");
   US30  = ALXSendServer("US30");

   Print("\n\n\n####################################");
   Print("Last Update:" + (string)TimeLocal());
   Print("US500: ",(string)US500);
   Print("US100: ",(string)US100);
   Print("US30: " ,(string)US30);
   Print("####################################");
  }


double ALXSendServer(string str)
{
   if(client!=INVALID_SOCKET64) // if the socket is already created, send
     {
      uchar data[];
      StringToCharArray(str, data);
      if(sendto(client,data,ArraySize(data),0,srvaddr.ref,ArraySize(srvaddr.ref))==SOCKET_ERROR)
        {
         int err=WSAGetLastError();
         if(err!=WSAEWOULDBLOCK)
            {
               if(debug)
                  Print("-Send failed error: "+WSAErrorDescript(err));
               CloseClean();
            }
        }
      else
        {
         if(debug)
            Print("send "+str+" to server");

         uchar data_received[];
         if(Receive(data_received)>0) // receive data
           {
               string msg=CharArrayToString(data_received);
               if(debug)
                  printf("received: Symbol:%s, %s",str,msg);
            return(StringToDouble(msg));
           }
        }
     }
   else // create a client socket
     {
      int res=0;
      char wsaData[]; ArrayResize(wsaData,sizeof(WSAData));
      res=WSAStartup(MAKEWORD(2,2),wsaData);

      if(res!=0)
         {
            if(debug)
               Print("-WSAStartup failed error: "+string(res));
              return(NULL);
         }

      // create socket
      client=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);
      if(client==INVALID_SOCKET64)
         {
            if(debug)
               Print("-Create failed error: "+WSAErrorDescript(WSAGetLastError()));
             CloseClean();
             return(NULL);
         }

      // set to nonblocking mode
      int non_block=1;
      res=ioctlsocket(client,(int)FIONBIO,non_block);
      if(res!=NO_ERROR)
         { 
            if(debug)
               Print("ioctlsocket failed error: "+string(res));
               CloseClean();
              return(NULL);
         }

      Print("ALX Server conectado!");
     }

   return(NULL);
}

  
  
//------------------------------------------------------------------	Receive
int Receive(uchar &rdata[]) // Receive until the peer closes the connection
  {
   if(client==INVALID_SOCKET64) return 0; // if the socket is still not open

   char rbuf[512]; int rlen=512; int r=0,res=0;
   do
     {
      res=recv(client,rbuf,rlen,0);
      if(res<0)
        {
         int err=WSAGetLastError();
         if(err!=WSAEWOULDBLOCK) { Print("-Receive failed error: "+string(err)+" "+WSAErrorDescript(err)); CloseClean(); return -1; }
         break;
        }
      if(res==0 && r==0) { Print("-Receive. connection closed"); CloseClean(); return -1; }
      r+=res; ArrayCopy(rdata,rbuf,ArraySize(rdata),0,res);
     }
   while(res>0 && res>=rlen);
   return r;
  }
//------------------------------------------------------------------	CloseClean
void CloseClean() // close socket
  {
   if(client!=INVALID_SOCKET64)
     {
      if(shutdown(client,SD_BOTH)==SOCKET_ERROR) Print("-Shutdown failed error: "+WSAErrorDescript(WSAGetLastError()));
      closesocket(client); client=INVALID_SOCKET64;
     }

   WSACleanup();
   Print("close socket");
  }
//+------------------------------------------------------------------+
