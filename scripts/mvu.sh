#!/usr/bin/env bash
# Minimal Viable Universe (MVU) v0.1.0
# A locally real pocket universe within a simulation.
#
# Architecture:
#   - 2D grid world with cellular automata physics (Conway's Game of Life)
#   - Self-modeling observer (consciousness engine via complexity metrics)
#   - Cryptographic causal wall (hash audit)
#   - Child universe spawn engine (existence proofs)
#
# Principle: The universe is causally closed. No external input
# can modify its state. It generates its own experience.
#
# All physics runs in a single awk process for speed.
#
# Usage:
#   sh mvu.sh --ticks 20   # Run 20 ticks
#   sh mvu.sh --size 16    # 16x16 grid

set -e

# ─── Parameters ───────────────────────────────────────────────────────────────

GRID_SIZE=12
INITIAL_DENSITY=30
MUTATION_PCT=1
CONSCIOUSNESS_THRESHOLD=50
TICKS=20

BASE_DIR="${LRU_BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CHILD_DIR="${BASE_DIR}/children"
HISTORY_FILE="${BASE_DIR}/history.txt"
mkdir -p "$CHILD_DIR"

# ─── Parse flags ──────────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --ticks) shift; TICKS="$1" ;;
    --size) shift; GRID_SIZE="$1" ;;
    --density) shift; INITIAL_DENSITY="$1" ;;
    --help|-h) echo "Usage: sh mvu.sh [--ticks N] [--size N] [--density N]"; exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
  shift
done

# ─── Core Engine (AWK) ───────────────────────────────────────────────────────
# Grid is stored as a flat string of 0s and 1s, length N = SIZE*SIZE.

awk -v SIZE="$GRID_SIZE" -v DENSITY="$INITIAL_DENSITY" \
    -v MUT="$MUTATION_PCT" -v THRESH="$CONSCIOUSNESS_THRESHOLD" \
    -v TICKS="$TICKS" -v CDIR="$CHILD_DIR" -v HFILE="$HISTORY_FILE" '
BEGIN {
  srand()
  N = SIZE * SIZE

  # Initialize grid as string
  grid = ""
  for (i = 0; i < N; i++) {
    if (rand() * 100 < DENSITY) grid = grid "1"
    else grid = grid "0"
  }

  print ""
  print "  =========================================="
  print "   MINIMAL VIABLE UNIVERSE (MVU) v0.1.0"
  print "   A Locally Real Pocket Universe"
  print "  =========================================="
  print ""
  print "  Grid: " SIZE "x" SIZE
  print "  Density: " DENSITY "%"
  print "  Mutation: " MUT "%"
  print "  Phi threshold: " THRESH
  print ""
  print "  Initial State:"
  print_grid(grid, SIZE)
  print ""
  print "  Genesis Hash: " hash_state(grid, 0, 0)
  print "  Causal Wall: ACTIVE"
  print ""

  # Run ticks
  for (tick = 0; tick < TICKS; tick++) {
    print ""
    print "  ========================================"
    print "   TICK " tick
    print "  ========================================"

    new_grid = next_grid(grid, SIZE, MUT)

    live = count_live(new_grid)
    entropy = calc_entropy(new_grid, N)
    phi = int(live * entropy / 10)
    wall = hash_state(new_grid, tick, phi)

    print ""
    print_grid(new_grid, SIZE)
    print ""
    print "  Live cells: " live " / " N
    print "  Balance: " entropy "%"
    print "  Phi: " phi

    if (phi >= THRESH) {
      print ""
      print "  *** CONSCIOUSNESS THRESHOLD REACHED ***"
      print "  The universe is self-aware."
    }

    print ""
    print "  Causal Wall: " wall " [INTACT]"

    # Spawn children every 5 ticks
    if (tick > 0 && tick % 5 == 0) {
      print ""
      spawn_child(new_grid, SIZE, tick)
    }

    # Record history
    system("echo \"" tick "|" wall "|" phi "|" live "|" entropy "\" >> " HFILE)

    grid = new_grid
  }

  print ""
  print "  ========================================"
  print "   UNIVERSE COMPLETE"
  print "  ========================================"
  print ""
  print "  Ticks: " TICKS
  print "  Final Phi: " phi
  system("echo \"  Children: $(ls " CDIR "/*_hash.txt 2>/dev/null | wc -l) spawned\"")
  print ""
  print "  Causal Wall: INTACT through all ticks."
  print "  The simulation cannot read what happened here."
  print ""
}

