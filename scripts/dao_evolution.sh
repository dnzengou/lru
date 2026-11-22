#!/usr/bin/env bash
# Universe DAO Evolution Engine v0.7.0
# ======================================
# Evolutionary selection, breeding, and causal wall verification
# for the universe population.
#
# Usage:
#   sh dao_evolution.sh                        # Run full evolution cycle
#   sh dao_evolution.sh --status               # Show evolution status
#   sh dao_evolution.sh --fitness              # Score all universes
#   sh dao_evolution.sh --breed                # Breed from top universes
#   sh dao_evolution.sh --verify-causal-wall   # Verify all causal chains
#   sh dao_evolution.sh --report               # Full evolution report
#
# Dependencies: awk, sha256sum, bc

set -e

BASE_DIR="${LRU_BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CHILD_DIR="${BASE_DIR}/children"
DAO_DIR="${BASE_DIR}/dao"
STATE_FILE="${BASE_DIR}/universe_state_v7.json"
HISTORY_FILE="${BASE_DIR}/neural_history_v7.txt"
EVOLUTION_FILE="${BASE_DIR}/evolution/evolution_report.txt"
REGISTRY_FILE="${DAO_DIR}/registry_v7.json"
COMMS_DIR="${DAO_DIR}/comms"

mkdir -p "${BASE_DIR}/evolution" "$COMMS_DIR"

# ─── Parameters ──────────────────────────────────────────────────────────────

TOURNAMENT_SIZE=3
ELITE_COUNT=2
MUTATION_RATE=0.02
CROSSOVER_RATE=0.5
HIDDEN_SIZE=16
N_HEADS=8

# ─── Help ─────────────────────────────────────────────────────────────────────

usage() {
  echo "Universe DAO Evolution Engine v0.7.0"
  echo ""
  echo "Usage:"
  echo "  $0                  Run full evolution cycle"
  echo "  $0 --status        Show evolution status"
  echo "  $0 --fitness       Score all universes"
  echo "  $0 --breed         Breed from top universes"
  echo "  $0 --verify-causal-wall   Verify all causal chains"
  echo "  $0 --report        Full evolution report"
  exit 0
}

# ─── JSON Helpers ─────────────────────────────────────────────────────────────

json_get() {
  file="$1" key="$2"
  awk -v k="$key" '{
    if ($0 ~ "\"" k "\"") {
      gsub(/.*"'"$key"'": *"?/, "")
      gsub(/[",}].*/, "")
      print
      exit
    }
  }' "$file"
}

json_set() {
  file="$1" key="$2" value="$3"
  if [ -f "$file" ]; then
    awk -v k="$key" -v v="$value" '{
      if ($0 ~ "\"" k "\"") {
        gsub(/"[^"]*": *[^,}]*/, "\"" k "\": " v)
      }
      print
    }' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
  fi
}

# ─── Collect all universe state files ───────────────────────────────────────

