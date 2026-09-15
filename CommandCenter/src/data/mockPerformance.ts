import type { PerformancePoint } from '../types';

/** Gera uma série de 30 pontos diários determinística a partir de uma seed. */
export function buildPerformanceSeries(seed: number, baseEquity: number): PerformancePoint[] {
  const points: PerformancePoint[] = [];
  let value = baseEquity * 0.88;
  const now = Date.now();
  for (let i = 29; i >= 0; i--) {
    const wave = Math.sin((seed + i) * 1.7) * 0.01 + Math.cos((seed + i) * 0.6) * 0.008;
    value = value * (1 + 0.004 + wave);
    points.push({
      timestamp: new Date(now - i * 86400000).toISOString(),
      equity: Math.round(value),
      pnl: Math.round(value * wave),
    });
  }
  points[points.length - 1].equity = baseEquity;
  return points;
}
