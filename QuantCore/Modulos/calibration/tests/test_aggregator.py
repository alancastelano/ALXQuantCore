"""Quick test for dataminer_aggregator with the real CSV files."""

import sys
from pathlib import Path

# Add project root to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from Modulos.calibration.dataminer_aggregator import aggregate


def test_xauusd():
    """Test with the XAUUSD CSV (which actually contains GBPUSD)."""
    csv_path = Path(r"C:\ALXQuant\data\mql5\data_miner_xauusd.csv")
    if not csv_path.exists():
        print(f"SKIP: {csv_path} not found")
        return

    print("=" * 60)
    print("TEST: data_miner_xauusd.csv (unfiltered)")
    print("=" * 60)
    summary = aggregate(csv_path, symbol="", min_sample=2)
    print(f"Total trades: {summary.total_trades}")
    print(f"Date range: {summary.date_range}")
    print(f"Warnings: {summary.warnings}")
    print()

    print("By Regime:")
    for regime, stats in summary.by_regime.items():
        if stats.insufficient_sample:
            print(f"  {regime}: n={stats.n} (insufficient)")
        else:
            print(
                f"  {regime}: n={stats.n}, exp={stats.expectancy_r:.3f}R, "
                f"wr={stats.win_rate:.1%}, p={stats.p_value:.4f}, "
                f"sig={'SIM' if stats.significant_5pct else 'NAO'}"
            )
    print()

    print("By Hurst Bucket:")
    for bucket, stats in summary.by_hurst_bucket.items():
        if stats.insufficient_sample:
            print(f"  {bucket}: n={stats.n} (insufficient)")
        else:
            print(
                f"  {bucket}: n={stats.n}, exp={stats.expectancy_r:.3f}R, "
                f"wr={stats.win_rate:.1%}"
            )
    print()

    print("By Semantic Flag:")
    for flag, stats in summary.by_semantic_flag.items():
        if stats.insufficient_sample:
            print(f"  {flag}: n={stats.n} (insufficient)")
        else:
            exp_str = f"{stats.expectancy_r:.3f}R" if stats.expectancy_r is not None else "N/A"
            print(f"  {flag}: n={stats.n}, exp={exp_str}")
    print()


def test_us30():
    """Test with the US30 CSV."""
    csv_path = Path(r"C:\ALXQuant\data\mql5\data_miner_us30.csv")
    if not csv_path.exists():
        print(f"SKIP: {csv_path} not found")
        return

    print("=" * 60)
    print("TEST: data_miner_us30.csv (filtered to US30)")
    print("=" * 60)
    summary = aggregate(csv_path, symbol="US30", min_sample=5)
    print(f"Total trades: {summary.total_trades}")
    print(f"Date range: {summary.date_range}")
    print()

    print("By Regime:")
    for regime, stats in summary.by_regime.items():
        if stats.insufficient_sample:
            print(f"  {regime}: n={stats.n} (insufficient)")
        else:
            print(
                f"  {regime}: n={stats.n}, exp={stats.expectancy_r:.3f}R, "
                f"wr={stats.win_rate:.1%}, p={stats.p_value:.4f}, "
                f"sig={'SIM' if stats.significant_5pct else 'NAO'}"
            )
    print()

    print("By Hurst Bucket:")
    for bucket, stats in summary.by_hurst_bucket.items():
        if stats.insufficient_sample:
            print(f"  {bucket}: n={stats.n} (insufficient)")
        else:
            print(f"  {bucket}: n={stats.n}, exp={stats.expectancy_r:.3f}R")


if __name__ == "__main__":
    test_xauusd()
    print()
    test_us30()
