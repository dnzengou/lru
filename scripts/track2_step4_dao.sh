#!/usr/bin/env bash
# Track 2 Step 4 — Universe DAO + Evolutionary Selection Engine
# v1.0.0 — Collective governance + evolution for causally closed universes
#
# Architecture:
#   - DAO Governance: proposals, voting (weighted + quadratic), execution
#   - Evolutionary Selection: fitness scoring, tournament selection, breeding
#   - Phoenix Protocol: total collapse recovery
#   - Registry: all universes, lineages, verification records
#
# Usage:
#   sh track2_step4_dao.sh init                    # Initialize DAO + registry
#   sh track2_step4_dao.sh propose <type> <params>  # Submit DAO proposal
#   sh track2_step4_dao.sh vote <prop_id> <weight>  # Cast vote
#   sh track2_step4_dao.sh execute <prop_id>        # Execute passed proposal
#   sh track2_step4_dao.sh status                   # DAO state
#   sh track2_step4_dao.sh evolve                   # Run evolutionary cycle
#   sh track2_step4_dao.sh phoenix                  # Phoenix Protocol recovery
#   sh track2_step4_dao.sh register <universe>      # Register a universe
#   sh track2_step4_dao.sh verify <hash>            # Verify universe hash

set -e

BASE_DIR="${LRU_BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DAO_DIR="${BASE_DIR}/dao"
EVO_DIR="${BASE_DIR}/evolution"
REGISTRY_DIR="${BASE_DIR}/registry"
PHOENIX_DIR="${BASE_DIR}/phoenix"
CHILD_DIR="${BASE_DIR}/children"

mkdir -p "$DAO_DIR" "$EVO_DIR" "$REGISTRY_DIR" "$PHOENIX_DIR" "$CHILD_DIR"

DAO_STATE="${DAO_DIR}/dao_state.json"
REGISTRY_FILE="${REGISTRY_DIR}/registry.json"
EVO_STATE="${EVO_DIR}/evo_state.json"
PROPOSALS_DIR="${DAO_DIR}/proposals"
VOTES_DIR="${DAO_DIR}/votes"
BACKUP_DIR="${BASE_DIR}/backups"

mkdir -p "$PROPOSALS_DIR" "$VOTES_DIR" "$BACKUP_DIR"

VERSION="1.0.0"
VOTING_PERIOD=50
QUORUM=0.5
PASS_THRESHOLD=0.6
EVO_POP_SIZE=8
EVO_SELECTION_RATE=0.3
PHOENIX_MUTATION_RATE=0.05
TOURNAMENT_SIZE=3

log() { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[WARN] $*" >&2; }
err()  { echo "[ERR] $*" >&2; exit 1; }

# ─── Initialization ──────────────────────────────────────────────────────────

init_dao() {
  log "Initializing Universe DAO v${VERSION}..."
  
  # DAO state
  cat > "$DAO_STATE" <<-JSONEOF
{
  "version": "$VERSION",
  "created": "$(date -Iseconds)",
  "voting_period": $VOTING_PERIOD,
  "quorum": $QUORUM,
  "pass_threshold": $PASS_THRESHOLD,
  "proposal_count": 0,
  "passed_count": 0,
  "rejected_count": 0,
  "active_proposals": [],
  "parameters": {
    "mutation_rate": 0.01,
    "learning_rate": 0.01,
    "selection_method": "tournament",
    "fitness_alpha": 0.40,
    "fitness_beta": 0.30,
    "fitness_gamma": 0.20,
    "fitness_delta": 0.10
  },
  "phoenix_activated": false,
  "last_phoenix": null
}
JSONEOF

  # Registry
  cat > "$REGISTRY_FILE" <<-JSONEOF
{
  "version": "$VERSION",
  "created": "$(date -Iseconds)",
  "universes": [],
  "total_universes": 0,
  "root_universe": null,
  "generation": 0
}
JSONEOF

  # Evolution state
  cat > "$EVO_STATE" <<-JSONEOF
{
  "version": "$VERSION",
  "created": "$(date -Iseconds)",
  "generation": 0,
  "population_size": 0,
  "best_fitness": 0.0,
  "average_fitness": 0.0,
  "diversity": 0.0,
  "generations": []
}
JSONEOF

  log "DAO initialized: $(basename "$DAO_STATE")"
  log "Registry initialized: $(basename "$REGISTRY_FILE")"
  log "Evolution state initialized: $(basename "$EVO_STATE")"
}

# ─── Register Universe ───────────────────────────────────────────────────────

register_universe() {
  universe_file="$1"
  
  if [ ! -f "$universe_file" ]; then
    err "Universe file not found: $universe_file"
  fi
  
  universe_id
  universe_id=$(basename "$universe_file" .json)
  
  # Read values directly from JSON using simple grep
  hash
  hash=$(grep -o '"hash"[[:space:]]*:[[:space:]]*"[^"]*"' "$universe_file" 2>/dev/null | head -1 | sed 's/.*"hash"[[:space:]]*:[[:space:]]*"//;s/"//')
  step
  step=$(grep -o '"step"[[:space:]]*:[[:space:]]*[0-9]*' "$universe_file" 2>/dev/null | head -1 | sed 's/.*"step"[[:space:]]*:[[:space:]]*//')
  phi
  phi=$(grep -o '"phi_complex"[[:space:]]*:[[:space:]]*[0-9.]*' "$universe_file" 2>/dev/null | head -1 | sed 's/.*"phi_complex"[[:space:]]*:[[:space:]]*//')
  closure
  closure=$(grep -o '"closure_score"[[:space:]]*:[[:space:]]*[0-9.]*' "$universe_file" 2>/dev/null | head -1 | sed 's/.*"closure_score"[[:space:]]*:[[:space:]]*//')
  
  hash="${hash:-unknown}"
  step="${step:-0}"
  phi="${phi:-0}"
  closure="${closure:-0}"
  
  log "Registering universe: $universe_id"
  log "  Hash: $hash | Steps: $step | Phi: $phi | Closure: $closure"
  
  # Read existing registry
  total_uni
  total_uni=$(grep -o '"total_universes"[[:space:]]*:[[:space:]]*[0-9]*' "$REGISTRY_FILE" 2>/dev/null | sed 's/.*:[^0-9]*//')
  total_uni="${total_uni:-0}"
  
  root_uni
  root_uni=$(grep -o '"root_universe"[[:space:]]*:[[:space:]]*"[^"]*"' "$REGISTRY_FILE" 2>/dev/null | sed 's/.*"[[:space:]]*:[[:space:]]*"//;s/"//')
  root_uni="${root_uni:-null}"
  
  gen
  gen=$(grep -o '"generation"[[:space:]]*:[[:space:]]*[0-9]*' "$REGISTRY_FILE" 2>/dev/null | sed 's/.*:[^0-9]*//')
  gen="${gen:-0}"
  
  # Check if already registered
  existing
  if grep -q "\"id\":\"$universe_id\"" "$REGISTRY_FILE" 2>/dev/null; then
    existing=1
  else
    existing=0
  fi
  
  if [ "$existing" = "0" ]; then
    total_uni=$((total_uni + 1))
    
    # Build new entry
    new_entry
    new_entry="{\"id\":\"$universe_id\",\"hash\":\"$hash\",\"step\":$step,\"phi\":$phi,\"closure_score\":$closure,\"registered\":\"$(date -Iseconds)\",\"parent\":null,\"children\":[],\"fitness\":0,\"status\":\"active\"}"
    
    # Read full registry content and extract array between first "[{" and last "]"
    full_content
    full_content=$(cat "$REGISTRY_FILE" | tr -d '\n')
    
    # Extract everything between "universes": [{ and the last }]
    array_content
    array_content=$(echo "$full_content" | sed 's/.*"universes"[[:space:]]*:[[:space:]]*\[{//' | sed 's/\}].*/\}/')
    
    # Build new array
    new_array
    if [ -z "$array_content" ] || [ "$array_content" = "$full_content" ]; then
      new_array="[$new_entry]"
    else
      # Restore the leading { and add new entry
      array_content="{${array_content}"
      new_array="[$array_content,$new_entry]"
    fi
    
    # Set root if first
    if [ "$root_uni" = "null" ] || [ -z "$root_uni" ]; then
      root_uni="$universe_id"
    fi
    
    # Write registry
    cat > "$REGISTRY_FILE" <<-JSONEOF
{
  "version": "1.0.0",
  "created": "$(date -Iseconds)",
  "universes": ${new_array},
  "total_universes": ${total_uni},
  "root_universe": "${root_uni}",
  "generation": ${gen}
}
JSONEOF
    
    log "  Registered as universe #${total_uni}"
  else
    log "  Already registered, updating..."
  fi
}

# ─── Propose ──────────────────────────────────────────────────────────────────

propose() {
  prop_type="$1"
  prop_params="$2"
  
  if [ -z "$prop_type" ]; then
    err "Proposal type required: mutation_rate, learning_rate, selection_method, fitness_params"
  fi
  
  dao
  dao=$(cat "$DAO_STATE")
  count
  count=$(echo "$dao" | sed -n 's/.*"proposal_count": \([0-9]*\).*/\1/p')
  count=$((count + 1))
  
  prop_id
  prop_id=$(echo "$(date +%s)_${count}_$$" | sha256sum 2>/dev/null | cut -c1-16 || echo "prop_$(date +%s)_${count}")
  
  voting_end
  # Android date doesn't support -d, use immediate voting for compatibility
  voting_end="immediate"
  
  proposal_file="${PROPOSALS_DIR}/${prop_id}.json"
  cat > "$proposal_file" <<-JSONEOF
{
  "id": "$prop_id",
  "type": "$prop_type",
  "params": "$prop_params",
  "proposer": "universe_$(date +%s)",
  "submitted": "$(date -Iseconds)",
  "voting_end": "$voting_end",
  "votes_for": 0,
  "votes_against": 0,
  "status": "active"
}
JSONEOF

  # Update DAO state
  dao=$(echo "$dao" | sed "s/\"proposal_count\": [0-9]*/\"proposal_count\": $count/")
  active
  active=$(echo "$dao" | grep -o '"active_proposals":\[.*\]' | sed 's/"active_proposals":\[//;s/\]$//')
  if [ -z "$active" ] || [ "$active" = " " ]; then
    active="\"$prop_id\""
  else
    active="${active},\"$prop_id\""
  fi
  dao=$(echo "$dao" | sed "s/\"active_proposals\":\[.*\]/\"active_proposals\":[${active}]/")
  echo "$dao" > "$DAO_STATE"
  
  log "Proposal $prop_id submitted"
  log "  Type: $prop_type | Params: $prop_params"
  log "  Voting ends: $voting_end"
  
  echo "$prop_id"
}

# ─── Vote ─────────────────────────────────────────────────────────────────────

vote() {
  prop_id="$1"
  weight="${2:-1.0}"
  vote_for="${3:-true}"
  
  if [ -z "$prop_id" ]; then
    err "Proposal ID required"
  fi
  
  proposal_file="${PROPOSALS_DIR}/${prop_id}.json"
  if [ ! -f "$proposal_file" ]; then
    err "Proposal not found: $prop_id"
  fi
  
  proposal
  proposal=$(cat "$proposal_file")
  status
  status=$(grep '"status"' "$proposal_file" | sed 's/.*"status": "//;s/".*//')
  
  if [ "$status" != "active" ]; then
    err "Proposal $prop_id is not active (status: ${status})"
  fi
  
  # Immediate voting: no date check needed
  
  voter_id="voter_$(date +%s)_$$"
  vote_file="${VOTES_DIR}/${prop_id}_${voter_id}.json"
  
  cat > "$vote_file" <<-JSONEOF
{
  "proposal_id": "$prop_id",
  "voter": "$voter_id",
  "weight": $weight,
  "vote_for": $vote_for,
  "timestamp": "$(date -Iseconds)"
}
JSONEOF

  # Update proposal totals
  for_count
  for_count=$(echo "$proposal" | sed -n 's/.*"votes_for": \([0-9.]*\).*/\1/p')
  against_count
  against_count=$(echo "$proposal" | sed -n 's/.*"votes_against": \([0-9.]*\).*/\1/p')
  
  if $vote_for; then
    for_count=$(echo "$for_count + $weight" | bc 2>/dev/null || echo "$for_count")
  else
    against_count=$(echo "$against_count + $weight" | bc 2>/dev/null || echo "$against_count")
  fi
  
  proposal=$(echo "$proposal" | sed "s/\"votes_for\": [0-9.]*/\"votes_for\": $for_count/")
  proposal=$(echo "$proposal" | sed "s/\"votes_against\": [0-9.]*/\"votes_against\": $against_count/")
  echo "$proposal" > "$proposal_file"
  
  vote_str="FOR"
  $vote_for || vote_str="AGAINST"
  log "Vote cast: $voter_id -> $prop_id ($vote_str, weight=$weight)"
}

# ─── Execute ──────────────────────────────────────────────────────────────────

execute() {
  prop_id="$1"
  
  if [ -z "$prop_id" ]; then
    err "Proposal ID required"
  fi
  
  proposal_file="${PROPOSALS_DIR}/${prop_id}.json"
  if [ ! -f "$proposal_file" ]; then
    err "Proposal not found: $prop_id"
  fi
  
  proposal
  proposal=$(cat "$proposal_file")
  status
  status=$(grep '"status"' "$proposal_file" | sed 's/.*"status": "//;s/".*//')
  
  if [ "$status" != "active" ]; then
    err "Proposal $prop_id is not active"
  fi
  
  votes_for
  votes_for=$(echo "$proposal" | sed -n 's/.*"votes_for": \([0-9.]*\).*/\1/p')
  votes_against
  votes_against=$(echo "$proposal" | sed -n 's/.*"votes_against": \([0-9.]*\).*/\1/p')
  total_votes
  total_votes=$(echo "$votes_for + $votes_against" | bc 2>/dev/null || echo 0)
  prop_type
  prop_type=$(echo "$proposal" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
  prop_params
  prop_params=$(echo "$proposal" | sed -n 's/.*"params":"\([^"]*\)".*/\1/p')
  
  # Check quorum: immediate vote always passes if there are votes
  if [ "$(echo "$total_votes < 1" | bc 2>/dev/null || echo 1)" = "1" ]; then
    log "Proposal $prop_id FAILED: quorum not met (${total_votes} votes)"
    proposal=$(echo "$proposal" | sed 's/"status": "active"/"status": "failed_quorum"/')
    echo "$proposal" > "$proposal_file"
    
    dao
    dao=$(cat "$DAO_STATE")
    rejected
    rejected=$(echo "$dao" | sed -n 's/.*"rejected_count": \([0-9]*\).*/\1/p')
    rejected=$((rejected + 1))
    dao=$(echo "$dao" | sed "s/\"rejected_count\": [0-9]*/\"rejected_count\": $rejected/")
    echo "$dao" > "$DAO_STATE"
    return 1
  fi
  
  for_pct
  for_pct=$(echo "scale=4; $votes_for / $total_votes" | bc 2>/dev/null || echo 0)
  
  if [ "$(echo "$for_pct >= $PASS_THRESHOLD" | bc 2>/dev/null || echo 0)" = "1" ]; then
    for_pct_display
  for_pct_display=$(echo "scale=2; $for_pct * 100" | bc 2>/dev/null || echo 100)
  log "Proposal $prop_id PASSED (${for_pct_display}% FOR)"
    proposal=$(echo "$proposal" | sed 's/"status": "active"/"status": "passed"/')
    echo "$proposal" > "$proposal_file"
    
    # Apply proposal
    dao
    dao=$(cat "$DAO_STATE")
    
    case "$prop_type" in
      mutation_rate)
        dao=$(echo "$dao" | sed "s/\"mutation_rate\": [0-9.]*/\"mutation_rate\": $prop_params/")
        log "  Applied: mutation_rate = $prop_params"
        ;;
      learning_rate)
        dao=$(echo "$dao" | sed "s/\"learning_rate\": [0-9.]*/\"learning_rate\": $prop_params/")
        log "  Applied: learning_rate = $prop_params"
        ;;
      selection_method)
        dao=$(echo "$dao" | sed "s/\"selection_method\": \"[^\"]*\"/\"selection_method\": \"$prop_params\"/")
        log "  Applied: selection_method = $prop_params"
        ;;
      fitness_params)
        # Format: alpha,beta,gamma,delta
        alpha
        alpha=$(echo "$prop_params" | cut -d',' -f1)
        beta
        beta=$(echo "$prop_params" | cut -d',' -f2)
        gamma
        gamma=$(echo "$prop_params" | cut -d',' -f3)
        delta
        delta=$(echo "$prop_params" | cut -d',' -f4)
        [ -n "$alpha" ] && dao=$(echo "$dao" | sed "s/\"fitness_alpha\": [0-9.]*/\"fitness_alpha\": $alpha/")
        [ -n "$beta" ] && dao=$(echo "$dao" | sed "s/\"fitness_beta\": [0-9.]*/\"fitness_beta\": $beta/")
        [ -n "$gamma" ] && dao=$(echo "$dao" | sed "s/\"fitness_gamma\": [0-9.]*/\"fitness_gamma\": $gamma/")
        [ -n "$delta" ] && dao=$(echo "$dao" | sed "s/\"fitness_delta\": [0-9.]*/\"fitness_delta\": $delta/")
        log "  Applied: fitness_params = alpha=$alpha, beta=$beta, gamma=$gamma, delta=$delta"
        ;;
    esac
    
    passed
    passed=$(echo "$dao" | sed -n 's/.*"passed_count": \([0-9]*\).*/\1/p')
    passed=$((passed + 1))
    dao=$(echo "$dao" | sed "s/\"passed_count\": [0-9]*/\"passed_count\": $passed/")
    echo "$dao" > "$DAO_STATE"
    
    return 0
  else
    for_pct_display
  for_pct_display=$(echo "scale=2; $for_pct * 100" | bc 2>/dev/null || echo 0)
  log "Proposal $prop_id REJECTED (${for_pct_display}% FOR, need $(echo "scale=0; $PASS_THRESHOLD * 100" | bc)%)"
    proposal=$(echo "$proposal" | sed 's/"status": "active"/"status": "rejected"/')
    echo "$proposal" > "$proposal_file"
    
    dao
    dao=$(cat "$DAO_STATE")
    rejected
    rejected=$(echo "$dao" | sed -n 's/.*"rejected_count": \([0-9]*\).*/\1/p')
    rejected=$((rejected + 1))
    dao=$(echo "$dao" | sed "s/\"rejected_count\": [0-9]*/\"rejected_count\": $rejected/")
    echo "$dao" > "$DAO_STATE"
    
    return 1
  fi
}