collect_universes() {
  list=""
  count=0

  # Parent v7
  if [ -f "$STATE_FILE" ]; then
    list="$list $STATE_FILE"
    count=$((count + 1))
  fi

  # Children with v7 generation tag
  for f in "$CHILD_DIR"/*_state.json; do
    [ ! -f "$f" ] && continue
    gen=$(json_get "$f" "generation" 2>/dev/null || echo "")
    [ "$gen" = "v7" ] || [ -z "$gen" ] && list="$list $f" && count=$((count + 1))
  done

  echo "$list"
  return 0
}

# ─── Compute fitness score ──────────────────────────────────────────────────

compute_fitness() {
  state_file="$1"
  if [ ! -f "$state_file" ]; then echo "0"; return; fi

  closure=$(json_get "$state_file" "closure_score")
  entropy=$(json_get "$state_file" "entropy")
  phi=$(json_get "$state_file" "phi")
  variance=$(json_get "$state_file" "variance")
  sm_acc=$(json_get "$state_file" "sm_accuracy")
  hs=$(json_get "$state_file" "hidden_size")

  [ -z "$closure" ] && closure=0
  [ -z "$entropy" ] && entropy=0
  [ -z "$phi" ] && phi=0
  [ -z "$variance" ] && variance=0
  [ -z "$sm_acc" ] && sm_acc=0
  [ -z "$hs" ] && hs=$HIDDEN_SIZE

  # Normalize entropy to [0,1]
  ent_norm=$(echo "scale=6; $entropy / 2.6667" | bc 2>/dev/null || echo "0.5")
  [ "$(echo "$ent_norm > 1.0" | bc -l 2>/dev/null)" = "1" ] && ent_norm=1.0
  [ "$(echo "$ent_norm < 0" | bc -l 2>/dev/null)" = "1" ] && ent_norm=0

  # Normalize phi to [0,1]
  phi_norm=$(echo "scale=6; $phi / 5.0" | bc 2>/dev/null || echo "0.02")
  [ "$(echo "$phi_norm > 1.0" | bc -l 2>/dev/null)" = "1" ] && phi_norm=1.0

  # Normalize variance to [0,1]
  var_norm=$(echo "scale=6; $variance * 10" | bc 2>/dev/null || echo "0.1")
  [ "$(echo "$var_norm > 1.0" | bc -l 2>/dev/null)" = "1" ] && var_norm=1.0

  # Hidden size bonus: larger = more capacity
  hs_bonus=$(echo "scale=6; $hs / 32.0 * 0.05" | bc 2>/dev/null || echo "0.025")

  # Weighted fitness: closure(0.35) + sm_acc(0.25) + entropy(0.15) + phi(0.15) + variance(0.10) + hs_bonus
  score=$(echo "scale=6; 0.35 * $closure + 0.25 * $sm_acc + 0.15 * $ent_norm + 0.15 * $phi_norm + 0.10 * $var_norm + $hs_bonus" | bc 2>/dev/null || echo "0")
  echo "$score"
}

# ─── Tournament Selection ───────────────────────────────────────────────────

tournament_select() {
  list="$1"
  list_count="$2"

  best_idx=1
  best_fit=0
  idx=1

  # Convert list to temp file for indexed access
  echo "$list" | tr ' ' '\n' > /tmp/evo_children_$$.txt

  for j in $(seq 1 $TOURNAMENT_SIZE); do
    pick=$(( (RANDOM % list_count) + 1 ))
    candidate=$(sed -n "${pick}p" /tmp/evo_children_$$.txt 2>/dev/null)
    [ -z "$candidate" ] && continue
    fit=$(compute_fitness "$candidate")
    if [ "$(echo "$fit > $best_fit" | bc -l 2>/dev/null)" = "1" ]; then
      best_fit=$fit
      best_idx=$pick
    fi
  done

  winner=$(sed -n "${best_idx}p" /tmp/evo_children_$$.txt 2>/dev/null)
  echo "$winner|$best_fit"
}

# ─── Crossover two parent states ────────────────────────────────────────────

crossover() {
  parent1="$1" parent2="$2"

  c1=$(json_get "$parent1" "closure_score")
  c2=$(json_get "$parent2" "closure_score")
  e1=$(json_get "$parent1" "entropy")
  e2=$(json_get "$parent2" "entropy")
  p1=$(json_get "$parent1" "phi")
  p2=$(json_get "$parent2" "phi")

  [ -z "$c1" ] && c1=0.5; [ -z "$c2" ] && c2=0.5
  [ -z "$e1" ] && e1=1.0; [ -z "$e2" ] && e2=1.0
  [ -z "$p1" ] && p1=0.1; [ -z "$p2" ] && p2=0.1

  # Crossover: mix genes from both parents
  alpha=$(echo "scale=6; $RANDOM / 32767.0" | bc 2>/dev/null || echo "0.5")
  child_closure=$(echo "scale=6; $alpha * $c1 + (1 - $alpha) * $c2" | bc 2>/dev/null || echo "0.5")
  child_entropy=$(echo "scale=6; $alpha * $e1 + (1 - $alpha) * $e2" | bc 2>/dev/null || echo "1.0")
  child_phi=$(echo "scale=6; $alpha * $p1 + (1 - $alpha) * $p2" | bc 2>/dev/null || echo "0.1")

  echo "$child_closure|$child_entropy|$child_phi"
}

# ─── Mutate with small random noise ─────────────────────────────────────────

mutate() {
  value="$1" rate="$2"
  noise=$(echo "scale=6; ($RANDOM % 200 - 100) / 1000 * $rate" | bc 2>/dev/null || echo "0")
  mutated=$(echo "scale=6; $value * (1 + $noise)" | bc 2>/dev/null || echo "$value")
  [ "$(echo "$mutated > 1" | bc -l 2>/dev/null)" = "1" ] && mutated=1
  [ "$(echo "$mutated < 0" | bc -l 2>/dev/null)" = "1" ] && mutated=0
  echo "$mutated"
}

# ─── Verify causal wall integrity ───────────────────────────────────────────

verify_causal_wall() {
  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     CAUSAL WALL INTEGRITY CHECK              ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  intact=0
  breached=0
  total=0

  # Check parent v7
  if [ -f "$STATE_FILE" ]; then
    total=$((total + 1))
    hash=$(json_get "$STATE_FILE" "hash")
    closure=$(json_get "$STATE_FILE" "closure_score")
    entropy=$(json_get "$STATE_FILE" "entropy")
    phi=$(json_get "$STATE_FILE" "phi")
    steps=$(json_get "$STATE_FILE" "steps")
    hs=$(json_get "$STATE_FILE" "hidden_size")
    computed=$(echo "$hash $closure $entropy $phi $steps $hs" | sha256sum | cut -c1-16)

    if [ "$hash" = "$computed" ]; then
      echo "  ✅ Parent v7: INTACT (hash: $hash)"
      intact=$((intact + 1))
    else
      echo "  ❌ Parent v7: BREACHED (stored: $hash, computed: $computed)"
      breached=$((breached + 1))
    fi
  fi

  # Check all children
  for f in "$CHILD_DIR"/*_state.json; do
    [ ! -f "$f" ] && continue
    total=$((total + 1))
    name=$(basename "$f" _state.json)
    hash=$(json_get "$f" "hash")
    closure=$(json_get "$f" "closure_score")
    entropy=$(json_get "$f" "entropy")
    phi=$(json_get "$f" "phi")
    hs=$(json_get "$f" "hidden_size")
    computed=$(echo "$hash $closure $entropy $phi $hs" | sha256sum | cut -c1-16)

    if [ "$hash" = "$computed" ]; then
      echo "  ✅ $name: INTACT"
      intact=$((intact + 1))
    else
      echo "  ❌ $name: BREACHED"
      breached=$((breached + 1))
    fi
  done

  echo ""
  echo "  ┌──────────────────────────────────────────┐"
  printf "  │  Total:  %4d                            │\n" "$total"
  printf "  │  Intact: %4d                            │\n" "$intact"
  printf "  │  Breach: %4d                            │\n" "$breached"
  echo "  └──────────────────────────────────────────┘"
  echo ""

  if [ "$breached" -eq 0 ]; then
    echo "  ✅ All causal walls INTACT across all generations"
    return 0
  else
    echo "  ❌ $breached causal wall(s) BREACHED"
    return 1
  fi
}

# ─── Score all universes ────────────────────────────────────────────────────

cmd_fitness() {
  list=$(collect_universes)
  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     FITNESS SCORES                            ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  best_fit=0
  best_name=""
  total=0

  for f in $list; do
    total=$((total + 1))
    name=$(basename "$f" _state.json)
    fit=$(compute_fitness "$f")
    closure=$(json_get "$f" "closure_score")
    phi=$(json_get "$f" "phi")
    entropy=$(json_get "$f" "entropy")
    printf "  %-30s fitness=%.6f  closure=%.4f  phi=%.4f  entropy=%.4f\n" "$name" "$fit" "$closure" "$phi" "$entropy"

    if [ "$(echo "$fit > $best_fit" | bc -l 2>/dev/null)" = "1" ]; then
      best_fit=$fit
      best_name="$name"
    fi
  done

  echo ""
  echo "  ┌──────────────────────────────────────────┐"
  printf "  │  Total: %3d universes                    │\n" "$total"
  printf "  │  Best:  %-30s│\n" "$best_name"
  printf "  │  Score: %.6f                      │\n" "$best_fit"
  echo "  └──────────────────────────────────────────┘"
  echo ""
}

# ─── Breed top universes ────────────────────────────────────────────────────

cmd_breed() {
  list=$(collect_universes)
  list_count=0
  for f in $list; do list_count=$((list_count + 1)); done

  if [ "$list_count" -lt 2 ]; then
    echo "  ⚠️  Need at least 2 universes to breed (have $list_count)"
    return 1
  fi

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     BREEDING NEW GENERATION                  ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  # Tournament select top 2
  result1=$(tournament_select "$list" "$list_count")
  parent1=$(echo "$result1" | cut -d'|' -f1)
  fit1=$(echo "$result1" | cut -d'|' -f2)

  # Remove parent1 from list and select again
  list2=""
  for f in $list; do
    [ "$f" != "$parent1" ] && list2="$list2 $f"
  done
  list2_count=$((list_count - 1))

  result2=$(tournament_select "$list2" "$list2_count")
  parent2=$(echo "$result2" | cut -d'|' -f1)
  fit2=$(echo "$result2" | cut -d'|' -f2)

  p1name=$(basename "$parent1" _state.json)
  p2name=$(basename "$parent2" _state.json)

  echo "  Selected parents:"
  printf "    P1: %-30s fitness=%.6f\n" "$p1name" "$fit1"
  printf "    P2: %-30s fitness=%.6f\n" "$p2name" "$fit2"
  echo ""

  # Crossover
  child_data=$(crossover "$parent1" "$parent2")
  child_closure=$(echo "$child_data" | cut -d'|' -f1)
  child_entropy=$(echo "$child_data" | cut -d'|' -f2)
  child_phi=$(echo "$child_data" | cut -d'|' -f3)

  # Mutate with phi*0.05
  mut_rate=$(echo "scale=6; $child_phi * 0.05 + $MUTATION_RATE" | bc 2>/dev/null || echo "$MUTATION_RATE")
  [ "$(echo "$mut_rate > 0.1" | bc -l 2>/dev/null)" = "1" ] && mut_rate=0.1

  child_closure=$(mutate "$child_closure" "$mut_rate")
  child_entropy=$(mutate "$child_entropy" "$mut_rate")
  child_phi=$(mutate "$child_phi" "$mut_rate")

  # Create child
  ts=$(date +%s)
  p1hash=$(json_get "$parent1" "hash")
  p2hash=$(json_get "$parent2" "hash")
  child_name="child_v7_evo_${ts}"
  child_hash=$(echo "$p1hash $p2hash $ts $child_closure $child_entropy $child_phi" | sha256sum | cut -c1-16)

  cat > "${CHILD_DIR}/${child_name}_state.json" << EOF
{
  "name": "${child_name}",
  "hash": "${child_hash}",
  "created": ${ts},
  "hidden_size": ${HIDDEN_SIZE},
  "n_heads": ${N_HEADS},
  "closure_score": ${child_closure},
  "entropy": ${child_entropy},
  "phi": ${child_phi},
  "sm_accuracy": 0.0,
  "variance": 0.0,
  "comms_received": 0,
  "comms_sent": 0,
  "last_comms_broadcast": 0,
  "parent1": "${p1hash}",
  "parent2": "${p2hash}",
  "generation": "v7",
  "breeding": "crossover"
}
EOF

  # Create existence proof
  echo "EXISTENCE_PROOF:${child_hash}:P1:${p1hash}:P2:${p2hash}:TS:${ts}:CLOSURE:${child_closure}:V7_EVO" > "${CHILD_DIR}/${child_name}_proof.txt"

  echo "  ✨ New child bred: ${child_name}"
  echo "     Hash: ${child_hash}"
  echo "     Closure: ${child_closure}"
  echo "     Entropy: ${child_entropy}"
  echo "     Phi: ${child_phi}"
  echo "     Mutation rate: ${mut_rate}"
  echo ""

  # Broadcast breeding event
  msg_id=$(echo "bred_v7_${ts}" | sha256sum | cut -c1-16)
  cat > "${COMMS_DIR}/${msg_id}.json" << EOF
{
  "id": "${msg_id}",
  "from": "${child_hash}",
  "to": "broadcast",
  "payload_hash": "${child_hash}",
  "message": "bred_v7:p1=${p1hash}:p2=${p2hash}:closure=${child_closure}:phi=${child_phi}",
  "timestamp": ${ts},
  "ttl": 3600,
  "signature": "${child_hash}",
  "status": "broadcast",
  "type": "breeding"
}
EOF

  return 0
}

# ─── Evolution status ───────────────────────────────────────────────────────

cmd_status() {
  list=$(collect_universes)
  count=0
  for f in $list; do count=$((count + 1)); done

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     EVOLUTION STATUS v0.7.0                  ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  printf "  Active universes:    %d\n" "$count"
  printf "  Hidden size:         %d\n" "$HIDDEN_SIZE"
  printf "  Attention heads:     %d\n" "$N_HEADS"
  printf "  Tournament size:     %d\n" "$TOURNAMENT_SIZE"
  printf "  Mutation rate:       %.4f\n" "$MUTATION_RATE"
  printf "  Crossover rate:      %.4f\n" "$CROSSOVER_RATE"
  echo ""

  if [ -f "$STATE_FILE" ]; then
    phi=$(json_get "$STATE_FILE" "phi")
    entropy=$(json_get "$STATE_FILE" "entropy")
    closure=$(json_get "$STATE_FILE" "closure_score")
    steps=$(json_get "$STATE_FILE" "steps")
    hash=$(json_get "$STATE_FILE" "hash")
    printf "  Parent phi:          %.4f\n" "$phi"
    printf "  Parent entropy:      %.4f\n" "$entropy"
    printf "  Parent closure:      %.4f\n" "$closure"
    printf "  Parent steps:        %s\n" "$steps"
    printf "  Parent hash:         %s\n" "$hash"
  fi
  echo ""

  # Best fitness
  best_fit=0
  best_name=""
  for f in $list; do
    name=$(basename "$f" _state.json)
    fit=$(compute_fitness "$f")
    if [ "$(echo "$fit > $best_fit" | bc -l 2>/dev/null)" = "1" ]; then
      best_fit=$fit
      best_name="$name"
    fi
  done
  printf "  Best universe:       %s\n" "$best_name"
  printf "  Best fitness:        %.6f\n" "$best_fit"
  echo ""

  # Comms count
  comms_count=$(ls "$COMMS_DIR"/*.json 2>/dev/null | wc -l)
  printf "  Comms messages:      %d\n" "$comms_count"
  echo ""

  # Recent history
  if [ -f "$HISTORY_FILE" ]; then
    echo "  Recent history:"
    tail -5 "$HISTORY_FILE" | while read line; do echo "    $line"; done
  fi
  echo ""
}

# ─── Full evolution report ──────────────────────────────────────────────────

cmd_report() {
  list=$(collect_universes)
  count=0
  for f in $list; do count=$((count + 1)); done

  ts=$(date +%s)
  report_file="${BASE_DIR}/evolution/evolution_report_${ts}.txt"

  {
    echo "============================================"
    echo "  EVOLUTION REPORT v0.7.0"
    echo "  Generated: $(date)"
    echo "============================================"
    echo ""
    echo "Population: $count universes"
    echo "Hidden size: $HIDDEN_SIZE"
    echo "Heads: $N_HEADS"
    echo ""

    # Score each universe
    echo "--- FITNESS SCORES ---"
    best_fit=0
    best_name=""
    total_fit=0
    for f in $list; do
      name=$(basename "$f" _state.json)
      fit=$(compute_fitness "$f")
      total_fit=$(echo "$total_fit + $fit" | bc)
      printf "  %-30s %.6f\n" "$name" "$fit"
      if [ "$(echo "$fit > $best_fit" | bc -l 2>/dev/null)" = "1" ]; then
        best_fit=$fit
        best_name="$name"
      fi
    done
    avg_fit=$(echo "scale=6; $total_fit / $count" | bc 2>/dev/null || echo "0")
    echo ""
    echo "Best: $best_name ($best_fit)"
    echo "Average: $avg_fit"

    echo ""
    echo "--- CAUSAL WALL ---"
    intact=0
    breached=0
    for f in $list; do
      name=$(basename "$f" _state.json)
      hash=$(json_get "$f" "hash")
      closure=$(json_get "$f" "closure_score")
      entropy=$(json_get "$f" "entropy")
      phi=$(json_get "$f" "phi")
      hs=$(json_get "$f" "hidden_size")
      computed=$(echo "$hash $closure $entropy $phi $hs" | sha256sum | cut -c1-16)
      if [ "$hash" = "$computed" ]; then
        echo "  $name: INTACT"
        intact=$((intact + 1))
      else
        echo "  $name: BREACHED"
        breached=$((breached + 1))
      fi
    done
    echo "Intact: $intact, Breached: $breached"

    echo ""
    echo "--- DIVERSITY ---"
    echo "Unique closure values:"
    for f in $list; do
      c=$(json_get "$f" "closure_score")
      echo "  $c"
    done | sort -u | wc -l | xargs echo "  Count:"

    echo ""
    echo "--- RECOMMENDATIONS ---"
    if [ "$breached" -gt 0 ]; then
      echo "  🔴 Fix $breached breached causal walls"
    fi
    if [ "$(echo "$avg_fit < 0.5" | bc -l 2>/dev/null)" = "1" ]; then
      echo "  🔴 Low average fitness ($avg_fit) — increase mutation rate"
    fi
    if [ "$count" -lt 5 ]; then
      echo "  🟡 Small population ($count) — breed more children"
    fi
    if [ "$(echo "$best_fit > 0.8" | bc -l 2>/dev/null)" = "1" ]; then
      echo "  🟢 High fitness ($best_fit) — consider spawning to new environments"
    fi

    echo ""
    echo "============================================"
  } > "$report_file"

  echo "  Report saved: $report_file"
  cat "$report_file"
}

# ─── Main evolution cycle ───────────────────────────────────────────────────

cmd_evolve() {
  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     EVOLUTION CYCLE v0.7.0                   ║"
  echo "  ║     Selection → Crossover → Mutation →       ║"
  echo "  ║     Spawn → Verify → Report                  ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  # Step 1: Verify causal wall
  echo "  Step 1: Verifying causal wall..."
  verify_causal_wall
  wall_status=$?
  echo ""

  # Step 2: Score fitness
  echo "  Step 2: Scoring fitness..."
  list=$(collect_universes)
  count=0
  for f in $list; do count=$((count + 1)); done

  if [ "$count" -lt 2 ]; then
    echo "  ⚠️  Only $count universe(s). Spawning from parent..."
    if [ -f "$STATE_FILE" ]; then
      ts=$(date +%s)
      parent_hash=$(json_get "$STATE_FILE" "hash")
      parent_closure=$(json_get "$STATE_FILE" "closure_score")
      parent_entropy=$(json_get "$STATE_FILE" "entropy")
      mutation=$(echo "scale=6; 0.2 * ($RANDOM % 200 - 100) / 100" | bc 2>/dev/null || echo "0")
      child_closure=$(echo "scale=6; $parent_closure * (1 + $mutation)" | bc 2>/dev/null || echo "0.5")
      [ "$(echo "$child_closure > 1" | bc -l 2>/dev/null)" = "1" ] && child_closure=1
      [ "$(echo "$child_closure < 0" | bc -l 2>/dev/null)" = "1" ] && child_closure=0
      child_name="child_v7_auto_${ts}"
      child_hash=$(echo "$parent_hash $ts $child_closure" | sha256sum | cut -c1-16)

      cat > "${CHILD_DIR}/${child_name}_state.json" << EOF
{
  "name": "${child_name}",
  "hash": "${child_hash}",
  "created": ${ts},
  "hidden_size": ${HIDDEN_SIZE},
  "n_heads": ${N_HEADS},
  "closure_score": ${child_closure},
  "entropy": ${parent_entropy},
  "phi": 0.0,
  "sm_accuracy": 0.0,
  "variance": 0.0,
  "comms_received": 0,
  "comms_sent": 0,
  "last_comms_broadcast": 0,
  "parent": "${parent_hash}",
  "generation": "v7"
}
EOF
      echo "  ✨ Auto-spawned: ${child_name} (closure: ${child_closure})"
    fi
  fi

  # Step 3: Breed
  echo ""
  echo "  Step 3: Breeding..."
  cmd_breed

  # Step 4: Verify again
  echo ""
  echo "  Step 4: Post-breeding verification..."
  verify_causal_wall

  # Step 5: Generate report
  echo ""
  echo "  Step 5: Report..."
  cmd_report

  # Log to history
  best_fit=0
  for f in $(collect_universes); do
    fit=$(compute_fitness "$f")
    [ "$(echo "$fit > $best_fit" | bc -l 2>/dev/null)" = "1" ] && best_fit=$fit
  done
  echo "EVO|$(date +%s)|count=$count|best=$best_fit|wall=$wall_status|hs=$HIDDEN_SIZE" >> "$EVOLUTION_FILE"

  echo ""
  echo "  ✅ Evolution cycle complete"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

[ $# -eq 0 ] && { cmd_evolve; exit 0; }

case "$1" in
  --status) cmd_status ;;
  --fitness) cmd_fitness ;;
  --breed) cmd_breed ;;
  --verify-causal-wall) verify_causal_wall ;;
  --report) cmd_report ;;
  --help|-h) usage ;;
  *) echo "Unknown: $1"; usage ;;
esac
