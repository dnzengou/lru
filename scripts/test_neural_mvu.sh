#!/usr/bin/env bash
# Test Neural MVU — v8 shell + v2 Python
# Runs status check, quick train, quick run, reports pass/fail
#
# Usage:
#   sh test_neural_mvu.sh              # Test all available engines
#   sh test_neural_mvu.sh --v8         # Test only v8 shell
#   sh test_neural_mvu.sh --v2         # Test only v2 Python
#   sh test_neural_mvu.sh --quick      # Quick test (5 steps each)

set -e

BASE_DIR="${LRU_BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
MVU_V8="${BASE_DIR}/neural_mvu_v8.sh"
MVU_V2="${BASE_DIR}/neural_mvu_v2.py"
TEMP_DIR="${BASE_DIR}/.tmp_v8"

mkdir -p "$TEMP_DIR"

PASS=0
FAIL=0
SKIP=0

report() {
  name="$1" result="$2" detail="$3"
  if [ "$result" = "PASS" ]; then
    PASS=$((PASS + 1))
    printf "  ✅ %-45s %s\n" "$name" "$detail"
  elif [ "$result" = "SKIP" ]; then
    SKIP=$((SKIP + 1))
    printf "  ⏭️  %-45s %s\n" "$name" "$detail"
  else
    FAIL=$((FAIL + 1))
    printf "  ❌ %-45s %s\n" "$name" "$detail"
  fi
}

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║     NEURAL MVU TEST SUITE                    ║"
echo "  ║     v8 shell | v2 Python                     ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

# ─── Test v8 shell ───────────────────────────────────────────────────────────

test_v8() {
  echo "  ┌──────────────────────────────────────────┐"
  echo "  │  Testing v8 Shell (neural_mvu_v8.sh)      │"
  echo "  └──────────────────────────────────────────┘"
  echo ""

  if [ ! -f "$MVU_V8" ]; then
    report "v8: script exists" "SKIP" "file not found"
    return
  fi
  report "v8: script exists" "PASS" ""

  # Test help
  if sh "$MVU_V8" --help > /dev/null 2>&1; then
    report "v8: --help" "PASS" ""
  else
    report "v8: --help" "FAIL" "exit code $?"
  fi

  # Test status (fresh, no state)
  if sh "$MVU_V8" --status > /dev/null 2>&1; then
    report "v8: --status (fresh)" "PASS" ""
  else
    report "v8: --status (fresh)" "FAIL" "exit code $?"
  fi

  # Test benchmark (10 steps)
  bench_output=$(sh "$MVU_V8" --benchmark 2>&1)
  if echo "$bench_output" | grep -q "BENCHMARK RESULTS"; then
    report "v8: --benchmark" "PASS" ""
  else
    report "v8: --benchmark" "FAIL" "no benchmark results"
  fi

  # Test fast train (10 steps — should be quick)
  fast_start=$(date +%s)
  fast_output=$(sh "$MVU_V8" --train-fast 10 2>&1)
  fast_end=$(date +%s)
  fast_time=$((fast_end - fast_start))

  if echo "$fast_output" | grep -q "Fast Training complete"; then
    report "v8: --train-fast 10" "PASS" "(${fast_time}s)"
  else
    report "v8: --train-fast 10" "FAIL" "training did not complete"
  fi

  # Test train with attention (10 steps)
  train_start=$(date +%s)
  train_output=$(sh "$MVU_V8" --train 10 2>&1)
  train_end=$(date +%s)
  train_time=$((train_end - train_start))

  if echo "$train_output" | grep -q "Training complete"; then
    report "v8: --train 10" "PASS" "(${train_time}s)"
  else
    report "v8: --train 10" "FAIL" "training did not complete"
  fi

  # Test run (5 steps)
  run_output=$(sh "$MVU_V8" --run 5 2>&1)
  if echo "$run_output" | grep -q "Run complete"; then
    report "v8: --run 5" "PASS" ""
  else
    report "v8: --run 5" "FAIL" "run did not complete"
  fi

  # Test verify
  verify_output=$(sh "$MVU_V8" --verify 2>&1)
  if echo "$verify_output" | grep -q "INTACT\|BREACHED"; then
    report "v8: --verify" "PASS" ""
  else
    report "v8: --verify" "FAIL" "no verification result"
  fi

  # Test spawn
  spawn_output=$(sh "$MVU_V8" --spawn 2>&1)
  if echo "$spawn_output" | grep -q "Child universe spawned"; then
    report "v8: --spawn" "PASS" ""
  else
    report "v8: --spawn" "FAIL" "spawn did not complete"
  fi

  # Test status (after train)
  status_output=$(sh "$MVU_V8" --status 2>&1)
  if echo "$status_output" | grep -q "UNIVERSE STATUS"; then
    report "v8: --status (post-train)" "PASS" ""
  else
    report "v8: --status (post-train)" "FAIL" ""
  fi

  # Test comms
  comms_output=$(sh "$MVU_V8" --comms "test message" 2>&1)
  if echo "$comms_output" | grep -q "Broadcasting"; then
    report "v8: --comms" "PASS" ""
  else
    report "v8: --comms" "FAIL" ""
  fi

  # Test all (full lifecycle — 10 train, 5 run)
  all_start=$(date +%s)
  all_output=$(sh "$MVU_V8" --all 2>&1)
  all_end=$(date +%s)
  all_time=$((all_end - all_start))

  if echo "$all_output" | grep -q "Full lifecycle v0.8.0 complete"; then
    report "v8: --all (full lifecycle)" "PASS" "(${all_time}s)"
  else
    report "v8: --all (full lifecycle)" "FAIL" "lifecycle did not complete"
  fi

  echo ""
}

