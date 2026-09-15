import type { Asset } from '../types';

export const mockAssets: Asset[] = [
  { id: 'EURUSD', symbol: 'EURUSD', change: 66, changePercent: 0.62, trend: 'up', volatility: 'media', state: 'normal', exposedAccounts: ['account-01', 'account-05'], direction: 'long', aggregatePnl: 6040, strategies: ['Trend', 'MultiAsset'] },
  { id: 'XAUUSD', symbol: 'XAUUSD', change: 30.5, changePercent: 1.28, trend: 'up', volatility: 'alta', state: 'attention', exposedAccounts: ['account-02', 'account-05'], direction: 'long', aggregatePnl: 10550, strategies: ['Breakout', 'MultiAsset'] },
  { id: 'GBPJPY', symbol: 'GBPJPY', change: 82, changePercent: 0.43, trend: 'up', volatility: 'media', state: 'normal', exposedAccounts: ['account-01', 'account-06'], direction: 'mixed', aggregatePnl: 2080, strategies: ['Trend', 'Swing'] },
  { id: 'US30', symbol: 'US30', change: 152, changePercent: 0.37, trend: 'up', volatility: 'baixa', state: 'normal', exposedAccounts: ['account-03'], direction: 'long', aggregatePnl: 2710, strategies: ['MeanReversion'] },
  { id: 'BTCUSD', symbol: 'BTCUSD', change: 1090, changePercent: 1.12, trend: 'up', volatility: 'alta', state: 'attention', exposedAccounts: ['account-04', 'account-07'], direction: 'long', aggregatePnl: 4890, strategies: ['Momentum', 'Scalping'] },
  { id: 'ETHUSD', symbol: 'ETHUSD', change: 33.2, changePercent: 0.98, trend: 'up', volatility: 'alta', state: 'neutral', exposedAccounts: ['account-04'], direction: 'long', aggregatePnl: 730, strategies: ['Momentum'] },
  { id: 'SOLUSD', symbol: 'SOLUSD', change: 3.1, changePercent: 1.45, trend: 'up', volatility: 'alta', state: 'elevated', exposedAccounts: ['account-07'], direction: 'long', aggregatePnl: 1260, strategies: ['Scalping'] },
  { id: 'XRPUSD', symbol: 'XRPUSD', change: 0.022, changePercent: 0.76, trend: 'down', volatility: 'alta', state: 'critical', exposedAccounts: ['account-08'], direction: 'long', aggregatePnl: -810, strategies: ['Experimental'] },
];
