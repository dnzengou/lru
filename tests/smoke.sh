#!/usr/bin/env bash
# LRU smoke tests — exercise the public entrypoints without long training runs.
set -euo pipefail

cd "$(dirname "$0")/.."
export LRU_BASE_DIR="$(pwd)"
export UNIVERSE_BASE_DIR="$LRU_BASE_DIR"

say() { printf "\n\033[1;36m[smoke]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[fail]\033[0m %s\n" "$*"; exit 1; }

say "shellcheck bash parse"
for f in scripts/*.sh; do
  bash -n "$f" || fail "parse error: $f"
done

say "python compile"
python3 -m py_compile python/neural_mvu.py python/neural_mvu_v2.py

say "go vet + build"
( cd go && go vet ./... && go build -o /tmp/universe-dao-smoke . ) || fail "go build"
rm -f /tmp/universe-dao-smoke

say "shell detection works"
sh scripts/run_universe.sh --help >/dev/null 2>&1 || true

say "state files load as JSON"
for f in universe_state.json dao/dao_state.json evolution/evo_state.json registry/registry.json; do
  [ -f "$f" ] || fail "missing: $f"
  python3 -c "import json,sys; json.load(open('$f'))" || fail "invalid json: $f"
done

say "smoke tests passed"
