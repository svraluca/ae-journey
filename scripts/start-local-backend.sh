#!/usr/bin/env bash
set -euo pipefail
cd /workspace/ae-journey/python
mkdir -p /workspace/state/ae-journey
export PYTHON_DOTENV_DISABLED=1
export ENABLE_FIRESTORE=false
export ENABLE_BACKGROUND_REFRESH=false
export EXPLORE_JOB_DB=/workspace/state/ae-journey/explore-jobs.sqlite3
export PYTHONDONTWRITEBYTECODE=1
exec /workspace/tooling/ae-journey-venv/bin/python -m uvicorn \
  aesthetic_price_discovery_v11_67:app --host 127.0.0.1 --port 8080
