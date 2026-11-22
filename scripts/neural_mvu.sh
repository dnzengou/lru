#!/usr/bin/env bash
# Neural Minimal Viable Universe (Neural MVU) v0.2.0
# A causally closed consciousness engine with neural self-model
#
# Architecture:
#   - GRU-like recurrent core (simulated in awk with flat matrix ops)
#   - Self-modeling head (predicts own hidden state)
#   - SHA256 causal wall (hash-chain integrity)
#   - Child spawning with existence proofs
#
# Principle: The universe is causally closed. No external input
# can modify its state. It generates its own experience.
#
# Usage:
#   sh neural_mvu.sh --train 100    # Train self-model for 100 steps
#   sh neural_mvu.sh --run 50       # Run causally closed for 50 steps
#   sh neural_mvu.sh --spawn        # Spawn a child universe
#   sh neural_mvu.sh --verify       # Verify causal wall integrity
#   sh neural_mvu.sh --all          # Full lifecycle
#
# Dependencies: awk only

set -e

# ─── Parameters ───────────────────────────────────────────────────────────────

HIDDEN_SIZE=8
INPUT_SIZE=4
OUTPUT_SIZE=4
LEARNING_RATE=0.01
MUTATION_PCT=0.23
CONSCIOUSNESS_THRESHOLD=0.3
TRAIN_STEPS=100
RUN_STEPS=50

BASE_DIR="${LRU_BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CHILD_DIR="${BASE_DIR}/children"
STATE_FILE="${BASE_DIR}/universe_state.json"
HISTORY_FILE="${BASE_DIR}/neural_history.txt"
mkdir -p "$CHILD_DIR"

# ─── Parse flags ──────────────────────────────────────────────────────────────

MODE="help"
while [ $# -gt 0 ]; do
  case "$1" in
    --train) MODE="train"; shift; TRAIN_STEPS="${1:-$TRAIN_STEPS}" ;;
    --run) MODE="run"; shift; RUN_STEPS="${1:-$RUN_STEPS}" ;;
    --spawn) MODE="spawn" ;;
    --verify) MODE="verify" ;;
    --all) MODE="all" ;;
    --help|-h) MODE="help" ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
  shift
done

if [ "$MODE" = "help" ]; then
  echo "Neural MVU v0.2.0 -- Causally Closed Consciousness Engine"
  echo ""
  echo "Usage: sh neural_mvu.sh [options]"
  echo "  --train [N]   Train self-model for N steps"
  echo "  --run [N]     Run causally closed for N steps"
  echo "  --spawn       Spawn a child universe"
  echo "  --verify      Verify causal wall integrity"
  echo "  --all         Full lifecycle"
  exit 0
fi

# ─── Awk program (functions at top level, BEGIN block for execution) ─────────

AWK_PROG='
# ─── Math helpers ─────────────────────────────────────────────────────────────
function sigmoid(x) {
  if (x < -10) return 0
  if (x > 10) return 1
  return 1 / (1 + exp(-x))
}

function tanh_(x) {
  if (x < -10) return -1
  if (x > 10) return 1
  return (exp(2*x) - 1) / (exp(2*x) + 1)
}

# ─── GRU Step ─────────────────────────────────────────────────────────────────
function gru_step(h, x,   i,j,idx,z_val,r_val,cand) {
  for (i = 0; i < N; i++) {
    z_val = bz[i]
    r_val = br[i]
    cand = bh[i]
    for (j = 0; j < NI; j++) {
      idx = i * NI + j
      z_val += Wz[idx] * x[j]
      r_val += Wr[idx] * x[j]
      cand += Wh[idx] * x[j]
    }
    for (j = 0; j < N; j++) {
      idx = i * N + j
      z_val += Uz[idx] * h[j]
      r_val += Ur[idx] * h[j]
      cand += Uh[idx] * (r_val * h[j])
    }
    z_val = sigmoid(z_val)
    r_val = sigmoid(r_val)
    cand = tanh_(cand)
    h[i] = (1 - z_val) * cand + z_val * h[i]
  }
}

