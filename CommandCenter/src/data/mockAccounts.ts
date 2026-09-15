import type { Account } from '../types';

export const mockAccounts: Account[] = [
  {
    id: 'account-01', name: 'Conta 01', label: 'FX', accentColor: '#22c55e',
    capital: 215480, equity: 218160, dailyPnl: 2680, dailyPnlPercent: 1.24,
    weeklyPnl: 6120, monthlyPnl: 14870, drawdown: 0.87, maxDrawdown: 1.6,
    strategy: 'Trend', mainAsset: 'EURUSD', status: 'online', riskStatus: 'normal',
    positions: [
      { asset: 'EURUSD', side: 'long', size: 2.5, openPrice: 1.0842, pnl: 1840 },
      { asset: 'GBPJPY', side: 'long', size: 1.0, openPrice: 192.44, pnl: 840 },
    ],
    lastUpdate: new Date().toISOString(),
  },
  {
    id: 'account-02', name: 'Conta 02', label: 'Gold', accentColor: '#3b82f6',
    capital: 382620, equity: 390870, dailyPnl: 8250, dailyPnlPercent: 2.16,
    weeklyPnl: 15300, monthlyPnl: 28410, drawdown: 1.21, maxDrawdown: 2.0,
    strategy: 'Breakout', mainAsset: 'XAUUSD', status: 'online', riskStatus: 'normal',
    positions: [
      { asset: 'XAUUSD', side: 'long', size: 3.0, openPrice: 2381.5, pnl: 8250 },
    ],
    lastUpdate: new Date().toISOString(),
  },
  {
    id: 'account-03', name: 'Conta 03', label: 'Indices', accentColor: '#8b5cf6',
    capital: 276340, equity: 279050, dailyPnl: 2710, dailyPnlPercent: 0.98,
    weeklyPnl: 4120, monthlyPnl: 9530, drawdown: 1.06, maxDrawdown: 1.9,
    strategy: 'MeanReversion', mainAsset: 'US30', status: 'online', riskStatus: 'neutral',
    positions: [
      { asset: 'US30', side: 'long', size: 1.2, openPrice: 41220, pnl: 2710 },
    ],
    lastUpdate: new Date().toISOString(),
  },
  {
    id: 'account-04', name: 'Conta 04', label: 'Crypto', accentColor: '#22d3ee',
    capital: 198760, equity: 202400, dailyPnl: 3640, dailyPnlPercent: 1.87,
    weeklyPnl: 5980, monthlyPnl: -3120, drawdown: 1.32, maxDrawdown: 3.8,
    strategy: 'Momentum', mainAsset: 'BTCUSD', status: 'online', riskStatus: 'attention',
    positions: [
      { asset: 'BTCUSD', side: 'long', size: 0.8, openPrice: 97400, pnl: 2910 },
      { asset: 'ETHUSD', side: 'long', size: 4.0, openPrice: 3410, pnl: 730 },
    ],
    lastUpdate: new Date().toISOString(),
  },
  {
    id: 'account-05', name: 'Conta 05', label: 'Prop', accentColor: '#eab308',
    capital: 421900, equity: 428400, dailyPnl: 6500, dailyPnlPercent: 1.56,
    weeklyPnl: 11940, monthlyPnl: 22110, drawdown: 0.92, maxDrawdown: 1.7,
    strategy: 'MultiAsset', mainAsset: 'EURUSD', status: 'online', riskStatus: 'normal',
    positions: [
      { asset: 'EURUSD', side: 'long', size: 4.0, openPrice: 1.0831, pnl: 4200 },
      { asset: 'XAUUSD', side: 'long', size: 1.5, openPrice: 2379.2, pnl: 2300 },
    ],
    lastUpdate: new Date().toISOString(),
  },
  {
    id: 'account-06', name: 'Conta 06', label: 'Swing', accentColor: '#2dd4bf',
    capital: 167320, equity: 168560, dailyPnl: 1240, dailyPnlPercent: 0.74,
    weeklyPnl: -860, monthlyPnl: 3240, drawdown: 1.48, maxDrawdown: 2.6,
    strategy: 'Swing', mainAsset: 'GBPJPY', status: 'online', riskStatus: 'neutral',
    positions: [
      { asset: 'GBPJPY', side: 'short', size: 0.8, openPrice: 193.10, pnl: 1240 },
    ],
    lastUpdate: new Date().toISOString(),
  },
  {
    id: 'account-07', name: 'Conta 07', label: 'Scalping', accentColor: '#e879f9',
    capital: 243870, equity: 247110, dailyPnl: 3240, dailyPnlPercent: 1.33,
    weeklyPnl: 7810, monthlyPnl: 16420, drawdown: 1.10, maxDrawdown: 2.2,
    strategy: 'Scalping', mainAsset: 'BTCUSD', status: 'online', riskStatus: 'elevated',
    positions: [
      { asset: 'BTCUSD', side: 'long', size: 0.4, openPrice: 97820, pnl: 1980 },
      { asset: 'SOLUSD', side: 'long', size: 12.0, openPrice: 214.6, pnl: 1260 },
    ],
    lastUpdate: new Date().toISOString(),
  },
  {
    id: 'account-08', name: 'Conta 08', label: 'Especial', accentColor: '#ef4444',
    capital: 189450, equity: 188640, dailyPnl: -810, dailyPnlPercent: -0.42,
    weeklyPnl: -2140, monthlyPnl: 1980, drawdown: 1.76, maxDrawdown: 4.1,
    strategy: 'Experimental', mainAsset: 'XRPUSD', status: 'online', riskStatus: 'critical',
    positions: [
      { asset: 'XRPUSD', side: 'long', size: 5000, openPrice: 2.92, pnl: -810 },
    ],
    lastUpdate: new Date().toISOString(),
  },
  {
    id: 'account-09', name: 'Conta 09', label: 'Reserva', accentColor: '#6b7280',
    capital: 90000, equity: 90000, dailyPnl: 0, dailyPnlPercent: 0,
    weeklyPnl: 0, monthlyPnl: 0, drawdown: 0, maxDrawdown: 0,
    strategy: 'Standby', mainAsset: 'EURUSD', status: 'offline', riskStatus: 'neutral',
    positions: [],
    lastUpdate: new Date().toISOString(),
  },
];
