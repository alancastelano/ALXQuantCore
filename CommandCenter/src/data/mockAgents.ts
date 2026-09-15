import type { AgentStatus } from '../types';

export const mockAgents: AgentStatus[] = [
  { name: 'MacroRegime', online: true, latencyMs: 12, lastUpdate: new Date().toISOString(), state: 'ok' },
  { name: 'RiskManager', online: true, latencyMs: 15, lastUpdate: new Date().toISOString(), state: 'ok' },
  { name: 'DataHouse', online: true, latencyMs: 22, lastUpdate: new Date().toISOString(), state: 'ok' },
  { name: 'AlphaMiner', online: true, latencyMs: 18, lastUpdate: new Date().toISOString(), state: 'ok' },
  { name: 'Execution', online: true, latencyMs: 14, lastUpdate: new Date().toISOString(), state: 'ok' },
  { name: 'Dashboard', online: true, latencyMs: 20, lastUpdate: new Date().toISOString(), state: 'warning' },
  { name: 'News/NLP', online: true, latencyMs: 16, lastUpdate: new Date().toISOString(), state: 'ok' },
];
