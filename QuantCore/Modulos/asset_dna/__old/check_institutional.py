"""
Verifica se as features institucionais estão funcionando
"""
import sys
import os

# Verificar dependências
deps = {
    'polars': 'Polars (I/O rápido)',
    'numba': 'Numba (kernels JIT)',
    'statsmodels': 'Statsmodels (ADF para FFD dinâmico)',
    'hmmlearn': 'HMMlearn (regimes latentes)',
    'pywt': 'PyWavelets (substituído por Kalman)',
    'scipy': 'SciPy (lfilter, cKDTree para KSG)',
    'joblib': 'Joblib (cache + paralelismo)',
    'bottleneck': 'Bottleneck (rolling otimizado)',
    'tqdm': 'tqdm (barras de progresso)',
    'reportlab': 'ReportLab (PDF)',
    'seaborn': 'Seaborn (gráficos)',
}

print("=" * 70)
print("ALXQuant Asset DNA v3.0 — Diagnóstico de Features Institucionais")
print("=" * 70)

missing = []
for module, desc in deps.items():
    try:
        __import__(module)
        print(f"✅ {module:15} — {desc}")
    except ImportError:
        print(f"❌ {module:15} — NÃO INSTALADO ({desc})")
        missing.append(module)

print("\n" + "=" * 70)
print("Features Institucionais vs Dependências:")
print("=" * 70)

features = {
    'FFD Dinâmico (busca d ótimo via ADF)': 'statsmodels' in missing,
    'DFA Hurst (Detrended Fluctuation)': 'numba' in missing,
    'Filtro de Kalman (causal)': False,  # numpy apenas
    'Transfer Entropy KSG (contínuo)': 'scipy' in missing,
    'Cointegração Johansen': 'statsmodels' in missing,
    'HMM com 5 features': 'hmmlearn' in missing,
    'CPCV + PBO Score': False,
}

for feature, blocked in features.items():
    status = "🚫 BLOQUEADO" if blocked else "✅ OK"
    print(f"{status} — {feature}")

print("\n" + "=" * 70)

if missing:
    print(f"\n⚠️  Dependências faltando: {', '.join(missing)}")
    print("\nInstale com:")
    print(f"  pip install {' '.join(missing)}")
    print("\nOu instale tudo de uma vez:")
    print("  pip install polars numba statsmodels hmmlearn scipy joblib bottleneck tqdm reportlab seaborn pydantic-settings")
else:
    print("\n✅ Todas as dependências instaladas!")

print("\n" + "=" * 70)
print("Para forçar recálculo SEM CACHE:")
print("=" * 70)
print("  python profiler_v2.py --symbol XAUUSD --tf M5 --no-cache")
print("\nOu limpe o cache manualmente:")
print("  python -c \"from profiler_v2 import CACHE; CACHE.invalidate()\"")