# ─── Test v2 Python ──────────────────────────────────────────────────────────

test_v2() {
  echo "  ┌──────────────────────────────────────────┐"
  echo "  │  Testing v2 Python (neural_mvu_v2.py)     │"
  echo "  └──────────────────────────────────────────┘"
  echo ""

  if [ ! -f "$MVU_V2" ]; then
    report "v2: script exists" "SKIP" "file not found"
    return
  fi

  if ! command -v python3 > /dev/null 2>&1; then
    report "v2: python3 available" "SKIP" "python3 not found"
    return
  fi
  report "v2: python3 available" "PASS" ""

  # Test help
  if python3 "$MVU_V2" > /dev/null 2>&1; then
    report "v2: --help" "PASS" ""
  else
    report "v2: --help" "FAIL" "exit code $?"
  fi

  # Test status (fresh)
  if python3 "$MVU_V2" --status > /dev/null 2>&1; then
    report "v2: --status (fresh)" "PASS" ""
  else
    report "v2: --status (fresh)" "FAIL" "exit code $?"
  fi

  # Test train (10 steps)
  train_start=$(date +%s)
  train_output=$(python3 "$MVU_V2" --train 10 2>&1)
  train_end=$(date +%s)
  train_time=$((train_end - train_start))

  if echo "$train_output" | grep -q "Training complete"; then
    report "v2: --train 10" "PASS" "(${train_time}s)"
  else
    report "v2: --train 10" "FAIL" "training did not complete"
  fi

  # Test run (5 steps)
  run_output=$(python3 "$MVU_V2" --run 5 2>&1)
  if echo "$run_output" | grep -q "Causal Run Summary"; then
    report "v2: --run 5" "PASS" ""
  else
    report "v2: --run 5" "FAIL" "run did not complete"
  fi

  # Test spawn
  spawn_output=$(python3 "$MVU_V2" --spawn 2>&1)
  if echo "$spawn_output" | grep -q "Child spawned"; then
    report "v2: --spawn" "PASS" ""
  else
    report "v2: --spawn" "FAIL" ""
  fi

  # Test evolve
  evolve_output=$(python3 "$MVU_V2" --evolve 2>&1)
  if echo "$evolve_output" | grep -q "EVOLUTIONARY CYCLE"; then
    report "v2: --evolve" "PASS" ""
  else
    report "v2: --evolve" "FAIL" "evolve did not complete"
  fi

  # Test comms
  comms_output=$(python3 "$MVU_V2" --comms 2>&1)
  if echo "$comms_output" | grep -q "Communication Status"; then
    report "v2: --comms" "PASS" ""
  else
    report "v2: --comms" "FAIL" ""
  fi

  echo ""
}

