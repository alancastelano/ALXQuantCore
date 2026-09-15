#!/usr/bin/env python
"""Diagnose miner.csv structure and row issues."""

import csv
import argparse
from pathlib import Path
from collections import Counter

parser = argparse.ArgumentParser(description='Diagnose a miner CSV file')
parser.add_argument('--csv', default=r'C:\ALXQuant\data\miner\Ghost_v2_XAUUSD_miner.csv',
                    help='CSV file to diagnose')
args = parser.parse_args()

p = Path(args.csv)
print(f"File exists: {p.exists()}")

text = p.read_text('utf-8-sig')
text_lines = [l for l in text.splitlines() if l.strip()]
print(f"\nText lines (splitlines): {len(text_lines)}")
print(f"Unique exact lines: {len(set(text_lines))}")

with p.open('r', encoding='utf-8-sig', newline='') as f:
    reader = csv.reader(f, delimiter=';', quotechar='"')
    csv_rows = list(reader)

print(f"\nCSV parser rows: {len(csv_rows)}")

row_col_counts = [len(r) for r in csv_rows]
print(f"\nColumn count stats:")
print(f"  Min: {min(row_col_counts)}")
print(f"  Max: {max(row_col_counts)}")
print(f"  Mode: {Counter(row_col_counts).most_common(3)}")

bad_rows = [(i, len(r), r) for i, r in enumerate(csv_rows) if len(r) != 107]
print(f"\nRows with != 97 columns: {len(bad_rows)}")
if bad_rows:
    print("  First 5 bad rows:")
    for i, cols, row in bad_rows[:5]:
        print(f"    Row {i}: {cols} cols, {repr(row[:3])}...")

tickets = [r[1] if len(r) > 1 else '' for r in csv_rows]
ticket_counts = Counter(tickets)
print(f"\nTicket analysis:")
print(f"  Total tickets: {len(tickets)}")
print(f"  Unique tickets: {len(ticket_counts)}")
print(f"  Duplicated tickets (count > 1): {sum(1 for c in ticket_counts.values() if c > 1)}")
print(f"  Top duplicated:")
for ticket, cnt in ticket_counts.most_common(10):
    if cnt > 1:
        print(f"    {ticket}: {cnt}x")

EXPECTED_COLS = 107
rows_missing_cols = sum(1 for r in csv_rows if len(r) < EXPECTED_COLS)
print(f"\nRows with < {EXPECTED_COLS} columns: {rows_missing_cols}")

print("\n✓ Diagnostic complete")