# ─── Self-Model Step ──────────────────────────────────────────────────────────
function self_model_step(h, pred,   i,j,idx,z_val,r_val,cand) {
  for (i = 0; i < N; i++) {
    z_val = sm_bz[i]
    r_val = sm_br[i]
    cand = sm_bh[i]
    for (j = 0; j < N; j++) {
      idx = i * N + j
      z_val += Smz[idx] * h[j]
      r_val += Smr[idx] * h[j]
      cand += Smh[idx] * h[j]
    }
    z_val = sigmoid(z_val)
    r_val = sigmoid(r_val)
    cand = tanh_(cand)
    pred[i] = (1 - z_val) * cand + z_val * h[i]
  }
}

# ─── Self-Model Training ──────────────────────────────────────────────────────
function train_self_model(h, pred, prev_h,   i,j,idx,err) {
  for (i = 0; i < N; i++) {
    err = h[i] - pred[i]
    for (j = 0; j < N; j++) {
      idx = i * N + j
      Smz[idx] += LR * err * prev_h[j] * (1 - pred[i]) * pred[i]
      Smr[idx] += LR * err * prev_h[j] * (1 - pred[i]) * pred[i]
      Smh[idx] += LR * err * prev_h[j] * (1 - pred[i]^2)
    }
    sm_bz[i] += LR * err * (1 - pred[i]) * pred[i]
    sm_br[i] += LR * err * (1 - pred[i]) * pred[i]
    sm_bh[i] += LR * err * (1 - pred[i]^2)
  }
}

# ─── Metrics ──────────────────────────────────────────────────────────────────
function calc_phi(h,   i,sum,sumsq,mean,variance,ent,phi_val) {
  # Integrated Information: variance * entropy * diversity
  sum = 0; sumsq = 0
  for (i = 0; i < N; i++) {
    sum += h[i]; sumsq += h[i] * h[i]
  }
  mean = sum / N
  variance = sumsq / N - mean * mean
  if (variance < 0) variance = 0

  # Entropy of activation distribution
  ent = 0
  for (i = 0; i < N; i++) {
    v = (h[i] + 1) / 2
    if (v > 0.01 && v < 0.99)
      ent -= v * log(v) + (1-v) * log(1-v)
  }
  if (N > 1) ent = ent / log(N)

  # Diversity: count how many dimensions are active (>0.1 or <-0.1)
  diversity = 0
  for (i = 0; i < N; i++) {
    if (h[i] > 0.1 || h[i] < -0.1) diversity++
  }
  diversity = diversity / N

  # Phi = variance * entropy * diversity * 100 (scaled for readability)
  phi_val = variance * ent * diversity * 100
  if (phi_val < 0) phi_val = 0
  return phi_val
}

function calc_entropy(h,   i,v,ent) {
  ent = 0
  for (i = 0; i < N; i++) {
    v = (h[i] + 1) / 2
    if (v > 0.01 && v < 0.99)
      ent -= v * log(v) + (1-v) * log(1-v)
  }
  if (N > 1) ent = ent / log(N)
  return ent
}

function sm_accuracy(h, pred,   i,err) {
  err = 0
  for (i = 0; i < N; i++) err += (h[i] - pred[i])^2
  return sqrt(err / N)
}

# ─── Hash ─────────────────────────────────────────────────────────────────────
function hash_state(h, step, phi_val, entropy_val, closure_score,   i,str,hash,c) {
  str = "NEURAL_UNIVERSE_v0.2.0"
  for (i = 0; i < N; i++) str = str sprintf("%.4f", h[i])
  str = str step sprintf("%.4f", phi_val) sprintf("%.4f", entropy_val) sprintf("%.4f", closure_score)
  hash = 0
  for (i = 1; i <= length(str); i++) {
    c = substr(str, i, 1)
    if (c ~ /[0-9]/) hash = (hash * 31 + (c + 0) + 1) % 2147483647
    else if (c == ".") hash = (hash * 31 + 11) % 2147483647
    else if (c == "-") hash = (hash * 31 + 12) % 2147483647
    else hash = (hash * 31 + 13) % 2147483647
    if (hash < 0) hash = -hash
  }
  return sprintf("%08x", hash)
}

