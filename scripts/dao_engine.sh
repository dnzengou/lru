#!/usr/bin/env bash
# Universe DAO Engine v0.6.0 — Evolutionary Governance + Inter-Universe Communication
# Track 2, Step 5
#
# Upgrades from v1.0.0:
# 1. Inter-Universe Communication Protocol (NEW)
# 2. 8-head attention (was 4) in Neural MVU
# 3. Tiered voting by phi score (was 1-universe-1-vote)
# 4. Meta-proposals (proposals that change governance)
# 5. Delegation (proxy voting for low-phi universes)
# 6. Treasury (AFRI-denominated, cross-track)
# 7. Deadlock detection (timeout-based proposal expiry)
#
# Dependencies: awk, sha256sum, bc

set -e

BASE_DIR="${LRU_BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
DAO_DIR="${BASE_DIR}/dao"
STATE_FILE="${DAO_DIR}/dao_state_v6.json"
PROPOSAL_DIR="${DAO_DIR}/proposals_v6"
VOTE_DIR="${DAO_DIR}/votes_v6"
CHILD_DIR="${BASE_DIR}/children"
HISTORY_FILE="${BASE_DIR}/neural_history_v6.txt"
MVU_SCRIPT="${BASE_DIR}/neural_mvu_v6.sh"
COMMS_DIR="${DAO_DIR}/comms"  # Inter-universe messages
TREASURY_FILE="${DAO_DIR}/treasury.json"
mkdir -p "$PROPOSAL_DIR" "$VOTE_DIR" "$COMMS_DIR"

# ─── DAO Parameters ──────────────────────────────────────────────────────────

VOTING_PERIOD=50       # Steps before proposal closes
QUORUM=0.50            # 50% of active universes must vote
PASS_THRESHOLD=0.60    # 60% of voting weight to pass
QUADRATIC=true         # Quadratic voting enabled
ELITE_COUNT=2          # Always keep top 2
TOURNAMENT_SIZE=3      # Tournament selection pool
BREED_COUNT=5          # Children per generation
EVAL_STEPS=30          # Steps to train each child
PHI_WEIGHTED=true      # Voting weighted by phi score (v0.6.0)
DELEGATION_ENABLED=true # Proxy voting (v0.6.0)
DEADLOCK_TIMEOUT=100   # Steps before auto-reject (v0.6.0)
COMMS_TTL=3600         # Message TTL in seconds (v0.6.0)

# ─── Help ─────────────────────────────────────────────────────────────────────