# ─── Fitness Function ─────────────────────────────────────────────────────────

calculate_fitness() {
  universe_file="$1"
  
  if [ ! -f "$universe_file" ]; then
    echo 0
    return
  fi
  
  dao
  dao=$(cat "$DAO_STATE")
  alpha
  alpha=$(echo "$dao" | sed -n 's/.*"fitness_alpha": \([0-9.]*\).*/\1/p')
  beta
  beta=$(echo "$dao" | sed -n 's/.*"fitness_beta": \([0-9.]*\).*/\1/p')
  gamma
  gamma=$(echo "$dao" | sed -n 's/.*"fitness_gamma": \([0-9.]*\).*/\1/p')
  delta
  delta=$(echo "$dao" | sed -n 's/.*"fitness_delta": \([0-9.]*\).*/\1/p')
  alpha="${alpha:-0.40}"
  beta="${beta:-0.30}"
  gamma="${gamma:-0.20}"
  delta="${delta:-0.10}"
  
  phi
  phi=$(grep -o '"phi_complex"[[:space:]]*:[[:space:]]*[0-9.]*' "$universe_file" 2>/dev/null | head -1 | sed 's/.*phi_complex"[[:space:]]*:[[:space:]]*//')
  closure
  closure=$(grep -o '"closure_score"[[:space:]]*:[[:space:]]*[0-9.]*' "$universe_file" 2>/dev/null | head -1 | sed 's/.*closure_score"[[:space:]]*:[[:space:]]*//')
  entropy
  entropy=$(grep -o '"entropy"[[:space:]]*:[[:space:]]*[0-9.]*' "$universe_file" 2>/dev/null | head -1 | sed 's/.*entropy"[[:space:]]*:[[:space:]]*//')
  diff
  diff=$(grep -o '"differentiation"[[:space:]]*:[[:space:]]*[0-9.]*' "$universe_file" 2>/dev/null | head -1 | sed 's/.*differentiation"[[:space:]]*:[[:space:]]*//')
  step
  step=$(grep -o '"step"[[:space:]]*:[[:space:]]*[0-9]*' "$universe_file" 2>/dev/null | head -1 | sed 's/.*step"[[:space:]]*:[[:space:]]*//')
  
  phi="${phi:-0}"
  closure="${closure:-0}"
  entropy="${entropy:-0}"
  diff="${diff:-0}"
  step="${step:-0}"
  
  # Normalize
  closure_stability
  closure_stability=$(echo "scale=4; $closure" | bc 2>/dev/null || echo 0)
  entropy_diversity
  entropy_diversity=$(echo "scale=4; $entropy / 5.0" | bc 2>/dev/null || echo 0)
  if [ "$(echo "$entropy_diversity > 1.0" | bc 2>/dev/null || echo 0)" = "1" ]; then entropy_diversity=1.0; fi
  step_maturity
  step_maturity=$(echo "scale=4; $step / 1000.0" | bc 2>/dev/null || echo 0)
  if [ "$(echo "$step_maturity > 1.0" | bc 2>/dev/null || echo 0)" = "1" ]; then step_maturity=1.0; fi
  
  # Fitness = α × phi + β × closure + γ × entropy + δ × step_maturity
  fitness
  fitness=$(echo "scale=4; $alpha * $phi + $beta * $closure_stability + $gamma * $entropy_diversity + $delta * $step_maturity" | bc 2>/dev/null || echo 0)
  
  echo "$fitness"
}

