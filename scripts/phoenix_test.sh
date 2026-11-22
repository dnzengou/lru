#!/usr/bin/env bash
# Phoenix Protocol Test v0.7.0
# =============================
# Tests the Phoenix Protocol recovery system:
#   1. Simulates total collapse (deletes all state)
#   2. Triggers Phoenix Protocol recovery
#   3. Recovers from phoenix/backup state
#   4. Verifies causal chain continuity
#   5. Reports recovery status
#
# Usage:
#   sh phoenix_test.sh                    # Run full phoenix test
#   sh phoenix_test.sh --dry-run          # Show what would happen
#   sh phoenix_test.sh --backup-only      # Only create backup
#   sh phoenix_test.sh --recover-only     # Only recover from backup
#   sh phoenix_test.sh --verify           # Verify causal chain
#
# Dependencies: awk, sha256sum, bc

set -e

BASE_DIR="${LRU_BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
CHILD_DIR="${BASE_DIR}/children"
DAO_DIR="${BASE_DIR}/dao"
PHOENIX_DIR="${BASE_DIR}/phoenix"
STATE_FILE="${BASE_DIR}/universe_state_v7.json"
HISTORY_FILE="${BASE_DIR}/neural_history_v7.txt"
COMMS_DIR="${DAO_DIR}/comms"
BACKUP_MANIFEST="${PHOENIX_DIR}/phoenix_manifest_v7.txt"

mkdir -p "$PHOENIX_DIR"

# ─── Help ─────────────────────────────────────────────────────────────────────

usage() {
  echo "Phoenix Protocol Test v0.7.0"
  echo ""
  echo "Usage:"
  echo "  $0                    Run full phoenix test"
  echo "  $0 --dry-run          Show what would happen"
  echo "  $0 --backup-only      Only create backup"
  echo "  $0 --recover-only     Only recover from backup"
  echo "  $0 --verify           Verify causal chain"
  exit 0
}

# ─── JSON Helper ─────────────────────────────────────────────────────────────

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

# ─── Step 1: Create Backup ─────────────────────────────────────────────────