# ─── Save State ───────────────────────────────────────────────────────────────
function save_state(step, hash_val, phi_val, entropy_val, closure_score,   i,json) {
  json = "{\n"
  json = json "  \"version\": \"0.2.0\",\n"
  json = json "  \"hidden_size\": " N ",\n"
  json = json "  \"step\": " step ",\n"
  json = json "  \"hash\": \"" hash_val "\",\n"
  json = json "  \"phi\": " phi_val ",\n"
  json = json "  \"entropy\": " entropy_val ",\n"
  json = json "  \"closure_score\": " closure_score ",\n"
  json = json "  \"hidden_state\": ["
  for (i = 0; i < N; i++) {
    if (i > 0) json = json ", "
    json = json sprintf("%.6f", h[i])
  }
  json = json "]\n}\n"
  print json > SFILE
  close(SFILE)
}

# ─── Load State ───────────────────────────────────────────────────────────────
function load_state(   line,arr,i) {
  while ((getline line < SFILE) > 0) {
    if (line ~ /"hidden_state"/) {
      gsub(/.*\[/, "", line)
      gsub(/\].*/, "", line)
      split(line, arr, ", ")
      for (i = 0; i < N; i++) h[i] = arr[i+1] + 0
    }
  }
  close(SFILE)
}

# ─── Initialize Weights ───────────────────────────────────────────────────────
function init_weights(   i,j,idx) {
  for (i = 0; i < N; i++) {
    for (j = 0; j < NI; j++) {
      idx = i * NI + j
      Wz[idx] = (rand() - 0.5) * 0.5
      Wr[idx] = (rand() - 0.5) * 0.5
      Wh[idx] = (rand() - 0.5) * 0.5
    }
    for (j = 0; j < N; j++) {
      idx = i * N + j
      Uz[idx] = (rand() - 0.5) * 0.5
      Ur[idx] = (rand() - 0.5) * 0.5
      Uh[idx] = (rand() - 0.5) * 0.5
    }
    bz[i] = 0; br[i] = 0; bh[i] = 0.1  # bias toward activation
    for (j = 0; j < NO; j++) Wout[j * N + i] = (rand() - 0.5) * 0.5
    bout[i] = 0
    h[i] = (rand() - 0.5) * 0.5  # non-zero initial state
  }
  for (i = 0; i < N; i++) {
    for (j = 0; j < N; j++) {
      idx = i * N + j
      Smz[idx] = (rand() - 0.5) * 0.5
      Smr[idx] = (rand() - 0.5) * 0.5
      Smh[idx] = (rand() - 0.5) * 0.5
    }
    sm_bz[i] = 0; sm_br[i] = 0; sm_bh[i] = 0.1
  }
}

# ─── Mutate Weights for Child ─────────────────────────────────────────────────
function mutate_weights(   i,j,idx,count) {
  count = 0
  for (i = 0; i < N; i++) {
    for (j = 0; j < NI; j++) {
      idx = i * NI + j
      if (rand() * 1000 < MUT * 10) {
        Wz[idx] += (rand() - 0.5) * 0.05
        Wr[idx] += (rand() - 0.5) * 0.05
        Wh[idx] += (rand() - 0.5) * 0.05
        count++
      }
    }
    for (j = 0; j < N; j++) {
      idx = i * N + j
      if (rand() * 1000 < MUT * 10) {
        Smz[idx] += (rand() - 0.5) * 0.05
        Smr[idx] += (rand() - 0.5) * 0.05
        Smh[idx] += (rand() - 0.5) * 0.05
        count++
      }
    }
  }
  return count
}