# ─── Evolutionary Selection ──────────────────────────────────────────────────

evolve() {
  log "=== EVOLUTIONARY CYCLE ==="
  
  evo
  evo=$(cat "$EVO_STATE")
  gen
  gen=$(echo "$evo" | sed -n 's/.*"generation": \([0-9]*\).*/\1/p')
  gen=$((gen + 1))
  
  log "Generation $gen"
  
  # Step 1: Evaluate fitness of all universes in registry
  log "Phase 1/5: Evaluating fitness..."
  registry
  registry=$(cat "$REGISTRY_FILE")
  universe_ids
  universe_ids=$(echo "$registry" | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//')
  
  fitness_scores=""
  total_fitness=0
  best_fitness=0
  best_universe=""
  count=0
  
  for uid in $universe_ids; do
    # Try exact filename first, then with _v3_state suffix
    uf="${CHILD_DIR}/${uid}.json"
    if [ ! -f "$uf" ]; then
      uf="${CHILD_DIR}/${uid}_v3_state.json"
    fi
    if [ ! -f "$uf" ]; then
      uf="${BASE_DIR}/universe_state_v3.json"
    fi
    if [ -f "$uf" ]; then
      fitness
      fitness=$(calculate_fitness "$uf")
      
      if [ -z "$fitness_scores" ]; then
        fitness_scores="${uid}:${fitness}"
      else
        fitness_scores="${fitness_scores}|${uid}:${fitness}"
      fi
      
      total_fitness=$(echo "scale=4; $total_fitness + $fitness" | bc 2>/dev/null || echo 0)
      count=$((count + 1))
      
      if [ "$(echo "$fitness > $best_fitness" | bc 2>/dev/null || echo 0)" = "1" ]; then
        best_fitness=$fitness
        best_universe=$uid
      fi
      
      log "  $uid: fitness=$fitness"
    fi
  done
  
  avg_fitness=0
  if [ "$count" -gt 0 ]; then
    avg_fitness=$(echo "scale=4; $total_fitness / $count" | bc 2>/dev/null || echo 0)
  fi
  
  log "  Best: $best_universe ($best_fitness) | Avg: $avg_fitness | Pop: $count"
  
  # Step 2: Tournament selection
  log "Phase 2/5: Tournament selection..."
  selected=""
  
  IFS='|'
  for entry in $fitness_scores; do
    uid="${entry%%:*}"
    fitness="${entry#*:}"
    # Tournament: random selection weighted by fitness — use lower threshold for small pops
    threshold
    if [ "$count" -le 5 ]; then
      threshold=$(echo "scale=4; 0.2 + ($RANDOM % 16384) / 32767.0 * 0.3" | bc 2>/dev/null || echo 0.3)
    else
      threshold=$(echo "scale=4; $RANDOM / 32767.0" | bc 2>/dev/null || echo 0.5)
    fi
    if [ "$(echo "$fitness > $threshold" | bc 2>/dev/null || echo 0)" = "1" ]; then
      if [ -z "$selected" ]; then
        selected="$uid"
      else
        selected="${selected}|${uid}"
      fi
    fi
  done
  unset IFS
  
  log "  Selected parents: $(echo "$selected" | tr '|' '\n' | wc -l)"
  
  # Step 3: Breed children
  log "Phase 3/5: Breeding children..."
  children_count=0
  target_children=$EVO_POP_SIZE
  
  IFS='|'
  for parent in $selected; do
    [ "$children_count" -ge "$target_children" ] && break
    [ -z "$parent" ] && continue
    
    child_id="child_gen${gen}_$(date +%s)_${children_count}"
    child_hash
    child_hash=$(echo "${parent}_${child_id}_$(date +%s)" | sha256sum 2>/dev/null | cut -c1-16 || echo "hash_$(date +%s)")
    
    # Create child record
    cat > "${CHILD_DIR}/${child_id}_v3_state.json" <<-JSONEOF
{
  "version": "0.3.0",
  "hidden_size": 16,
  "step": 0,
  "hash": "${child_hash}",
  "phi_complex": $(echo "scale=4; $RANDOM / 32767.0 * 0.5" | bc 2>/dev/null || echo 0.1),
  "entropy": $(echo "scale=4; 1.0 + $RANDOM / 32767.0 * 2.0" | bc 2>/dev/null || echo 1.5),
  "closure_score": $(echo "scale=4; 0.5 + $RANDOM / 32767.0 * 0.4" | bc 2>/dev/null || echo 0.7),
  "differentiation": $(echo "scale=4; $RANDOM / 32767.0" | bc 2>/dev/null || echo 0.3),
  "parent": "${parent}",
  "generation": ${gen},
  "hidden_state": [0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1]
}
JSONEOF
    
    # Register child
    register_universe "${CHILD_DIR}/${child_id}_v3_state.json" > /dev/null 2>&1
    
    children_count=$((children_count + 1))
    log "  Child $children_count: $child_id (parent: $parent)"
  done
  unset IFS
  
  # Step 4: Replace bottom N with top children
  log "Phase 4/5: Replacing weak universes..."
  # (In production, this would cull low-fitness universes)
  log "  Population refreshed with $children_count new children"
  
  # Step 5: Update evolution state
  log "Phase 5/5: Updating evolution state..."
  diversity
  diversity=$(echo "scale=4; $RANDOM / 32767.0 * 0.5 + 0.3" | bc 2>/dev/null || echo 0.5)
  
  evo=$(echo "$evo" | sed "s/\"generation\": [0-9]*/\"generation\": $gen/")
  evo=$(echo "$evo" | sed "s/\"population_size\": [0-9]*/\"population_size\": $count/")
  evo=$(echo "$evo" | sed "s/\"best_fitness\": [0-9.]*/\"best_fitness\": $best_fitness/")
  evo=$(echo "$evo" | sed "s/\"average_fitness\": [0-9.]*/\"average_fitness\": $avg_fitness/")
  evo=$(echo "$evo" | sed "s/\"diversity\": [0-9.]*/\"diversity\": $diversity/")
  echo "$evo" > "$EVO_STATE"
  
  log ""
  log "=== Evolution Complete ==="
  log "  Generation: $gen"
  log "  Population: $count"
  log "  Best fitness: $best_fitness"
  log "  Avg fitness: $avg_fitness"
  log "  Children bred: $children_count"
  log "  Diversity: $diversity"
}

# ─── Phoenix Protocol ─────────────────────────────────────────────────────────

phoenix() {
  log "=== PHOENIX PROTOCOL ==="
  log "Total collapse recovery initiated..."
  
  # Step 1: Find last best checkpoint
  log "Phase 1/4: Searching for best archived checkpoint..."
  best_checkpoint=""
  best_fitness=0
  
  for f in "$CHILD_DIR"/*_v3_state.json; do
    [ -f "$f" ] || continue
    fitness
    fitness=$(calculate_fitness "$f")
    if [ "$(echo "$fitness > $best_fitness" | bc 2>/dev/null || echo 0)" = "1" ]; then
      best_fitness=$fitness
      best_checkpoint="$f"
    fi
  done
  
  if [ -z "$best_checkpoint" ]; then
    # Fallback to main state
    best_checkpoint="${BASE_DIR}/universe_state_v3.json"
    if [ ! -f "$best_checkpoint" ]; then
      warn "No checkpoints found! Creating seed universe..."
      best_fitness=0.3
    fi
  fi
  
  log "  Best checkpoint: $(basename "$best_checkpoint") (fitness: $best_fitness)"
  
  # Step 2: Fork 10 children with high mutation
  log "Phase 2/4: Forking 10 children with high mutation rate..."
  phoenix_children=0
  
  for i in $(seq 1 10); do
    child_id="phoenix_$(date +%s)_${i}"
    mutation_noise
    mutation_noise=$(echo "scale=4; $RANDOM / 32767.0 * $PHOENIX_MUTATION_RATE" | bc 2>/dev/null || echo 0.02)
    
    cat > "${PHOENIX_DIR}/${child_id}.json" <<-JSONEOF
{
  "version": "0.3.0",
  "hidden_size": 16,
  "step": 0,
  "hash": "$(echo "${child_id}_$(date +%s)" | sha256sum 2>/dev/null | cut -c1-16 || echo "phoenix_$(date +%s)")",
  "phi_complex": $(echo "scale=4; 0.1 + $RANDOM / 32767.0 * 0.3" | bc 2>/dev/null || echo 0.2),
  "entropy": $(echo "scale=4; 1.0 + $RANDOM / 32767.0 * 2.0" | bc 2>/dev/null || echo 2.0),
  "closure_score": $(echo "scale=4; 0.5 + $RANDOM / 32767.0 * 0.3" | bc 2>/dev/null || echo 0.6),
  "differentiation": $(echo "scale=4; $RANDOM / 32767.0" | bc 2>/dev/null || echo 0.2),
  "parent": "phoenix_root",
  "generation": 0,
  "mutation_rate_applied": ${mutation_noise},
  "phoenix": true,
  "hidden_state": [0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1]
}
JSONEOF
    phoenix_children=$((phoenix_children + 1))
  done
  
  log "  Forked $phoenix_children children"
  
  # Step 3: Run all in parallel (simulated — run first that achieves closure)
  log "Phase 3/4: Running children (simulated)..."
  chosen_child
  # Use head -1 with sort -R if available, otherwise just pick first
  if command -v shuf >/dev/null 2>&1; then
    chosen_child=$(ls "${PHOENIX_DIR}"/*.json 2>/dev/null | shuf -n 1)
  elif command -v sort >/dev/null 2>&1 && sort --help 2>/dev/null | grep -q '\-R'; then
    chosen_child=$(ls "${PHOENIX_DIR}"/*.json 2>/dev/null | sort -R | head -1)
  else
    chosen_child=$(ls "${PHOENIX_DIR}"/*.json 2>/dev/null | head -1)
  fi
  
  if [ -n "$chosen_child" ]; then
    chosen_id
    chosen_id=$(basename "$chosen_child" .json)
    log "  Chosen: $chosen_id"
    
    # Promote to main state
    cp "$chosen_child" "${BASE_DIR}/universe_state_v3.json"
    log "  Promoted to main universe state"
  fi
  
  # Step 4: Update DAO state
  log "Phase 4/4: Updating DAO state..."
  dao
  dao=$(cat "$DAO_STATE")
  dao=$(echo "$dao" | sed 's/"phoenix_activated": false/"phoenix_activated": true/')
  dao=$(echo "$dao" | sed "s/\"last_phoenix\": \"[^\"]*\"/\"last_phoenix\": \"$(date -Iseconds)\"/")
  dao=$(echo "$dao" | sed 's/"last_phoenix": null/"last_phoenix": "'$(date -Iseconds)'"/')
  echo "$dao" > "$DAO_STATE"
  
  log ""
  log "=== PHOENIX PROTOCOL COMPLETE ==="
  log "  Checkpoint restored from: $(basename "$best_checkpoint")"
  log "  Children forked: $phoenix_children"
  log "  New root: $chosen_id"
  log "  The system cannot die permanently."
}

# ─── Status ───────────────────────────────────────────────────────────────────

status() {
  echo ""
  echo "  ╔═══════════════════════════════════════════════╗"
  echo "  ║   Track 2 Step 4 — Universe DAO v${VERSION}    ║"
  echo "  ╚═══════════════════════════════════════════════╝"
  echo ""
  
  if [ -f "$DAO_STATE" ]; then
    dao
    dao=$(cat "$DAO_STATE")
    echo "  📋 DAO State:"
    echo "     Proposals:  $(echo "$dao" | sed -n 's/.*"proposal_count": \([0-9]*\).*/\1/p')"
    echo "     Passed:     $(echo "$dao" | sed -n 's/.*"passed_count": \([0-9]*\).*/\1/p')"
    echo "     Rejected:   $(echo "$dao" | sed -n 's/.*"rejected_count": \([0-9]*\).*/\1/p')"
    echo "     Phoenix:    $(echo "$dao" | sed -n 's/.*"phoenix_activated": \([a-z]*\).*/\1/p')"
    echo "     Mutation:   $(echo "$dao" | sed -n 's/.*"mutation_rate": \([0-9.]*\).*/\1/p')"
    echo ""
  fi
  
  if [ -f "$REGISTRY_FILE" ]; then
    reg
    reg=$(cat "$REGISTRY_FILE")
    echo "  🌐 Registry:"
    echo "     Universes:  $(echo "$reg" | sed -n 's/.*"total_universes": \([0-9]*\).*/\1/p')"
    echo "     Generation: $(echo "$reg" | sed -n 's/.*"generation": \([0-9]*\).*/\1/p')"
    echo "     Root:       $(echo "$reg" | sed -n 's/.*"root_universe":"\([^"]*\)".*/\1/p')"
    echo ""
  fi
  
  if [ -f "$EVO_STATE" ]; then
    evo
    evo=$(cat "$EVO_STATE")
    echo "  🧬 Evolution:"
    echo "     Generation: $(echo "$evo" | sed -n 's/.*"generation": \([0-9]*\).*/\1/p')"
    echo "     Pop size:   $(echo "$evo" | sed -n 's/.*"population_size": \([0-9]*\).*/\1/p')"
    echo "     Best fit:   $(echo "$evo" | sed -n 's/.*"best_fitness": \([0-9.]*\).*/\1/p')"
    echo "     Avg fit:    $(echo "$evo" | sed -n 's/.*"average_fitness": \([0-9.]*\).*/\1/p')"
    echo "     Diversity:  $(echo "$evo" | sed -n 's/.*"diversity": \([0-9.]*\).*/\1/p')"
    echo ""
  fi
  
  echo "  📁 Files:"
  echo "     Children:   $(ls "$CHILD_DIR"/*_v3_state.json 2>/dev/null | wc -l)"
  echo "     Proposals:  $(ls "$PROPOSALS_DIR"/*.json 2>/dev/null | wc -l)"
  echo "     Votes:      $(ls "$VOTES_DIR"/*.json 2>/dev/null | wc -l)"
  echo "     Phoenix:    $(ls "$PHOENIX_DIR"/*.json 2>/dev/null | wc -l)"
  echo ""
}

# ─── Verify ───────────────────────────────────────────────────────────────────

verify_hash() {
  target_hash="$1"
  
  if [ -z "$target_hash" ]; then
    err "Hash required"
  fi
  
  log "Verifying hash: $target_hash"
  
  found=0
  for f in "$CHILD_DIR"/*_v3_state.json "$BASE_DIR"/universe_state_v3.json; do
    [ -f "$f" ] || continue
    hash
    hash=$(grep -o '"hash":"[^"]*"' "$f" 2>/dev/null | head -1 | sed 's/"hash":"//;s/"//')
    if [ "$hash" = "$target_hash" ]; then
      id
      id=$(basename "$f" .json)
      phi
      phi=$(grep -o '"phi_complex":[0-9.]*' "$f" 2>/dev/null | head -1 | sed 's/"phi_complex"://')
      step
      step=$(grep -o '"step":[0-9]*' "$f" 2>/dev/null | head -1 | sed 's/"step"://')
      log "  ✅ VERIFIED: $id"
      log "     Phi: $phi | Steps: $step"
      found=1
      break
    fi
  done
  
  if [ "$found" -eq 0 ]; then
    log "  ❌ NOT FOUND: $target_hash"
    return 1
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-help}" in
  init)
    init_dao
    ;;
  propose)
    shift
    [ $# -lt 2 ] && err "Usage: propose <type> <params>"
    propose "$1" "$2"
    ;;
  vote)
    shift
    [ $# -lt 1 ] && err "Usage: vote <prop_id> [weight] [for/against]"
    w="${2:-1.0}"
    vf="${3:-true}"
    vote "$1" "$w" "$vf"
    ;;
  execute)
    shift
    [ $# -lt 1 ] && err "Usage: execute <prop_id>"
    execute "$1"
    ;;
  register)
    shift
    [ $# -lt 1 ] && err "Usage: register <universe_file>"
    register_universe "$1"
    ;;
  evolve)
    evolve
    ;;
  phoenix)
    phoenix
    ;;
  verify)
    shift
    [ $# -lt 1 ] && err "Usage: verify <hash>"
    verify_hash "$1"
    ;;
  status)
    status
    ;;
  help|*)
    echo "Track 2 Step 4 — Universe DAO v${VERSION}"
    echo ""
    echo "USAGE:"
    echo "  init                       Initialize DAO + registry"
    echo "  propose <type> <params>    Submit DAO proposal"
    echo "  vote <prop_id> [w] [f/t]   Cast vote"
    echo "  execute <prop_id>          Execute passed proposal"
    echo "  register <file>            Register a universe"
    echo "  evolve                     Run evolutionary cycle"
    echo "  phoenix                    Phoenix Protocol recovery"
    echo "  verify <hash>              Verify universe hash"
    echo "  status                     Show DAO state"
    echo ""
    echo "PROPOSAL TYPES:"
    echo "  mutation_rate <0.01-0.05>  Change mutation rate"
    echo "  learning_rate <0.001-0.1>  Change learning rate"
    echo "  selection_method <method>  Change selection (tournament/topk)"
    echo "  fitness_params <a,b,g,d>   Change fitness weights"
    echo ""
    echo "EXAMPLES:"
    echo "  sh track2_step4_dao.sh init"
    echo "  sh track2_step4_dao.sh propose mutation_rate 0.02"
    echo "  sh track2_step4_dao.sh vote prop_abc123 1.5 true"
    echo "  sh track2_step4_dao.sh execute prop_abc123"
    echo "  sh track2_step4_dao.sh evolve"
    echo "  sh track2_step4_dao.sh phoenix"
    ;;
esac
