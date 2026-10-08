#!/usr/bin/env bash
set -euo pipefail

ae_repo=/workspace/ae-journey
ae_tools=/workspace/tooling
ae_node=node-v20.20.2-linux-x64
ae_flutter_version=3.41.4
ae_flutter_commit=ff37bef603469fb030f2b72995ab929ccfc227f0
ae_flutter="$ae_tools/flutter"
export PUB_CACHE="$ae_tools/pub-cache"
export XDG_CONFIG_HOME="$ae_tools/xdg-config"
export ANALYZER_STATE_LOCATION_OVERRIDE="$ae_tools/dart-analyzer-state"
export CI=true
export FLUTTER_SUPPRESS_ANALYTICS=true
mkdir -p "$ae_tools/pip-cache" "$ae_tools/npm-cache" "$PUB_CACHE" \
  "$XDG_CONFIG_HOME" /workspace/state/ae-journey

if [ ! -x "$ae_tools/ae-journey-venv/bin/python" ]; then
  python3 -m venv "$ae_tools/ae-journey-venv"
fi
"$ae_tools/ae-journey-venv/bin/python" -m pip install \
  --cache-dir "$ae_tools/pip-cache" --disable-pip-version-check \
  -r "$ae_repo/python/requirements.lock"

if [ ! -x "$ae_tools/$ae_node/bin/node" ]; then
  curl --fail --silent --show-error --location \
    "https://nodejs.org/dist/v20.20.2/$ae_node.tar.xz" \
    --output "$ae_tools/$ae_node.tar.xz"
  printf '%s  %s\n' \
    df770b2a6f130ed8627c9782c988fda9669fa23898329a61a871e32f965e007d \
    "$ae_tools/$ae_node.tar.xz" | sha256sum --check
  tar --extract --xz --file "$ae_tools/$ae_node.tar.xz" --directory "$ae_tools"
fi
export PATH="$ae_tools/$ae_node/bin:$PATH"
cd "$ae_repo/functions"
npm ci --cache "$ae_tools/npm-cache" --no-audit --no-fund
"$ae_tools/ae-journey-venv/bin/python" -m pip check
node --version

if [ ! -d "$ae_flutter/.git" ]; then
  if [ -e "$ae_flutter" ]; then
    printf 'Flutter installation path already exists without a Git checkout: %s\n' \
      "$ae_flutter" >&2
    exit 1
  fi
  git clone --depth 1 --branch "$ae_flutter_version" \
    https://github.com/flutter/flutter.git "$ae_flutter"
fi
if [ "$(git -C "$ae_flutter" rev-parse HEAD)" != "$ae_flutter_commit" ]; then
  printf 'Flutter checkout must be version %s at commit %s: %s\n' \
    "$ae_flutter_version" "$ae_flutter_commit" "$ae_flutter" >&2
  exit 1
fi
export PATH="$ae_flutter/bin:$PATH"
cd "$ae_repo"
if [ ! -e .env ] && [ ! -L .env ]; then
  git check-ignore --quiet --no-index .env
  (set -o noclobber; : > .env)
fi
flutter --version
flutter pub get --enforce-lockfile
