#!/bin/bash
set -e
echo "[1] TRIAGE"
python3 scripts/verify_release.py || py scripts/verify_release.py || python scripts/verify_release.py
echo "[4] LOCAL TEST"
python3 -m unittest discover -s tests 2>&1 | tail -20 || py -m unittest discover -s tests 2>&1 | tail -20
echo "[5] VERIFY"
bash -n scripts/build.sh && echo "build.sh syntax OK"
