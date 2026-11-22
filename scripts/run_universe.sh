#!/usr/bin/env bash
# Run Universe — Full Lifecycle Wrapper v0.4.0
# Detects v8 (optimized) → v7 (stable) → v2.py (Python enhanced)
# Launches the Neural MVU + DAO in sequence
#
# Usage:
#   sh run_universe.sh                  # Full lifecycle
#   sh run_universe.sh --train 100      # Train only
#   sh run_universe.sh --run 50         # Run causally closed
#   sh run_universe.sh --evolve         # DAO evolutionary cycle
#   sh run_universe.sh --status         # Full status
#   sh run_universe.sh --phoenix        # Phoenix Protocol
#   sh run_universe.sh --proposal ...   # DAO proposal
#   sh run_universe.sh --vote ...       # DAO vote
#   sh run_universe.sh --benchmark      # Benchmark v8 (10-step timing)
#   sh run_universe.sh --train-fast N   # Fast batch training (v8 only)

set -e

BASE_DIR="${LRU_BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
MVU_V9="${SCRIPTS_DIR}/neural_mvu_v9.sh"
MVU_V8="${SCRIPTS_DIR}/neural_mvu_v8.sh"
MVU_V7="${SCRIPTS_DIR}/neural_mvu_v7.sh"
MVU_PYTHON="${BASE_DIR}/python/neural_mvu_v2.py"
DAO_SCRIPT="${SCRIPTS_DIR}/dao_engine.sh"

# ─── Detect best available version ────────────────────────────────────────────

detect_mvu() {
  if [ -f "$MVU_V9" ]; then
    echo "$MVU_V9"
  elif [ -f "$MVU_V8" ]; then
    echo "$MVU_V8"
  elif [ -f "$MVU_V7" ]; then
    echo "$MVU_V7"
  elif [ -f "$MVU_PYTHON" ]; then
    echo "$MVU_PYTHON"
  else
    echo ""
  fi
}

MVU_SCRIPT=$(detect_mvu)
MVU_VERSION=""

if echo "$MVU_SCRIPT" | grep -q "v9"; then
  MVU_VERSION="v0.9.0 (latest)"
elif echo "$MVU_SCRIPT" | grep -q "v8"; then
  MVU_VERSION="v0.8.0 (optimized awk)"
elif echo "$MVU_SCRIPT" | grep -q "v7"; then
  MVU_VERSION="v0.7.0 (stable)"
elif echo "$MVU_SCRIPT" | grep -q "v2.py"; then
  MVU_VERSION="v2.0.0 (Python enhanced)"
fi

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║       LOCAL REAL UNIVERSE v0.4.0              ║"
if [ -n "$MVU_VERSION" ]; then
  printf "  ║   Engine: %-34s║\n" "$MVU_VERSION"
fi
echo "  ║   Neural MVU + DAO + Evolutionary Selection   ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

if [ -z "$MVU_SCRIPT" ]; then
  echo "  ❌ No Neural MVU script found!"
  echo "     Expected one of:"
  echo "       - neural_mvu_v8.sh (optimized)"
  echo "       - neural_mvu_v7.sh (stable)"
  echo "       - neural_mvu_v2.py (Python enhanced)"
  exit 1
fi

# ─── Route command ────────────────────────────────────────────────────────────