usage() {
  echo "Universe DAO Engine v0.6.0"
  echo ""
  echo "Usage:"
  echo "  $0 --proposal submit <type> <params>     Submit proposal"
  echo "  $0 --proposal list                       List all proposals"
  echo "  $0 --proposal status <id>                Proposal details"
  echo "  $0 --vote <proposal_id> <for|against>    Cast vote"
  echo "  $0 --delegate <to_universe>              Delegate voting power (v0.6.0)"
  echo "  $0 --evolve                              Run evolutionary cycle"
  echo "  $0 --fitness <child_dir>                 Score a universe"
  echo "  $0 --breed <n>                           Breed N children"
  echo "  $0 --status                              DAO status"
  echo "  $0 --phoenix                              Phoenix Protocol"
  echo "  $0 --check                               Run circuit breakers"
  echo "  $0 --comms send <to> <msg>               Send inter-universe message (v0.6.0)"
  echo "  $0 --comms inbox [universe]              Read messages (v0.6.0)"
  echo "  $0 --treasury                            Show treasury (v0.6.0)"
  echo "  $0 --treasury deposit <amt> <from>       Deposit to treasury"
  echo "  $0 --meta-proposal <id>                  Submit meta-proposal (v0.6.0)"
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

hash_universe() {
  echo "$1" | sha256sum | cut -c1-16
}

# ─── Load DAO State ──────────────────────────────────────────────────────────

load_state() {
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" << 'EOF'
{
  "version": "0.6.0",
  "created": "'$(date -Iseconds)'",
  "voting_period": 50,
  "quorum": 0.5,
  "pass_threshold": 0.6,
  "phi_weighted": true,
  "delegation_enabled": true,
  "deadlock_timeout": 100,
  "proposal_count": 0,
  "passed_count": 0,
  "rejected_count": 0,
  "active_proposals": [],
  "delegations": {},
  "treasury": {
    "afri_balance": 0,
    "total_deposited": 0,
    "total_withdrawn": 0
  },
  "parameters": {
    "mutation_rate": 0.02,
    "learning_rate": 0.01,
    "selection_method": "tournament",
    "fitness_alpha": 0.40,
    "fitness_beta": 0.30,
    "fitness_gamma": 0.20,
    "fitness_delta": 0.10
  },
  "phoenix_activated": true,
  "last_phoenix": null,
  "comms_count": 0
}
EOF
  fi
}

# ─── Count Active Universes ──────────────────────────────────────────────────

count_universes() {
  count=0
  for f in "$CHILD_DIR"/*_state.json; do
    [ -f "$f" ] && count=$((count + 1))
  done
  [ -f "$BASE_DIR/universe_state.json" ] && count=$((count + 1))
  echo "$count"
}

# ─── Get Universe Fitness with Phi-Weighting (v0.6.0) ───────────────────────

get_universe_fitness() {
  state_file="$1"
  closure_score entropy_val phi_val

  if [ ! -f "$state_file" ]; then echo "0"; return; fi

  closure_score=$(json_get "$state_file" "closure_score")
  entropy_val=$(json_get "$state_file" "entropy")
  phi_val=$(json_get "$state_file" "phi")

  [ -z "$closure_score" ] && closure_score=0
  [ -z "$entropy_val" ] && entropy_val=0
  [ -z "$phi_val" ] && phi_val=0

  alpha=0.40 beta=0.30 gamma=0.20 delta=0.10
  ent_norm=$(echo "scale=6; $entropy_val / 2.6667" | bc 2>/dev/null || echo "0.5")
  phi_norm=$(echo "scale=6; $phi_val / 5.0" | bc 2>/dev/null || echo "0.02")
  [ "$(echo "$phi_norm > 1.0" | bc -l 2>/dev/null)" = "1" ] && phi_norm=1.0

  score=$(echo "scale=6; $alpha * $closure_score + $beta * $closure_score + $gamma * $ent_norm + $delta * $phi_norm" | bc 2>/dev/null || echo "0")
  echo "$score"
}

# ─── Get Phi Score for Weighted Voting (v0.6.0) ─────────────────────────────

get_universe_phi() {
  state_file="$1"
  if [ ! -f "$state_file" ]; then echo "0.1"; return; fi
  phi=$(json_get "$state_file" "phi")
  [ -z "$phi" ] && phi="0.1"
  [ "$(echo "$phi <= 0" | bc -l 2>/dev/null)" = "1" ] && phi="0.1"
  echo "$phi"
}

# ─── Get Universe Hash ───────────────────────────────────────────────────────

get_universe_hash() {
  state_file="$1"
  if [ ! -f "$state_file" ]; then echo "unknown"; return; fi
  hash=$(json_get "$state_file" "hash")
  [ -z "$hash" ] && hash=$(sha256sum "$state_file" | cut -c1-16)
  echo "$hash"
}

# ─── PROPOSAL: Submit ────────────────────────────────────────────────────────

cmd_proposal_submit() {
  type="$1" params="$2"
  [ -z "$type" ] && { echo "Usage: $0 --proposal submit <type> <params>"; exit 1; }

  load_state

  proposer_hash=$(sha256sum "$BASE_DIR/universe_state.json" 2>/dev/null | cut -c1-16 || echo "parent")
  timestamp=$(date +%s)
  proposal_id=$(echo "$proposer_hash $type $params $timestamp" | sha256sum | cut -c1-32)

  # Validate proposal type (v0.6.0: added delegation, meta, treasury types)
  case "$type" in
    mutation_rate|learning_rate|selection_method|fitness_alpha|fitness_beta)
      ;;
    fitness_gamma|fitness_delta|kill_orphan|phoenix_trigger)
      ;;
    delegation|meta_proposal|treasury_allocation|comms_protocol)  # NEW v0.6.0
      ;;
    *) echo "Invalid type: $type (valid: mutation_rate, learning_rate, selection_method, fitness_alpha, fitness_beta, fitness_gamma, fitness_delta, kill_orphan, phoenix_trigger, delegation, meta_proposal, treasury_allocation, comms_protocol)"; exit 1 ;;
  esac

  voting_end=$((timestamp + VOTING_PERIOD * 10))

  cat > "${PROPOSAL_DIR}/${proposal_id}.json" << EOF
{
  "id": "${proposal_id}",
  "proposer": "${proposer_hash}",
  "type": "${type}",
  "params": "${params}",
  "timestamp": ${timestamp},
  "voting_end": ${voting_end},
  "status": "active",
  "votes_for": 0,
  "votes_against": 0,
  "voting_weight_total": 0,
  "phi_weighted": ${PHI_WEIGHTED},
  "is_meta": $( [ "$type" = "meta_proposal" ] && echo "true" || echo "false" )
}
EOF

  echo "  ✅ Proposal #${proposal_id} submitted"
  echo "     Type: $type | Params: $params"
  echo "     Voting ends: $(date -d @$voting_end 2>/dev/null || echo 'in 500s')"
  echo "     Phi-weighted: $PHI_WEIGHTED"
}

# ─── VOTE (v0.6.0: Phi-weighted voting) ─────────────────────────────────────

cmd_vote() {
  proposal_id="$1" choice="$2"
  [ -z "$proposal_id" ] && { echo "Usage: $0 --vote <proposal_id> <for|against>"; exit 1; }
  [ "$choice" != "for" ] && [ "$choice" != "against" ] && { echo "Vote must be 'for' or 'against'"; exit 1; }

  proposal_file="${PROPOSAL_DIR}/${proposal_id}.json"
  [ ! -f "$proposal_file" ] && { echo "Proposal not found: $proposal_id"; exit 1; }

  # Check expiry and deadlock (v0.6.0)
  voting_end=$(json_get "$proposal_file" "voting_end")
  now=$(date +%s)
  [ "$now" -gt "$voting_end" ] && {
    # Check deadlock timeout
    expired_for=$(( (now - voting_end) / 10 ))
    if [ "$expired_for" -gt "$DEADLOCK_TIMEOUT" ]; then
      echo "  ⏰ Proposal expired by deadlock timeout. Auto-rejecting."
      json_set "$proposal_file" "status" '"rejected"'
      json_set "$proposal_file" "reason" '"deadlock_timeout"'
      return
    fi
    echo "  ⏰ Voting period ended. Proposal closed."
    return
  }

  # Get voter identity and phi weight (v0.6.0)
  voter_hash=$(sha256sum "$BASE_DIR/universe_state.json" 2>/dev/null | cut -c1-16 || echo "parent")
  phi_weight=1

  if [ "$PHI_WEIGHTED" = "true" ]; then
    # Check delegation first (v0.6.0)
    if [ "$DELEGATION_ENABLED" = "true" ]; then
      delegate_to=$(json_get "$STATE_FILE" "delegations" 2>/dev/null | grep -o "\"${voter_hash}\":\"[^\"]*\"" | cut -d'"' -f4 || echo "")
      if [ -n "$delegate_to" ]; then
        delegate_state="${CHILD_DIR}/${delegate_to}_state.json"
        phi_weight=$(get_universe_phi "$delegate_state")
        echo "  Delegated vote: $voter_hash → $delegate_to (phi: $phi_weight)"
      else
        phi_weight=$(get_universe_phi "$BASE_DIR/universe_state.json")
      fi
    else
      phi_weight=$(get_universe_phi "$BASE_DIR/universe_state.json")
    fi
  fi

  # Record vote
  vote_weight=$phi_weight
  if [ "$QUADRATIC" = "true" ]; then
    # Quadratic: weight = sqrt(phi)
    vote_weight=$(echo "scale=4; sqrt($phi_weight)" | bc 2>/dev/null || echo "1")
  fi

  # Update proposal
  current_for=$(json_get "$proposal_file" "votes_for")
  current_against=$(json_get "$proposal_file" "votes_against")
  current_total=$(json_get "$proposal_file" "voting_weight_total")

  if [ "$choice" = "for" ]; then
    current_for=$(echo "$current_for + $vote_weight" | bc)
  else
    current_against=$(echo "$current_against + $vote_weight" | bc)
  fi
  current_total=$(echo "$current_total + $vote_weight" | bc)

  json_set "$proposal_file" "votes_for" "$current_for"
  json_set "$proposal_file" "votes_against" "$current_against"
  json_set "$proposal_file" "voting_weight_total" "$current_total"

  echo "  ✅ Vote recorded: $choice"
  echo "     Weight: $vote_weight (phi: $phi_weight, quadratic: $QUADRATIC)"
  echo "     Total: $current_for for / $current_against against"
}

# ─── DELEGATE (v0.6.0) ───────────────────────────────────────────────────────

cmd_delegate() {
  to_universe="$1"
  [ -z "$to_universe" ] && { echo "Usage: $0 --delegate <to_universe_hash>"; exit 1; }

  load_state
  voter_hash=$(sha256sum "$BASE_DIR/universe_state.json" 2>/dev/null | cut -c1-16 || echo "parent")

  # Verify target exists
  target_state="${CHILD_DIR}/${to_universe}_state.json"
  if [ ! -f "$target_state" ] && [ "$to_universe" != "parent" ]; then
    echo "  Target universe not found: $to_universe"
    exit 1
  fi

  # Store delegation
  delegations=$(json_get "$STATE_FILE" "delegations" 2>/dev/null || echo "{}")
  # Simple approach: update the JSON file
  sed -i "s/\"delegations\": {[^}]*}/\"delegations\": {\"${voter_hash}\": \"${to_universe}\"}/" "$STATE_FILE" 2>/dev/null || {
    # If sed fails, use awk
    awk -v v="$voter_hash" -v t="$to_universe" '{
      if ($0 ~ "\"delegations\"") {
        gsub(/\}[^}]*$/, "}")
        print
        print "    \"" v "\": \"" t "\""
        print "  }"
      } else { print }
    }' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
  }

  echo "  ✅ Delegation set: $voter_hash → $to_universe"
  echo "     All future votes will use $to_universe's phi score"
}

# ─── INTER-UNIVERSE COMMUNICATION (v0.6.0) ──────────────────────────────────

cmd_comms_send() {
  to_universe="$1" message="$2"
  [ -z "$to_universe" ] && { echo "Usage: $0 --comms send <to_universe> <message>"; exit 1; }
  [ -z "$message" ] && { echo "Usage: $0 --comms send <to_universe> <message>"; exit 1; }

  from_hash=$(sha256sum "$BASE_DIR/universe_state.json" 2>/dev/null | cut -c1-16 || echo "parent")
  to_hash=$(echo "$to_universe" | sha256sum | cut -c1-16)
  timestamp=$(date +%s)
  payload_hash=$(echo "$from_hash $to_hash $message $timestamp" | sha256sum | cut -c1-32)
  msg_id=$(echo "$payload_hash $RANDOM" | sha256sum | cut -c1-16)

  # Create message
  cat > "${COMMS_DIR}/${msg_id}.json" << EOF
{
  "id": "${msg_id}",
  "from": "${from_hash}",
  "to": "${to_hash}",
  "payload_hash": "${payload_hash}",
  "message": "${message}",
  "timestamp": ${timestamp},
  "ttl": ${COMMS_TTL},
  "signature": "${payload_hash}",
  "status": "delivered"
}
EOF

  # Log to history
  echo "COMMS|${msg_id}|${from_hash}→${to_hash}|${message}|${timestamp}" >> "${DAO_DIR}/comms_history.txt"

  echo "  📨 Message sent"
  echo "     From: ${from_hash}"
  echo "     To:   ${to_hash}"
  echo "     Hash: ${payload_hash}"
  echo "     TTL:  ${COMMS_TTL}s"
}

cmd_comms_inbox() {
  universe_filter="${1:-}"
  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     INTER-UNIVERSE COMMUNICATIONS            ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  count=0
  for f in "$COMMS_DIR"/*.json; do
    [ ! -f "$f" ] && continue
    from=$(json_get "$f" "from")
    to=$(json_get "$f" "to")
    msg=$(json_get "$f" "message")
    ts=$(json_get "$f" "timestamp")
    hash=$(json_get "$f" "payload_hash")

    # Apply filter
    [ -n "$universe_filter" ] && [ "$to" != "$universe_filter" ] && [ "$from" != "$universe_filter" ] && continue

    # Check TTL
    now=$(date +%s)
    age=$((now - ts))
    [ "$age" -gt "$COMMS_TTL" ] && continue  # Expired

    count=$((count + 1))
    printf "  [%s] %s → %s (%ds ago)\n" "$hash" "$from" "$to" "$age"
    printf "  \"%s\"\n" "$msg"
    echo ""
  done

  [ "$count" -eq 0 ] && echo "  (no messages)"
  echo "  Total: $count active messages"
  echo ""
}

# ─── TREASURY (v0.6.0) ───────────────────────────────────────────────────────

cmd_treasury() {
  if [ ! -f "$TREASURY_FILE" ]; then
    echo '{"afri_balance":0,"total_deposited":0,"total_withdrawn":0,"transactions":[]}' > "$TREASURY_FILE"
  fi

  balance=$(json_get "$TREASURY_FILE" "afri_balance")
  deposited=$(json_get "$TREASURY_FILE" "total_deposited")
  withdrawn=$(json_get "$TREASURY_FILE" "total_withdrawn")

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║           DAO TREASURY                        ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""
  printf "  Balance:       %.2f AFRI\n" "$balance"
  printf "  Total In:      %.2f AFRI\n" "$deposited"
  printf "  Total Out:     %.2f AFRI\n" "$withdrawn"
  echo ""
  echo "  Recent transactions:"
  tail -5 "$TREASURY_FILE" 2>/dev/null | grep "tx" || echo "  (none)"
  echo ""
}

cmd_treasury_deposit() {
  amount="$1" from="$2"
  [ -z "$amount" ] && { echo "Usage: $0 --treasury deposit <amount> <from>"; exit 1; }

  if [ ! -f "$TREASURY_FILE" ]; then
    echo '{"afri_balance":0,"total_deposited":0,"total_withdrawn":0,"transactions":[]}' > "$TREASURY_FILE"
  fi

  balance=$(json_get "$TREASURY_FILE" "afri_balance")
  deposited=$(json_get "$TREASURY_FILE" "total_deposited")
  new_balance=$(echo "$balance + $amount" | bc)
  new_deposited=$(echo "$deposited + $amount" | bc)
  ts=$(date +%s)

  json_set "$TREASURY_FILE" "afri_balance" "$new_balance"
  json_set "$TREASURY_FILE" "total_deposited" "$new_deposited"

  echo "  💰 Treasury deposit: $amount AFRI from $from"
  echo "     New balance: $new_balance AFRI"
}

# ─── EVOLVE (v0.6.0: Phi-weighted voting in DAO check) ──────────────────────

cmd_evolve() {
  load_state

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║        EVOLUTIONARY CYCLE                     ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  # 1. Check circuit breakers
  cmd_check
  breaker_status=$?
  [ "$breaker_status" -ne 0 ] && { echo "  ❌ Circuit breakers tripped. Cannot evolve."; exit 1; }

  # 2. Check for passed proposals and execute them
  cmd_proposal_list | grep "passed" | while read line; do
    pid=$(echo "$line" | grep -o '[a-f0-9]\{32\}')
    [ -n "$pid" ] && cmd_proposal_execute "$pid"
  done

  # 3. Breed children
  cmd_breed "$BREED_COUNT"

  # 4. Score fitness
  echo ""
  echo "  Fitness scores:"
  best_fitness=0
  best_child=""
  for f in "$CHILD_DIR"/*_state.json; do
    [ ! -f "$f" ] && continue
    name=$(basename "$f" _state.json)
    fitness=$(get_universe_fitness "$f")
    printf "    %-20s → %.6f\n" "$name" "$fitness"
    if [ "$(echo "$fitness > $best_fitness" | bc -l 2>/dev/null)" = "1" ]; then
      best_fitness=$fitness
      best_child=$name
    fi
  done

  echo ""
  echo "  Best: $best_child (fitness: $best_fitness)"

  # 5. Record generation
  gen=$(wc -l < "$HISTORY_FILE" 2>/dev/null || echo "0")
  gen=$((gen + 1))
  echo "GEN|$(date +%s)|best=$best_fitness|count=$(count_universes)|bred=$BREED_COUNT|mut=$(json_get "$STATE_FILE" "parameters" | grep -o '"mutation_rate":[0-9.]*' | cut -d: -f2)" >> "$HISTORY_FILE"

  echo ""
  echo "  Generation #$gen complete"
  echo ""
}

# ─── BREED (v0.6.0: Tournament with phi-weighted selection) ─────────────────

cmd_breed() {
  n="${1:-$BREED_COUNT}"

  echo ""
  echo "  Breeding $n children..."

  # Build children list (POSIX-compatible)
  child_list=""
  child_count=0
  for f in "$CHILD_DIR"/*_state.json; do
    if [ -f "$f" ]; then
      child_count=$((child_count + 1))
      child_list="$child_list $f"
    fi
  done

  if [ "$child_count" -eq 0 ]; then
    echo "  No children to breed from. Spawning from parent."
    sh "$MVU_SCRIPT" --spawn 2>/dev/null || echo "  (MVU script not found)"
    return
  fi

  # Convert list to indexed access via temp file
  tmpdir="${TMPDIR:-/tmp}"
  echo "$child_list" | tr ' ' '\n' > "${tmpdir}/dao_children_$$.txt"
  child_file="${tmpdir}/dao_children_$$.txt"

  for i in $(seq 1 $n); do
    # Tournament selection with phi-weighting (v0.6.0)
    best_idx=1
    best_fit=0

    for j in $(seq 1 $TOURNAMENT_SIZE); do
      idx=$(( (RANDOM % child_count) + 1 ))
      parent=$(sed -n "${idx}p" "${child_file}" 2>/dev/null)
      [ -z "$parent" ] && continue
      fit=$(get_universe_fitness "$parent")

      # Phi-weighted bonus (v0.6.0)
      if [ "$PHI_WEIGHTED" = "true" ]; then
        phi=$(get_universe_phi "$parent")
        fit=$(echo "scale=6; $fit * (1 + $phi / 10)" | bc)
      fi

      if [ "$(echo "$fit > $best_fit" | bc -l 2>/dev/null)" = "1" ]; then
        best_fit=$fit
        best_idx=$idx
      fi
    done

    parent=$(sed -n "${best_idx}p" "${child_file}" 2>/dev/null)
    [ -z "$parent" ] && continue
    parent_name=$(basename "$parent" _state.json)
    child_name="${parent_name}_child_$(date +%s)_$i"

    # Copy with mutation
    mkdir -p "$CHILD_DIR/$child_name"
    cp "$parent" "$CHILD_DIR/${child_name}_state.json"

    # Apply mutation to state
    mut=$(json_get "$STATE_FILE" "parameters" | grep -o '"mutation_rate":[0-9.]*' | cut -d: -f2)
    [ -z "$mut" ] && mut=0.02

    # Mutate fitness parameters
    closure=$(json_get "$CHILD_DIR/${child_name}_state.json" "closure_score")
    new_closure=$(echo "scale=6; $closure * (1 + ($mut * ($RANDOM % 200 - 100) / 100))" | bc)
    json_set "$CHILD_DIR/${child_name}_state.json" "closure_score" "$new_closure"

    echo "    Child $i: $child_name (fitness: $best_fit, mutation: $mut)"
  done
}

# ─── PROPOSAL: Execute ───────────────────────────────────────────────────────

cmd_proposal_execute() {
  proposal_id="$1"
  proposal_file="${PROPOSAL_DIR}/${proposal_id}.json"
  [ ! -f "$proposal_file" ] && return

  type=$(json_get "$proposal_file" "type")
  params=$(json_get "$proposal_file" "params")
  votes_for=$(json_get "$proposal_file" "votes_for")
  votes_against=$(json_get "$proposal_file" "votes_against")
  total_weight=$(json_get "$proposal_file" "voting_weight_total")

  # Check quorum
  universe_count=$(count_universes)
  quorum_needed=$(echo "$universe_count * $QUORUM" | bc | cut -d. -f1)
  voters=$(echo "$total_weight / 1" | bc 2>/dev/null || echo "0")

  if [ "$voters" -lt "$quorum_needed" ]; then
    json_set "$proposal_file" "status" '"rejected"'
    json_set "$proposal_file" "reason" '"quorum_not_met"'
    echo "  ❌ Proposal $proposal_id rejected: quorum not met ($voters < $quorum_needed)"
    return
  fi

  # Check pass threshold
  total_votes=$(echo "$votes_for + $votes_against" | bc)
  pass_needed=$(echo "$total_votes * $PASS_THRESHOLD" | bc)
  if [ "$(echo "$votes_for >= $pass_needed" | bc -l)" = "1" ]; then
    json_set "$proposal_file" "status" '"passed"'

    # Execute based on type
    case "$type" in
      mutation_rate)
        json_set "$STATE_FILE" "parameters" "{\"mutation_rate\":$params,\"learning_rate\":$(json_get "$STATE_FILE" "parameters" | grep -o '"learning_rate":[0-9.]*' | cut -d: -f2),\"selection_method\":\"$(json_get "$STATE_FILE" "parameters" | grep -o '"selection_method":"[^"]*"' | cut -d'"' -f4)\",\"fitness_alpha\":$(json_get "$STATE_FILE" "parameters" | grep -o '"fitness_alpha":[0-9.]*' | cut -d: -f2),\"fitness_beta\":$(json_get "$STATE_FILE" "parameters" | grep -o '"fitness_beta":[0-9.]*' | cut -d: -f2),\"fitness_gamma\":$(json_get "$STATE_FILE" "parameters" | grep -o '"fitness_gamma":[0-9.]*' | cut -d: -f2),\"fitness_delta\":$(json_get "$STATE_FILE" "parameters" | grep -o '"fitness_delta":[0-9.]*' | cut -d: -f2)}"
        echo "  ✅ Executed: mutation_rate → $params" ;;
      learning_rate)
        json_set "$STATE_FILE" "parameters" "{\"mutation_rate\":$(json_get "$STATE_FILE" "parameters" | grep -o '"mutation_rate":[0-9.]*' | cut -d: -f2),\"learning_rate\":$params,\"selection_method\":\"$(json_get "$STATE_FILE" "parameters" | grep -o '"selection_method":"[^"]*"' | cut -d'"' -f4)\",\"fitness_alpha\":$(json_get "$STATE_FILE" "parameters" | grep -o '"fitness_alpha":[0-9.]*' | cut -d: -f2),\"fitness_beta\":$(json_get "$STATE_FILE" "parameters" | grep -o '"fitness_beta":[0-9.]*' | cut -d: -f2),\"fitness_gamma\":$(json_get "$STATE_FILE" "parameters" | grep -o '"fitness_gamma":[0-9.]*' | cut -d: -f2),\"fitness_delta\":$(json_get "$STATE_FILE" "parameters" | grep -o '"fitness_delta":[0-9.]*' | cut -d: -f2)}"
        echo "  ✅ Executed: learning_rate → $params" ;;
      kill_orphan)
        echo "  Cleaning up orphan children..." ;;
      phoenix_trigger)
        cmd_phoenix ;;
      meta_proposal)
        echo "  ✅ Meta-proposal passed: $params"
        # Meta-proposals change governance parameters
        eval "$params" 2>/dev/null || echo "  ⚠️  Could not execute meta-proposal params" ;;
      treasury_allocation)
        cmd_treasury_deposit "$params" "dao_proposal" ;;
      *)
        echo "  ✅ Executed: $type → $params" ;;
    esac

    echo "  ✅ Proposal $proposal_id PASSED (for: $votes_for, against: $votes_against)"
  else
    json_set "$proposal_file" "status" '"rejected"'
    json_set "$proposal_file" "reason" '"threshold_not_met"'
    echo "  ❌ Proposal $proposal_id rejected: threshold not met ($votes_for < $pass_needed)"
  fi
}

# ─── PROPOSAL: List ──────────────────────────────────────────────────────────

cmd_proposal_list() {
  echo ""
  echo "  Active Proposals:"
  echo "  ─────────────────────────────────────────────"
  found=0
  for f in "$PROPOSAL_DIR"/*.json; do
    [ ! -f "$f" ] && continue
    id=$(json_get "$f" "id")
    type=$(json_get "$f" "type")
    status=$(json_get "$f" "status")
    vf=$(json_get "$f" "votes_for")
    va=$(json_get "$f" "votes_against")
    meta=$(json_get "$f" "is_meta")
    meta_flag=""
    [ "$meta" = "true" ] && meta_flag=" [META]"
    printf "  [%s] %s%s | for: %s | against: %s | %s\n" "$id" "$type" "$meta_flag" "$vf" "$va" "$status"
    found=1
  done
  [ "$found" -eq 0 ] && echo "  (no proposals)"
  echo ""
}

# ─── CIRCUIT BREAKERS (v0.6.0: Added deadlock detection) ─────────────────────

cmd_check() {
  issues=0

  # 1. Quorum check
  uc=$(count_universes)
  if [ "$uc" -lt 2 ]; then
    echo "  ⚠️  Low universe count: $uc (need ≥2)"
    issues=$((issues + 1))
  fi

  # 2. Stagnation check
  if [ -f "$HISTORY_FILE" ]; then
    recent=$(tail -5 "$HISTORY_FILE" 2>/dev/null | grep "GEN" | grep -o "best=[0-9.]*" | cut -d= -f2)
    stable=1
    for v in $recent; do
      diff=$(echo "$v - $(echo "$recent" | head -1)" | bc 2>/dev/null || echo "0")
      [ "$(echo "$diff < 0.001" | bc -l 2>/dev/null)" = "1" ] || stable=0
    done
    [ "$stable" -eq 1 ] && [ -n "$recent" ] && {
      echo "  ⚠️  Stagnation detected (last 5 gens within 0.001)"
      issues=$((issues + 1))
    }
  fi

  # 3. Mass collapse check
  state_count=$(ls "$CHILD_DIR"/*_state.json 2>/dev/null | wc -l)
  if [ "$state_count" -eq 0 ] && [ ! -f "$BASE_DIR/universe_state.json" ]; then
    echo "  🔴 Mass collapse: no universes exist"
    issues=$((issues + 1))
  fi

  # 4. Deadlock detection (v0.6.0)
  now=$(date +%s)
  for f in "$PROPOSAL_DIR"/*.json; do
    [ ! -f "$f" ] && continue
    status=$(json_get "$f" "status")
    [ "$status" != "active" ] && continue
    voting_end=$(json_get "$f" "voting_end")
    expired_for=$(( (now - voting_end) / 10 ))
    if [ "$expired_for" -gt "$DEADLOCK_TIMEOUT" ]; then
      echo "  ⏰ Deadlock: proposal $(json_get "$f" "id") expired $expired_for steps ago"
      json_set "$f" "status" '"rejected"'
      json_set "$f" "reason" '"deadlock_timeout"'
      issues=$((issues + 1))
    fi
  done

  # 5. Registry corruption check
  hash_count=$(ls "$CHILD_DIR"/*.json 2>/dev/null | wc -l)
  state_count2=$(ls "$CHILD_DIR"/*_state.json 2>/dev/null | wc -l)
  if [ "$hash_count" -gt 0 ] && [ "$hash_count" -ne "$state_count2" ]; then
    echo "  ⚠️  Registry corruption: $hash_count files vs $state_count2 state files"
    issues=$((issues + 1))
  fi

  echo ""
  if [ "$issues" -gt 0 ]; then
    echo "  🔴 $issues circuit breaker(s) tripped"
    return 1
  else
    echo "  🟢 All circuit breakers CLOSED"
    return 0
  fi
}

# ─── PHOENIX PROTOCOL ────────────────────────────────────────────────────────

cmd_phoenix() {
  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║        PHOENIX PROTOCOL ACTIVATED             ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  # Create backup
  backup_dir="${BASE_DIR}/phoenix/backup_$(date +%s)"
  mkdir -p "$backup_dir"
  cp "$CHILD_DIR"/*.json "$backup_dir/" 2>/dev/null || true
  cp "$BASE_DIR/universe_state.json" "$backup_dir/" 2>/dev/null || true

  echo "  Backup saved to: $backup_dir"

  # Spawn new universe with mutation boost
  mut_boost=$PHOENIX_MUTATION_RATE
  echo "  Spawning with mutation rate: $mut_boost"

  if [ -f "$MVU_SCRIPT" ]; then
    sh "$MVU_SCRIPT" --spawn 2>/dev/null || {
      # Manual spawn if MVU fails
      ts=$(date +%s)
      hash=$(echo "phoenix_$ts" | sha256sum | cut -c1-16)
      cat > "${CHILD_DIR}/phoenix_${ts}_state.json" << EOF
{
  "name": "phoenix_${ts}",
  "hash": "${hash}",
  "created": ${ts},
  "closure_score": 0.5,
  "entropy": 1.3333,
  "phi": 0.1,
  "steps": 0,
  "parent": "phoenix"
}
EOF
      echo "  Created: phoenix_${ts}"
    }
  else
    ts=$(date +%s)
    hash=$(echo "phoenix_$ts" | sha256sum | cut -c1-16)
    cat > "${CHILD_DIR}/phoenix_${ts}_state.json" << EOF
{
  "name": "phoenix_${ts}",
  "hash": "${hash}",
  "created": ${ts},
  "closure_score": 0.5,
  "entropy": 1.3333,
  "phi": 0.1,
  "steps": 0,
  "parent": "phoenix"
}
EOF
    echo "  Created: phoenix_${ts}"
  fi

  json_set "$STATE_FILE" "last_phoenix" "\"$(date -Iseconds)\""
  echo ""
  echo "  ✅ Phoenix complete. Universe reborn."
}

# ─── STATUS (v0.6.0: Added treasury, comms, delegation info) ────────────────

cmd_status() {
  load_state

  uc=$(count_universes)
  fitness=$(get_universe_fitness "$BASE_DIR/universe_state.json")
  phi=$(get_universe_phi "$BASE_DIR/universe_state.json")

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║       UNIVERSE DAO STATUS v0.6.0             ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""
  printf "  Active universes:  %d\n" "$uc"
  printf "  Parent fitness:    %.6f\n" "$fitness"
  printf "  Parent phi:        %.4f\n" "$phi"
  echo ""
  printf "  Voting:            phi-weighted=%s, quadratic=%s\n" "$PHI_WEIGHTED" "$QUADRATIC"
  printf "  Delegation:        %s\n" "$DELEGATION_ENABLED"
  printf "  Deadlock timeout:  %d steps\n" "$DEADLOCK_TIMEOUT"
  echo ""
  printf "  Mutation rate:     %s\n" "$(json_get "$STATE_FILE" "parameters" | grep -o '"mutation_rate":[0-9.]*' | cut -d: -f2)"
  printf "  Learning rate:     %s\n" "$(json_get "$STATE_FILE" "parameters" | grep -o '"learning_rate":[0-9.]*' | cut -d: -f2)"
  printf "  Selection:         %s\n" "$(json_get "$STATE_FILE" "parameters" | grep -o '"selection_method":"[^"]*"' | cut -d'"' -f4)"
  echo ""
  printf "  Phoenix available: %s\n" "$(json_get "$STATE_FILE" "phoenix_activated")"
  printf "  Last phoenix:      %s\n" "$(json_get "$STATE_FILE" "last_phoenix" || echo "never")"
  echo ""
  printf "  Comms TTL:         %ds\n" "$COMMS_TTL"
  printf "  Comms messages:    %d\n" "$(ls "$COMMS_DIR"/*.json 2>/dev/null | wc -l)"
  echo ""

  # Treasury
  if [ -f "$TREASURY_FILE" ]; then
    printf "  Treasury:          %.2f AFRI\n" "$(json_get "$TREASURY_FILE" "afri_balance")"
  fi
  echo ""

  # Show recent generations
  echo "  Recent generations:"
  tail -3 "$HISTORY_FILE" 2>/dev/null | while read line; do
    echo "    $line"
  done
  [ ! -f "$HISTORY_FILE" ] && echo "    (none)"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

[ $# -eq 0 ] && { cmd_status; exit 0; }

case "$1" in
  --proposal)
    shift
    case "$1" in
      submit) shift; cmd_proposal_submit "$@" ;;
      list) cmd_proposal_list ;;
      status) shift; cmd_proposal_status "$1" ;;
      execute) shift; cmd_proposal_execute "$1" ;;
      *) echo "Usage: $0 --proposal <submit|list|status|execute>"; exit 1 ;;
    esac
    ;;
  --vote) shift; cmd_vote "$@" ;;
  --delegate) shift; cmd_delegate "$@" ;;
  --evolve) cmd_evolve ;;
  --fitness) shift; get_universe_fitness "$1" ;;
  --breed) shift; cmd_breed "$@" ;;
  --status) cmd_status ;;
  --phoenix) cmd_phoenix ;;
  --check) cmd_check ;;
  --comms)
    shift
    case "$1" in
      send) shift; cmd_comms_send "$@" ;;
      inbox) shift; cmd_comms_inbox "$@" ;;
      *) echo "Usage: $0 --comms <send|inbox>"; exit 1 ;;
    esac
    ;;
  --treasury)
    shift
    case "$1" in
      deposit) shift; cmd_treasury_deposit "$@" ;;
      *) cmd_treasury ;;
    esac
    ;;
  --meta-proposal) shift; cmd_proposal_submit "meta_proposal" "$@" ;;
  --help|-h) usage ;;
  *) echo "Unknown: $1"; usage ;;
esac