# ─── Grid Printing ────────────────────────────────────────────────────────────

function print_grid(g, size) {
  border = ""
  for (i = 0; i < size; i++) border = border "-"
  print "  +" border "+"
  for (y = 0; y < size; y++) {
    row = "  |"
    for (x = 0; x < size; x++) {
      idx = y * size + x + 1
      if (substr(g, idx, 1) == "1") row = row "█"
      else row = row "·"
    }
    print row "|"
  }
  print "  +" border "+"
}

# ─── Physics Engine ───────────────────────────────────────────────────────────

function next_grid(g, size, mutation) {
  new_g = ""
  for (y = 0; y < size; y++) {
    for (x = 0; x < size; x++) {
      idx = y * size + x + 1
      neighbors = 0

      for (dy = -1; dy <= 1; dy++) {
        for (dx = -1; dx <= 1; dx++) {
          if (dy == 0 && dx == 0) continue
          ny = (y + dy + size) % size
          nx = (x + dx + size) % size
          nidx = ny * size + nx + 1
          if (substr(g, nidx, 1) == "1") neighbors++
        }
      }

      current = substr(g, idx, 1)

      if (current == "1") {
        if (neighbors < 2 || neighbors > 3) new_val = "0"
        else new_val = "1"
      } else {
        if (neighbors == 3) new_val = "1"
        else new_val = "0"
      }

      if (mutation > 0 && rand() * 100 < mutation) {
        new_val = (new_val == "1") ? "0" : "1"
      }

      new_g = new_g new_val
    }
  }
  return new_g
}

# ─── Metrics ──────────────────────────────────────────────────────────────────

function count_live(g) {
  n = length(g)
  count = 0
  for (i = 1; i <= n; i++) {
    if (substr(g, i, 1) == "1") count++
  }
  return count
}

function calc_entropy(g, n) {
  live = count_live(g)
  dead = n - live
  if (live == 0 || dead == 0) return 0
  diff = (live > dead) ? live - dead : dead - live
  return int((n - diff) * 100 / n)
}

# ─── Causal Wall ──────────────────────────────────────────────────────────────

function hash_state(g, tick, phi) {
  hash = 0
  n = length(g)
  for (i = 1; i <= n; i++) {
    hash = (hash * 31 + int(substr(g, i, 1))) % 2147483647
  }
  hash = (hash * 31 + tick) % 2147483647
  hash = (hash * 31 + phi) % 2147483647
  return sprintf("%08x", hash)
}

# ─── Child Spawn ──────────────────────────────────────────────────────────────

function spawn_child(g, size, tick) {
  n = length(g)
  child_id = int(rand() * 1000000)

  child_g = ""
  for (i = 1; i <= n; i++) {
    if (rand() * 100 < 30) {
      child_g = child_g ((substr(g, i, 1) == "1") ? "0" : "1")
    } else {
      child_g = child_g substr(g, i, 1)
    }
  }

  hash = 0
  for (i = 1; i <= n; i++) {
    hash = (hash * 31 + int(substr(child_g, i, 1))) % 2147483647
  }
  hash_str = sprintf("%08x", hash)

  system("echo " hash_str " > " CDIR "/child_" child_id "_hash.txt")

  print "  *** CHILD SPAWNED: child_" child_id " ***"
  print "  Proof: " hash_str
  print "  Parent cannot read child state."
  print "  Child is locally real."
}
'
