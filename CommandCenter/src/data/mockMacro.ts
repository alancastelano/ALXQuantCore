import type { MacroSnapshot } from '../types';

export const mockMacro: MacroSnapshot = {
  sentiment: 'neutro',
  regions: [
    { code: 'US', label: 'Estados Unidos', sentiment: 'neutro' },
    { code: 'EU', label: 'Zona do Euro', sentiment: 'positivo' },
    { code: 'JP', label: 'Japão', sentiment: 'neutro' },
    { code: 'CN', label: 'China', sentiment: 'negativo' },
  ],
  events: [
    { id: 'ev-1', time: '14:30', title: 'CPI EUA', region: 'US', impact: 'high', status: 'upcoming' },
    { id: 'ev-2', time: '16:00', title: 'Discurso Powell', region: 'US', impact: 'high', status: 'upcoming' },
    { id: 'ev-3', time: '18:00', title: 'Estoque de Petróleo', region: 'US', impact: 'medium', status: 'upcoming' },
    { id: 'ev-4', time: '21:00', title: 'Decisão BoJ', region: 'JP', impact: 'high', status: 'upcoming' },
  ],
};