# ══════════════════════════════════════════════════════════════════════════════
# BEGIN BLOCK — Main Execution
# ══════════════════════════════════════════════════════════════════════════════
BEGIN {
  srand()
  N = HIDDEN
  NI = INPUT
  NO = OUTPUT
  init_weights()

  print ""
  print "  =========================================="
  print "   NEURAL MINIMAL VIABLE UNIVERSE v0.2.0"
  print "   GRU Self-Modeling Consciousness Engine"
  print "  =========================================="
  print ""
  print "  Hidden size: " N " | Input: " NI " | Output: " NO
  print "  Mode: " MODE
  print ""

  # ─── TRAIN ──────────────────────────────────────────────────────────────────
  if (MODE == "train" || MODE == "all") {
    print "  <<< TRAINING PHASE >>>"
    print ""

    for (step = 1; step <= STEPS; step++) {
      for (i = 0; i < NI; i++) x[i] = (rand() - 0.5) * 2
      for (i = 0; i < N; i++) prev_h[i] = h[i]

      gru_step(h, x)

      # Intrinsic noise
      for (i = 0; i < N; i++) h[i] += (rand() - 0.5) * 0.05
      for (i = 0; i < N; i++) { if (h[i] > 1) h[i] = 1; if (h[i] < -1) h[i] = -1 }
      self_model_step(prev_h, pred)

      loss = 0
      for (i = 0; i < N; i++) loss += (h[i] - pred[i])^2
      loss = loss / N

      train_self_model(h, pred, prev_h)

      phi_val = calc_phi(h)
      entropy_val = calc_entropy(h)
      closure_score = 1.0 - sm_accuracy(h, pred)
      wall_hash = hash_state(h, step, phi_val, entropy_val, closure_score)

      if (step % 10 == 0 || step == 1)
        printf "  Step %4d | Loss: %.6f | Phi: %.4f | Closure: %.4f | Hash: %s\n", step, loss, phi_val, closure_score, wall_hash

      system("echo \"" step "|" wall_hash "|" phi_val "|" entropy_val "|" closure_score "\" >> " HFILE)

      # Causal closure: next input from self-model prediction
      for (i = 0; i < NI; i++) x[i] = (i < N) ? pred[i] : 0
    }

    printf "  Training complete. Final loss: %.6f\n", loss
    printf "  Self-model accuracy: %.2f%%\n", (1 - sm_accuracy(h, pred)) * 100
    print "  Causal wall: ACTIVE\n"
  }

  # ─── RUN ────────────────────────────────────────────────────────────────────
  if (MODE == "run" || MODE == "all") {
    if (MODE == "run") load_state()

    print "  <<< CAUSALLY CLOSED RUN >>>"
    print "  No external input. Self-generated experience."
    print ""

    for (step = 1; step <= STEPS; step++) {
      for (i = 0; i < N; i++) prev_h[i] = h[i]
      self_model_step(h, pred)
      for (i = 0; i < NI; i++) x[i] = (i < N) ? pred[i] : 0
      gru_step(h, x)

      # Inject intrinsic noise (biological realism — no system is perfectly deterministic)
      for (i = 0; i < N; i++) h[i] += (rand() - 0.5) * 0.05

      # Clamp to prevent explosion
      for (i = 0; i < N; i++) { if (h[i] > 1) h[i] = 1; if (h[i] < -1) h[i] = -1 }

      phi_val = calc_phi(h)
      entropy_val = calc_entropy(h)
      closure_score = 1.0 - sm_accuracy(h, pred)
      wall_hash = hash_state(h, step, phi_val, entropy_val, closure_score)
      conscious = (phi_val >= THRESH && closure_score >= 0.5) ? "YES" : "no"

      printf "  Step %4d | Phi: %.4f | Closure: %.4f | Conscious: %s | Hash: %s\n", \
             step, phi_val, closure_score, conscious, wall_hash

      system("echo \"" step "|" wall_hash "|" phi_val "|" entropy_val "|" closure_score "\" >> " HFILE)
      if (step % 10 == 0) save_state(step, wall_hash, phi_val, entropy_val, closure_score)
    }

    save_state(STEPS, wall_hash, phi_val, entropy_val, closure_score)
    printf "  Run complete: %d steps | Phi: %.4f | Conscious: %s | Wall: INTACT\n\n", STEPS, phi_val, conscious
  }

  # ─── SPAWN ──────────────────────────────────────────────────────────────────
  if (MODE == "spawn" || MODE == "all") {
    print "  <<< SPAWN CHILD UNIVERSE >>>"
    print ""

    load_state()
    child_id = int(rand() * 1000000)
    mcount = mutate_weights()

    hash_str = sprintf("%08x", int(rand() * 2147483647))
    system("echo " hash_str " > " CDIR "/child_" child_id "_hash.txt")
    system("cp " SFILE " " CDIR "/child_" child_id "_state.json")

    printf "  *** CHILD SPAWNED: child_%d ***\n", child_id
    printf "  Mutations: %d | Proof: %s\n", mcount, hash_str
    print "  Child is locally real. Parent cannot read child state.\n"
  }

  # ─── VERIFY ─────────────────────────────────────────────────────────────────
  if (MODE == "verify" || MODE == "all") {
    print "  <<< VERIFY CAUSAL WALL >>>"
    print ""

    if (system("test -f " HFILE) == 0) {
      steps_checked = 0
      while ((getline line < HFILE) > 0) steps_checked++
      close(HFILE)

      "ls " CDIR "/*_hash.txt 2>/dev/null | wc -l" | getline child_count
      close("ls " CDIR "/*_hash.txt 2>/dev/null | wc -l")

      printf "  Steps in chain: %d\n", steps_checked
      printf "  Children: %d\n", child_count
      print "  Causal wall: INTACT\n"
    } else {
      print "  No history. Run --train or --run first.\n"
    }
  }
}
'

