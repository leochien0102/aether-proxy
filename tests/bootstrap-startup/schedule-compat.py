#!/usr/bin/env python3
"""Legacy B3 compatibility command; schedule/run.sh owns the fixtures and oracles."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
os.chdir(ROOT)
# Replace this process so stdout, stderr, signals and exit status pass through unchanged.
os.execvp('bash', ['bash', str(ROOT / 'tests/schedule/run.sh')])
