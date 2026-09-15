"""Vulnerable Python module — DANTE test fixture.

Intentionally contains multiple Python rule violations.
"""

import os
import json
from pathlib import Path

# PY-7.5: mutable module-level state
GLOBAL_LIST = []
GLOBAL_DICT = {}


# PY-7.8: missing type hints
def calculate_average(values):
    """Calculate average without type hints."""
    total = 0
    # PY-7.1: bare except
    for v in values:
        try:
            total += v
        except:
            pass
    return total / len(values) if values else 0


# PY-7.2: mutable default arguments
def process_data(items=[], config={}):
    """Process data with mutable defaults."""
    items.append("processed")
    config["status"] = "done"
    return items, config


# PY-7.3: None comparison with ==
def find_item(data, target):
    """Find item with wrong None comparison."""
    result = None
    for item in data:
        if item == None:
            continue
        if item == target:
            result = item
            break
    return result


# PY-7.4: string concatenation in loop
def build_report(lines):
    """Build report with string concat in loop."""
    report = ""
    for line in lines:
        report = report + line + "\n"
    return report


# PY-7.6: missing super().__init__
class CustomAnalyzer:
    """Class without super init."""

    def __init__(self, name):
        self.name = name
        self.results = []

    def analyze(self, data):
        return [d for d in data if d is not None]


# PY-7.7: unreachable code
def check_status(value):
    """Function with unreachable code."""
    if value > 0:
        return "positive"
        print("This is never reached")  # unreachable
    return "non-positive"


# Secret detection fixtures
API_KEY = "sk-1234567890abcdefghijklmnop"  # SEC-01: hardcoded secret
DATABASE_PASSWORD = "super_secret_password_12345"  # SEC-01: hardcoded secret


def connect_to_api():
    """Connect with hardcoded token."""
    token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"  # SEC-01: GitHub token
    url = f"https://api.github.com/repos?token={token}"
    return url
