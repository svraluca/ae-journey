Use the existing checkout at `/workspace/ae-journey`. Each cloud task is already isolated; do not create a Git worktree unless the user requests one.

Dependencies and SDKs are retained under `/workspace/tooling`. Run `bash /workspace/ae-journey/scripts/setup-cloud.sh` if they are missing or need to be restored. It verifies the pinned Flutter commit, the Node archive checksum, and both dependency lockfiles.

Activate the tools for each new shell:

```sh
export PATH=/workspace/tooling/flutter/bin:/workspace/tooling/node-v20.20.2-linux-x64/bin:$PATH
export PUB_CACHE=/workspace/tooling/pub-cache
export XDG_CONFIG_HOME=/workspace/tooling/xdg-config
export ANALYZER_STATE_LOCATION_OVERRIDE=/workspace/tooling/dart-analyzer-state
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
```

The home directory is read-only. Use these cache/state overrides instead of changing `HOME`. The root `.env` asset is an ignored empty local placeholder when credentials are absent; preserve an existing `.env` and never commit its contents.

Start the local Python service in a managed background terminal:

```sh
cd /workspace/ae-journey
bash scripts/start-local-backend.sh
```

That helper uses the clean Python environment and local SQLite state, with Firestore and scheduled refresh disabled. It disables file-based dotenv overrides for this local process so a preserved `.env` cannot override those flags; existing process credentials remain available. Processes do not survive an environment snapshot; start the service again in a new task. Check readiness with a local request to `http://127.0.0.1:8080/health` and assert JSON `ok: true`. The `/price-index` endpoint should accept a Valencia/Botox request with `display_limit: 4` and reject `display_limit: 8` with a validation error for that field. Do not present localhost as a user-facing preview.

For offline checks:

```sh
cd /workspace/ae-journey/python
PYTHONDONTWRITEBYTECODE=1 /workspace/tooling/ae-journey-venv/bin/python -m unittest discover -s tests -v
cd /workspace/ae-journey/functions
npm test
cd /workspace/ae-journey
flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings
flutter test --no-pub --concurrency=1 test/explore_valencia_prices_test.dart test/explore_compare_hybrid_contract_test.dart test/explore_duplicate_verify_test.dart test/explore_extract_performance_test.dart test/explore_source_context_regressions_test.dart test/explore_owned_tariff_context_test.dart
```

No external database or paid provider is required for these checks. Live clinic discovery, Places ratings, Firestore, or deployment needs its actual runtime credentials and network access. Reuse existing secure bindings; inspect names and presence only, and never print values or put them in scripts. If a required provider remains unavailable, identify that operation separately from the tested local workflow. No Firebase or mobile release deployment is part of setup.