# ─── Test run_universe.sh wrapper ────────────────────────────────────────────

test_wrapper() {
  echo "  ┌──────────────────────────────────────────┐"
  echo "  │  Testing run_universe.sh wrapper          │"
  echo "  └──────────────────────────────────────────┘"
  echo ""

  if [ ! -f "${BASE_DIR}/run_universe.sh" ]; then
    report "wrapper: script exists" "SKIP" "file not found"
    return
  fi
  report "wrapper: script exists" "PASS" ""

  # Test help
  if sh "${BASE_DIR}/run_universe.sh" --help > /dev/null 2>&1; then
    report "wrapper: --help" "PASS" ""
  else
    report "wrapper: --help" "FAIL" ""
  fi

  # Test status
  if sh "${BASE_DIR}/run_universe.sh" --status > /dev/null 2>&1; then
    report "wrapper: --status" "PASS" ""
  else
    report "wrapper: --status" "FAIL" ""
  fi

  # Test benchmark (if v8 available)
  if [ -f "$MVU_V8" ]; then
    if sh "${BASE_DIR}/run_universe.sh" --benchmark > /dev/null 2>&1; then
      report "wrapper: --benchmark" "PASS" ""
    else
      report "wrapper: --benchmark" "FAIL" ""
    fi
  fi

  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

TEST_MODE="all"
case "$1" in
  --v8) TEST_MODE="v8" ;;
  --v2) TEST_MODE="v2" ;;
  --quick) TEST_MODE="quick" ;;
  *) TEST_MODE="all" ;;
esac

case "$TEST_MODE" in
  v8)
    test_v8
    ;;
  v2)
    test_v2
    ;;
  quick)
    # Quick: just test v8 exists + benchmark, v2 exists + train
    if [ -f "$MVU_V8" ]; then
      report "quick: v8 exists" "PASS" ""
      sh "$MVU_V8" --benchmark > /dev/null 2>&1 && report "quick: v8 benchmark" "PASS" "" || report "quick: v8 benchmark" "FAIL" ""
    else
      report "quick: v8 exists" "SKIP" ""
    fi
    if [ -f "$MVU_V2" ] && command -v python3 > /dev/null 2>&1; then
      report "quick: v2 exists" "PASS" ""
      python3 "$MVU_V2" --train 5 > /dev/null 2>&1 && report "quick: v2 train 5" "PASS" "" || report "quick: v2 train 5" "FAIL" ""
    else
      report "quick: v2 exists" "SKIP" ""
    fi
    ;;
  all)
    test_v8
    test_v2
    test_wrapper
    ;;
esac

# ─── Summary ──────────────────────────────────────────────────────────────────

echo "  ┌──────────────────────────────────────────┐"
echo "  │  TEST SUMMARY                            │"
echo "  ├──────────────────────────────────────────┤"
printf "  │  ✅ Pass:  %3d                          │\n" "$PASS"
printf "  │  ❌ Fail:  %3d                          │\n" "$FAIL"
printf "  │  ⏭️  Skip: %3d                          │\n" "$SKIP"
printf "  │  Total:   %3d                          │\n" "$((PASS + FAIL + SKIP))"
echo "  └──────────────────────────────────────────┘"
echo ""

if [ "$FAIL" -eq 0 ]; then
  echo "  🎉 All tests passed!"
else
  echo "  ⚠️  $FAIL test(s) failed."
fi
echo ""