create_backup() {
  ts=$(date +%s)
  backup_dir="${PHOENIX_DIR}/backup_v7_${ts}"
  mkdir -p "$backup_dir"

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     PHOENIX BACKUP CREATION                  ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  # Backup state file
  if [ -f "$STATE_FILE" ]; then
    cp "$STATE_FILE" "$backup_dir/universe_state_v7.json"
    hash=$(json_get "$STATE_FILE" "hash")
    closure=$(json_get "$STATE_FILE" "closure_score")
    entropy=$(json_get "$STATE_FILE" "entropy")
    phi=$(json_get "$STATE_FILE" "phi")
    steps=$(json_get "$STATE_FILE" "steps")
    echo "  ✅ State backed up: hash=$hash phi=$phi steps=$steps"
  else
    echo "  ⚠️  No state file to backup"
  fi

  # Backup children
  child_count=0
  mkdir -p "$backup_dir/children"
  for f in "$CHILD_DIR"/*_state.json; do
    [ ! -f "$f" ] && continue
    cp "$f" "$backup_dir/children/"
    child_count=$((child_count + 1))
  done
  echo "  ✅ $child_count children backed up"

  # Backup history
  if [ -f "$HISTORY_FILE" ]; then
    cp "$HISTORY_FILE" "$backup_dir/neural_history_v7.txt"
    echo "  ✅ History backed up"
  fi

  # Backup comms
  comms_count=0
  mkdir -p "$backup_dir/comms"
  for f in "$COMMS_DIR"/*.json; do
    [ ! -f "$f" ] && continue
    cp "$f" "$backup_dir/comms/"
    comms_count=$((comms_count + 1))
  done
  echo "  ✅ $comms_count comms messages backed up"

  # Create manifest
  manifest_hash=$(echo "phoenix_v7_${ts}_${hash}_${child_count}" | sha256sum | cut -c1-16)
  cat > "$backup_dir/manifest.txt" << EOF
PHOENIX_BACKUP_V7
timestamp: ${ts}
state_hash: ${hash:-unknown}
child_count: ${child_count}
comms_count: ${comms_count}
manifest_hash: ${manifest_hash}
EOF

  # Update global manifest
  echo "${ts}|${backup_dir}|${manifest_hash}|${hash:-unknown}|${child_count}" >> "$BACKUP_MANIFEST"

  echo ""
  echo "  Backup saved to: $backup_dir"
  echo "  Manifest hash:   $manifest_hash"
  echo ""

  echo "$backup_dir"
}

# ─── Step 2: Simulate Total Collapse ───────────────────────────────────────

simulate_collapse() {
  dry_run="${1:-false}"

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     SIMULATING TOTAL COLLAPSE                ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  if [ "$dry_run" = "true" ]; then
    echo "  [DRY RUN] Would delete:"
    echo "    - $STATE_FILE"
    echo "    - $CHILD_DIR/*_state.json"
    echo "    - $CHILD_DIR/*_proof.txt"
    echo "    - $COMMS_DIR/*.json"
    echo "    - $HISTORY_FILE"
    echo ""
    return
  fi

  # Count before deletion
  state_exists=0
  [ -f "$STATE_FILE" ] && state_exists=1
  child_count=$(ls "$CHILD_DIR"/*_state.json 2>/dev/null | wc -l)
  proof_count=$(ls "$CHILD_DIR"/*_proof.txt 2>/dev/null | wc -l)
  comms_count=$(ls "$COMMS_DIR"/*.json 2>/dev/null | wc -l)

  # Delete state
  rm -f "$STATE_FILE"
  rm -f "$CHILD_DIR"/*_state.json
  rm -f "$CHILD_DIR"/*_proof.txt
  rm -f "$COMMS_DIR"/*.json
  rm -f "$HISTORY_FILE"

  echo "  💥 COLLAPSE EXECUTED"
  echo "     Deleted:"
  echo "       - State file: $([ "$state_exists" -eq 1 ] && echo 'yes' || echo 'no')"
  echo "       - Children: $child_count"
  echo "       - Proofs: $proof_count"
  echo "       - Comms: $comms_count"
  echo "       - History: yes"
  echo ""

  # Verify deletion
  remaining=$(ls "$STATE_FILE" "$CHILD_DIR"/*.json "$COMMS_DIR"/*.json 2>/dev/null | wc -l)
  if [ "$remaining" -eq 0 ]; then
    echo "  ✅ Total collapse confirmed: 0 remaining artifacts"
  else
    echo "  ⚠️  Partial collapse: $remaining artifacts remain"
  fi
  echo ""
}

# ─── Step 3: Recover from Backup ───────────────────────────────────────────

recover_from_backup() {
  backup_dir="$1"

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     PHOENIX RECOVERY                         ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  if [ ! -d "$backup_dir" ]; then
    echo "  ❌ Backup directory not found: $backup_dir"
    echo "     Looking for latest backup..."

    # Find latest backup from manifest
    if [ -f "$BACKUP_MANIFEST" ]; then
      backup_dir=$(tail -1 "$BACKUP_MANIFEST" | cut -d'|' -f2)
      echo "     Found: $backup_dir"
    else
      # Try to find any backup directory
      backup_dir=$(ls -d "$PHOENIX_DIR"/backup_v7_* 2>/dev/null | tail -1)
      if [ -z "$backup_dir" ]; then
        echo "  ❌ No backup found. Cannot recover."
        return 1
      fi
      echo "     Found: $backup_dir"
    fi
  fi

  # Verify manifest
  if [ -f "$backup_dir/manifest.txt" ]; then
    echo "  ✅ Manifest found"
    cat "$backup_dir/manifest.txt"
    echo ""
  fi

  # Restore state file
  if [ -f "$backup_dir/universe_state_v7.json" ]; then
    cp "$backup_dir/universe_state_v7.json" "$STATE_FILE"
    hash=$(json_get "$STATE_FILE" "hash")
    echo "  ✅ State restored: $hash"
  else
    echo "  ⚠️  No state file in backup. Creating new genesis..."
    genesis_hash=$(echo "phoenix_recovery_$(date +%s)" | sha256sum | cut -c1-16)
    cat > "$STATE_FILE" << EOF
{
  "name": "parent_v7_phoenix",
  "hash": "${genesis_hash}",
  "created": $(date +%s),
  "steps": 0,
  "hidden_size": 16,
  "n_heads": 8,
  "closure_score": 0.5,
  "entropy": 1.3333,
  "phi": 0.1,
  "sm_accuracy": 0.5,
  "variance": 0.1,
  "hidden_state": [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5],
  "comms_received": 0,
  "comms_sent": 0,
  "last_comms_broadcast": 0,
  "parent": "phoenix",
  "phoenix_recovery": true
}
EOF
    echo "  ✨ New genesis created: $genesis_hash"
  fi

  # Restore children
  child_count=0
  if [ -d "$backup_dir/children" ]; then
    for f in "$backup_dir/children"/*.json; do
      [ ! -f "$f" ] && continue
      cp "$f" "$CHILD_DIR/"
      child_count=$((child_count + 1))
    done
    echo "  ✅ $child_count children restored"
  fi

  # Restore history
  if [ -f "$backup_dir/neural_history_v7.txt" ]; then
    cp "$backup_dir/neural_history_v7.txt" "$HISTORY_FILE"
    echo "  ✅ History restored"
  fi

  # Restore comms
  comms_count=0
  if [ -d "$backup_dir/comms" ]; then
    for f in "$backup_dir/comms"/*.json; do
      [ ! -f "$f" ] && continue
      cp "$f" "$COMMS_DIR/"
      comms_count=$((comms_count + 1))
    done
    echo "  ✅ $comms_count comms messages restored"
  fi

  # Record phoenix event
  ts=$(date +%s)
  phoenix_hash=$(echo "phoenix_recovery_${ts}" | sha256sum | cut -c1-16)
  echo "PHOENIX|${ts}|recovered_from=${backup_dir}|hash=${phoenix_hash}" >> "$HISTORY_FILE"

  echo ""
  echo "  🔥 PHOENIX RECOVERY COMPLETE"
  echo "     Restored from: $backup_dir"
  echo "     Timestamp:     $(date)"
  echo ""
}

# ─── Step 4: Verify Causal Chain Continuity ────────────────────────────────

verify_causal_chain() {
  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     CAUSAL CHAIN VERIFICATION                 ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  if [ ! -f "$STATE_FILE" ]; then
    echo "  ❌ No state file exists. Causal chain broken."
    return 1
  fi

  hash=$(json_get "$STATE_FILE" "hash")
  closure=$(json_get "$STATE_FILE" "closure_score")
  entropy=$(json_get "$STATE_FILE" "entropy")
  phi=$(json_get "$STATE_FILE" "phi")
  steps=$(json_get "$STATE_FILE" "steps")
  hs=$(json_get "$STATE_FILE" "hidden_size")
  phoenix=$(json_get "$STATE_FILE" "phoenix_recovery")

  # Check if this is a phoenix recovery
  if [ "$phoenix" = "true" ]; then
    echo "  🔥 This universe was recovered via Phoenix Protocol"
    echo "     Causal chain reset at recovery point."
    echo ""
  fi

  # Verify hash integrity
  computed_hash=$(echo "$hash $closure $entropy $phi $steps $hs" | sha256sum | cut -c1-16)

  echo "  Hash (stored):    $hash"
  echo "  Hash (computed):  $computed_hash"

  if [ "$hash" = "$computed_hash" ]; then
    echo ""
    echo "  ✅ Causal chain INTACT"
    echo "     The universe is causally closed."
    echo ""
    printf "     Closure: %.4f\n" "$closure"
    printf "     Entropy: %.4f\n" "$entropy"
    printf "     Phi:     %.4f\n" "$phi"
    printf "     Steps:   %s\n" "$steps"
    printf "     Hidden:  %s\n" "$hs"
    echo ""
    return 0
  else
    echo ""
    echo "  ❌ Causal chain BREACHED — hash mismatch"
    echo "     External interference detected."
    echo ""
    return 1
  fi
}

# ─── Full Phoenix Test ─────────────────────────────────────────────────────

cmd_full_test() {
  dry_run="${1:-false}"

  echo ""
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     PHOENIX PROTOCOL TEST v0.7.0             ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  # Phase 1: Pre-backup verification
  echo "  Phase 1: Pre-backup verification..."
  if [ -f "$STATE_FILE" ]; then
    hash=$(json_get "$STATE_FILE" "hash")
    closure=$(json_get "$STATE_FILE" "closure_score")
    phi=$(json_get "$STATE_FILE" "phi")
    echo "     Current state: hash=$hash closure=$closure phi=$phi"
  else
    echo "     ⚠️  No current state"
  fi
  echo ""

  # Phase 2: Create backup
  echo "  Phase 2: Creating backup..."
  backup_dir=$(create_backup)
  echo ""

  # Phase 3: Simulate collapse
  echo "  Phase 3: Simulating collapse..."
  simulate_collapse "$dry_run"
  echo ""

  if [ "$dry_run" = "true" ]; then
    echo "  [DRY RUN] Skipping recovery and verification."
    echo "  [DRY RUN] To execute: sh phoenix_test.sh"
    echo ""
    return
  fi

  # Phase 4: Recover
  echo "  Phase 4: Recovering from backup..."
  recover_from_backup "$backup_dir"
  echo ""

  # Phase 5: Verify
  echo "  Phase 5: Verifying causal chain..."
  verify_causal_chain
  echo ""

  # Phase 6: Report
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     PHOENIX TEST RESULTS                     ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo ""

  if [ -f "$STATE_FILE" ]; then
    hash=$(json_get "$STATE_FILE" "hash")
    closure=$(json_get "$STATE_FILE" "closure_score")
    phi=$(json_get "$STATE_FILE" "phi")
    phoenix=$(json_get "$STATE_FILE" "phoenix_recovery")

    echo "  Status: ✅ RECOVERED"
    [ "$phoenix" = "true" ] && echo "  Method: Phoenix Protocol (new genesis)" || echo "  Method: Full state restoration"
    printf "  Hash:   %s\n" "$hash"
    printf "  Phi:    %.4f\n" "$phi"
    printf "  Steps:  %s\n" "$(json_get "$STATE_FILE" "steps")"
    echo ""
    echo "  The universe survived total collapse."
    echo "  Causal continuity preserved through backup."
  else
    echo "  Status: ❌ NOT RECOVERED"
    echo "  The universe did not survive collapse."
    echo ""
    return 1
  fi

  # Log test result
  ts=$(date +%s)
  echo "PHOENIX_TEST|${ts}|backup=${backup_dir}|result=recovered|phi=${phi}" >> "$HISTORY_FILE"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

[ $# -eq 0 ] && { cmd_full_test; exit 0; }

case "$1" in
  --dry-run)
    cmd_full_test "true"
    ;;
  --backup-only)
    create_backup
    ;;
  --recover-only)
    shift
    recover_from_backup "$1"
    ;;
  --verify)
    verify_causal_chain
    ;;
  --help|-h)
    usage
    ;;
  *)
    echo "Unknown: $1"
    usage
    ;;
esac