case "$1" in
  --train)
    shift
    STEPS="${1:-100}"
    echo "  Mode: TRAIN ($STEPS steps)"
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --train "$STEPS"
    else
      sh "$MVU_SCRIPT" --train "$STEPS"
    fi
    ;;
  --train-fast)
    shift
    STEPS="${1:-100}"
    echo "  Mode: FAST BATCH TRAINING ($STEPS steps)"
    if echo "$MVU_SCRIPT" | grep -q "v8"; then
      sh "$MVU_SCRIPT" --train-fast "$STEPS"
    else
      echo "  ⚠️  --train-fast requires v8. Falling back to --train."
      sh "$MVU_SCRIPT" --train "$STEPS"
    fi
    ;;
  --run)
    shift
    STEPS="${1:-50}"
    echo "  Mode: CAUSALLY CLOSED RUN ($STEPS steps)"
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --run "$STEPS"
    else
      sh "$MVU_SCRIPT" --run "$STEPS"
    fi
    ;;
  --all)
    echo "  Mode: FULL LIFECYCLE (train → run → spawn → evolve)"
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --all
    else
      sh "$MVU_SCRIPT" --all
    fi
    echo ""
    sh "$DAO_SCRIPT" --evolve
    ;;
  --evolve)
    echo "  Mode: DAO EVOLUTIONARY CYCLE"
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --evolve
    else
      sh "$DAO_SCRIPT" --evolve
    fi
    ;;
  --status)
    echo "  Mode: FULL STATUS"
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --status
    else
      sh "$MVU_SCRIPT" --verify
    fi
    echo ""
    sh "$DAO_SCRIPT" --status 2>/dev/null || echo "  (DAO engine not available)"
    echo ""
    sh "$DAO_SCRIPT" --check 2>/dev/null || echo "  (Circuit breaker check not available)"
    ;;
  --phoenix)
    echo "  Mode: PHOENIX PROTOCOL"
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --phoenix
    else
      sh "$DAO_SCRIPT" --phoenix 2>/dev/null || {
        echo "  DAO engine not found. Running minimal phoenix..."
        sh "$MVU_SCRIPT" --spawn 2>/dev/null || echo "  Spawned new child as recovery."
      }
    fi
    ;;
  --proposal)
    shift
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --proposal "$@"
    else
      sh "$DAO_SCRIPT" --proposal "$@"
    fi
    ;;
  --vote)
    shift
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --vote "$@"
    else
      sh "$DAO_SCRIPT" --vote "$@"
    fi
    ;;
  --spawn)
    echo "  Mode: SPAWN CHILD"
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --spawn
    else
      sh "$MVU_SCRIPT" --spawn
    fi
    ;;
  --comms)
    shift
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      python3 "$MVU_SCRIPT" --comms "$@"
    else
      sh "$MVU_SCRIPT" --comms "$@"
    fi
    ;;
  --benchmark)
    echo "  Mode: BENCHMARK (10-step timing)"
    if echo "$MVU_SCRIPT" | grep -q "v8"; then
      sh "$MVU_SCRIPT" --benchmark
    else
      echo "  ⚠️  --benchmark requires v8 engine."
      echo "     neural_mvu_v8.sh not found or not executable."
      exit 1
    fi
    ;;
  --breed)
    shift
    N="${1:-5}"
    sh "$DAO_SCRIPT" --breed "$N" 2>/dev/null || echo "  DAO engine --breed not available"
    ;;
  --fitness)
    shift
    sh "$DAO_SCRIPT" --fitness "$1" 2>/dev/null || echo "  DAO engine --fitness not available"
    ;;
  --verify)
    echo "  Mode: CAUSAL WALL VERIFICATION"
    if echo "$MVU_SCRIPT" | grep -q "\.py$"; then
      echo "  (Python v2 uses SHA256 hash chain — verify via --status)"
      python3 "$MVU_SCRIPT" --status | grep -A3 "Causal Wall"
    else
      sh "$MVU_SCRIPT" --verify
    fi
    ;;
  --help|-h|*)
    echo "Usage: sh run_universe.sh [command]"
    echo ""
    echo "Auto-detects best available engine: v8 > v7 > v2.py"
    echo ""
    echo "Commands:"
    echo "  (no args)    Full lifecycle (train 100 → run 50 → evolve)"
    echo "  --train [N]  Train neural MVU for N steps"
    echo "  --train-fast [N] Fast batch training (v8 only)"
    echo "  --run [N]    Run causally closed for N steps"
    echo "  --all        Train → run → spawn → evolve"
    echo "  --evolve     DAO evolutionary cycle"
    echo "  --status     Full status"
    echo "  --phoenix    Phoenix Protocol (total collapse recovery)"
    echo "  --proposal   DAO proposal (submit|list|status)"
    echo "  --vote       Cast DAO vote"
    echo "  --spawn      Spawn child universe"
    echo "  --comms      Communication status or send"
    echo "  --benchmark  10-step timing benchmark (v8 only)"
    echo "  --verify     Causal wall verification"
    echo "  --breed [N]  Breed N children"
    echo "  --fitness    Score a universe"
    echo ""
    echo "Current engine: ${MVU_VERSION:-none}"
    echo ""
    ;;
esac
