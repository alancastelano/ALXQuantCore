"""macro_overlay.py — roda 1x/dia, gera overlay macro para EA MQL5"""
import json
import logging
import sys
from pathlib import Path

# Adicionar path do asset_dna para importar MacroRiskIntegrator
sys.path.insert(0, str(Path(__file__).parent.parent / "asset_dna"))
from asset_dna_full import MacroRiskIntegrator

logger = logging.getLogger(__name__)

DB_PATH = r"C:\ALXQuant\data\macro_state.duckdb"
OUTPUT_DIR = Path(r"C:\ALXQuant\MQL5\MQL5\Files")
PROFILE_DIR = Path(r"C:\ALXQuant\data\mql5")


def compute_daily_overlay(symbol: str, tf: str = 'M5') -> dict | None:
    profile_path = PROFILE_DIR / f"asset_profile_{symbol}_{tf}.json"
    if not profile_path.exists():
        logger.warning(f"[OVERLAY] Profile nao encontrado: {profile_path}")
        return None

    profile = json.loads(profile_path.read_text(encoding='utf-8'))
    priority_drivers = profile.get('macro_priority_drivers', {})
    if not priority_drivers:
        logger.warning(f"[OVERLAY] Sem priority_drivers no profile de {symbol}")
        return None

    mi = MacroRiskIntegrator(db_path=DB_PATH)
    macro_wide = mi.load()
    if macro_wide.empty:
        logger.warning("[OVERLAY] Macro data vazio")
        return None

    overlay = {}
    for sym, hist in priority_drivers.items():
        if sym not in macro_wide.columns:
            continue
        series = macro_wide[sym].dropna()
        if len(series) < 30:
            continue
        window = series.tail(252)  # 1 ano
        z = (series.iloc[-1] - window.mean()) / window.std() if window.std() > 0 else 0.0
        overlay[sym] = {
            'z_score': round(float(z), 3),
            'hist_corr_close_ret': hist.get('corr_close_ret'),
            'best_lag_days': hist.get('best_lag_days', 0),
        }

    if not overlay:
        return None

    output = {
        'symbol': symbol,
        'timeframe': tf,
        'overlay': overlay,
        'allow_mean_reversion': profile.get('allow_mean_reversion', False),
        'regime_score': profile.get('dominant_regime', 'RANGE'),
    }

    # Salvar como KEY=VALUE para MQL5
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUTPUT_DIR / f"macro_overlay_{symbol}.txt"
    lines = [f"SYMBOL={symbol}"]
    lines.append(f"TIMEFRAME={tf}")
    lines.append(f"ALLOW_MR={'1' if output['allow_mean_reversion'] else '0'}")
    lines.append(f"REGIME={output['regime_score']}")
    for sym_data, data in overlay.items():
        lines.append(f"Z_{sym_data}={data['z_score']}")
        lines.append(f"CORR_{sym_data}={data['hist_corr_close_ret']}")
        lines.append(f"LAG_{sym_data}={data['best_lag_days']}")
    out_path.write_text('\n'.join(lines), encoding='utf-8')
    logger.info(f"[OVERLAY] Exportado: {out_path}")

    # Tambem salvar JSON completo
    json_path = OUTPUT_DIR / f"macro_overlay_{symbol}.json"
    json_path.write_text(json.dumps(output, indent=2, ensure_ascii=False), encoding='utf-8')

    return output


if __name__ == '__main__':
    sym = sys.argv[1] if len(sys.argv) > 1 else 'XAUUSD'
    tf = sys.argv[2] if len(sys.argv) > 2 else 'M5'
    result = compute_daily_overlay(sym, tf)
    if result:
        print(json.dumps(result, indent=2))
    else:
        print("Falha ao gerar overlay")