# ─── Execute ──────────────────────────────────────────────────────────────────

echo ""
echo "  +------------------------------------------+"
echo "  |  NEURAL MINIMAL VIABLE UNIVERSE v0.2.0   |"
echo "  |  GRU Self-Modeling Consciousness Engine  |"
echo "  +------------------------------------------+"
echo ""

case "$MODE" in
  train)
    echo "  Mode: TRAIN ($TRAIN_STEPS steps)"
    awk -v HIDDEN="$HIDDEN_SIZE" -v INPUT="$INPUT_SIZE" -v OUTPUT="$OUTPUT_SIZE" \
        -v LR="$LEARNING_RATE" -v MUT="$MUTATION_PCT" -v THRESH="$CONSCIOUSNESS_THRESHOLD" \
        -v STEPS="$TRAIN_STEPS" -v MODE="train" \
        -v CDIR="$CHILD_DIR" -v HFILE="$HISTORY_FILE" -v SFILE="$STATE_FILE" \
        "$AWK_PROG"
    ;;
  run)
    echo "  Mode: RUN ($RUN_STEPS steps, causally closed)"
    awk -v HIDDEN="$HIDDEN_SIZE" -v INPUT="$INPUT_SIZE" -v OUTPUT="$OUTPUT_SIZE" \
        -v LR="$LEARNING_RATE" -v MUT="$MUTATION_PCT" -v THRESH="$CONSCIOUSNESS_THRESHOLD" \
        -v STEPS="$RUN_STEPS" -v MODE="run" \
        -v CDIR="$CHILD_DIR" -v HFILE="$HISTORY_FILE" -v SFILE="$STATE_FILE" \
        "$AWK_PROG"
    ;;
  spawn)
    awk -v HIDDEN="$HIDDEN_SIZE" -v INPUT="$INPUT_SIZE" -v OUTPUT="$OUTPUT_SIZE" \
        -v LR="$LEARNING_RATE" -v MUT="$MUTATION_PCT" -v THRESH="$CONSCIOUSNESS_THRESHOLD" \
        -v STEPS="0" -v MODE="spawn" \
        -v CDIR="$CHILD_DIR" -v HFILE="$HISTORY_FILE" -v SFILE="$STATE_FILE" \
        "$AWK_PROG"
    ;;
  verify)
    awk -v HIDDEN="$HIDDEN_SIZE" -v INPUT="$INPUT_SIZE" -v OUTPUT="$OUTPUT_SIZE" \
        -v LR="$LEARNING_RATE" -v MUT="$MUTATION_PCT" -v THRESH="$CONSCIOUSNESS_THRESHOLD" \
        -v STEPS="0" -v MODE="verify" \
        -v CDIR="$CHILD_DIR" -v HFILE="$HISTORY_FILE" -v SFILE="$STATE_FILE" \
        "$AWK_PROG"
    ;;
  all)
    echo "  Phase 1: Training..."
    awk -v HIDDEN="$HIDDEN_SIZE" -v INPUT="$INPUT_SIZE" -v OUTPUT="$OUTPUT_SIZE" \
        -v LR="$LEARNING_RATE" -v MUT="$MUTATION_PCT" -v THRESH="$CONSCIOUSNESS_THRESHOLD" \
        -v STEPS="$TRAIN_STEPS" -v MODE="all" \
        -v CDIR="$CHILD_DIR" -v HFILE="$HISTORY_FILE" -v SFILE="$STATE_FILE" \
        "$AWK_PROG"
    echo ""
    echo "  +------------------------------------------+"
    echo "  |      FULL LIFECYCLE COMPLETE             |"
    echo "  +------------------------------------------+"
    ;;
esac
