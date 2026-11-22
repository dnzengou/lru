#!/usr/bin/env bash
# Cross-Track Bridge: AFRI ←→ Universe DAO Treasury
# v2.0.0 — Enhanced with /propose, /vote, auto-yield, rich status
#
# Integrates Track 1 (AFRI digital money) with Track 2 (Universe DAO)

BRIDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$BRIDGE_DIR/cross_track_bridge.dat"

# Defaults
MINT_COST_AFRI=1
STAKE_YIELD_APR=0.05

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

init_state() {
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" << EOF
afri_treasury=0
universes_minted=0
total_staked=0
total_yield=0
tx_count=0
last_yield_time=0
EOF
    echo "✅ Cross-track bridge initialized"
  fi
}

read_val() {
  grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2
}

write_val() {
  sed -i "s/^$1=.*/$1=$2/" "$STATE_FILE"
}

# ─── Enhanced Status ──────────────────────────────────────────────────────────

cmd_status() {
  AT=$(read_val afri_treasury)
  UM=$(read_val universes_minted)
  TS=$(read_val total_staked)
  TY=$(read_val total_yield)
  TX=$(read_val tx_count)
  LYT=$(read_val last_yield_time)
  [ -z "$LYT" ] && LYT=0

  # Compute staking APY
  STAKING_APY=$(echo "$STAKE_YIELD_APR * 100" | bc)

  # Count active proposals
  PROP_COUNT=0
  PROP_LIST=""
  if [ -d "$BRIDGE_DIR/dao/proposals_v6" ]; then
    for f in "$BRIDGE_DIR/dao/proposals_v6"/*.json; do
      [ ! -f "$f" ] && continue
      status=$(grep -o '"status":"[^"]*"' "$f" 2>/dev/null | cut -d'"' -f4)
      if [ "$status" = "active" ]; then
        PROP_COUNT=$((PROP_COUNT + 1))
        pid=$(basename "$f" .json)
        ptype=$(grep -o '"type":"[^"]*"' "$f" 2>/dev/null | cut -d'"' -f4)
        PROP_LIST="${PROP_LIST}\n  ${CYAN}▶${NC} ${pid:0:16}... (${ptype})"
      fi
    done
  fi

  # Check if yield is due (>24h since last)
  NOW=$(date +%s)
  YIELD_DUE=false
  if [ "$LYT" -gt 0 ]; then
    ELAPSED=$((NOW - LYT))
    if [ "$ELAPSED" -gt 86400 ]; then
      YIELD_DUE=true
    fi
  fi

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║           CROSS-TRACK BRIDGE STATUS v2.0                    ║"
  echo "║           AFRI Treasury ↔ Universe DAO                     ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  printf "  ${BLUE}AFRI Treasury:${NC}     ${GREEN}%s AFRI${NC}\n" "$AT"
  printf "  ${BLUE}Universes Minted:${NC}  ${GREEN}%s${NC} (cost: %s AFRI each)\n" "$UM" "$MINT_COST_AFRI"
  printf "  ${BLUE}Total Staked:${NC}      ${YELLOW}%s AFRI${NC}\n" "$TS"
  printf "  ${BLUE}Staking APY:${NC}       ${YELLOW}%.1f%%${NC}\n" "$STAKING_APY"
  printf "  ${BLUE}Total Yield Paid:${NC}  ${GREEN}%s AFRI${NC}\n" "$TY"
  printf "  ${BLUE}Transactions:${NC}      %s\n" "$TX"
  echo ""
  printf "  ${BLUE}Active Proposals:${NC}  %s\n" "$PROP_COUNT"
  if [ "$PROP_COUNT" -gt 0 ]; then
    echo "$PROP_LIST"
  fi
  echo ""

  if [ "$YIELD_DUE" = true ]; then
    echo "  ${YELLOW}⚡ Yield distribution overdue! Run 'yield' command.${NC}"
    echo ""
  fi

  # Universe children count
  CHILD_COUNT=$(ls "$BRIDGE_DIR/children/"*_state.json 2>/dev/null | wc -l)
  printf "  ${BLUE}Universe Children:${NC}  %s\n" "$CHILD_COUNT"

  # Neural MVU status
  if [ -f "$BRIDGE_DIR/universe_state_v7.json" ]; then
    PHI=$(grep -o '"phi":[0-9.]*' "$BRIDGE_DIR/universe_state_v7.json" 2>/dev/null | cut -d: -f2)
    SM_ACC=$(grep -o '"sm_accuracy":[0-9.]*' "$BRIDGE_DIR/universe_state_v7.json" 2>/dev/null | cut -d: -f2)
    ENTROPY=$(grep -o '"entropy":[0-9.]*' "$BRIDGE_DIR/universe_state_v7.json" 2>/dev/null | cut -d: -f2)
    VAR=$(grep -o '"variance":[0-9.]*' "$BRIDGE_DIR/universe_state_v7.json" 2>/dev/null | cut -d: -f2)
    STEPS=$(grep -o '"steps":[0-9]*' "$BRIDGE_DIR/universe_state_v7.json" 2>/dev/null | cut -d: -f2)
    echo ""
    echo "  ┌─ Neural MVU v0.7.0 ─────────────────────────────────┐"
    printf "  │  Phi:        ${CYAN}%s${NC}                               │\n" "$PHI"
    printf "  │  SM Accuracy: %s                               │\n" "$SM_ACC"
    printf "  │  Entropy:    %s                               │\n" "$ENTROPY"
    printf "  │  Variance:   %s                               │\n" "$VAR"
    printf "  │  Steps:      %s                                │\n" "$STEPS"
    echo "  └──────────────────────────────────────────────────────┘"
  fi

  echo ""
  echo "  Commands: deposit <amt> | mint | stake <amt> | yield | propose | vote <id> <yes|no>"
  echo ""
}

# ─── Deposit ──────────────────────────────────────────────────────────────────

cmd_deposit() {
  AMOUNT=${1:-10}
  AT=$(read_val afri_treasury)
  TX=$(read_val tx_count)
  NEW_AT=$(echo "$AT + $AMOUNT" | bc)
  NEW_TX=$((TX + 1))

  write_val afri_treasury "$NEW_AT"
  write_val tx_count "$NEW_TX"

  echo "✅ Deposited $AMOUNT AFRI into cross-track treasury"
  echo "   Treasury: $NEW_AT AFRI"
}

# ─── Mint ─────────────────────────────────────────────────────────────────────

cmd_mint() {
  AT=$(read_val afri_treasury)
  UM=$(read_val universes_minted)
  TX=$(read_val tx_count)

  if [ "$(echo "$AT < $MINT_COST_AFRI" | bc)" -eq 1 ]; then
    echo "❌ Insufficient AFRI in treasury ($AT < $MINT_COST_AFRI)"
    return 1
  fi

  NEW_AT=$(echo "$AT - $MINT_COST_AFRI" | bc)
  NEW_UM=$((UM + 1))
  NEW_TX=$((TX + 1))

  write_val afri_treasury "$NEW_AT"
  write_val universes_minted "$NEW_UM"
  write_val tx_count "$NEW_TX"

  echo "✅ Universe #$NEW_UM minted ($MINT_COST_AFRI AFRI spent)"
  echo "   Treasury: $NEW_AT AFRI remaining"
}

# ─── Stake ────────────────────────────────────────────────────────────────────

cmd_stake() {
  AMOUNT=${1:-5}
  AT=$(read_val afri_treasury)
  TS=$(read_val total_staked)
  TX=$(read_val tx_count)

  if [ "$(echo "$AT < $AMOUNT" | bc)" -eq 1 ]; then
    echo "❌ Insufficient AFRI in treasury ($AT < $AMOUNT)"
    return 1
  fi

  NEW_AT=$(echo "$AT - $AMOUNT" | bc)
  NEW_TS=$(echo "$TS + $AMOUNT" | bc)
  NEW_TX=$((TX + 1))

  write_val afri_treasury "$NEW_AT"
  write_val total_staked "$NEW_TS"
  write_val tx_count "$NEW_TX"

  echo "✅ Staked $AMOUNT AFRI in governance"
  echo "   Total staked: $NEW_TS AFRI"
  echo "   Est. annual yield: $(echo "$NEW_TS * $STAKE_YIELD_APR" | bc) AFRI"
}

# ─── Yield with auto-check ────────────────────────────────────────────────────

cmd_yield() {
  TS=$(read_val total_staked)
  TY=$(read_val total_yield)
  TX=$(read_val tx_count)
  LYT=$(read_val last_yield_time)
  [ -z "$LYT" ] && LYT=0

  NOW=$(date +%s)

  # Check if yield was distributed in last 24h
  if [ "$LYT" -gt 0 ]; then
    ELAPSED=$((NOW - LYT))
    if [ "$ELAPSED" -lt 86400 ]; then
      REMAINING=$((86400 - ELAPSED))
      echo "⏳ Yield was distributed $(echo "$ELAPSED / 3600" | bc)h ago."
      echo "   Next yield eligible in $(echo "$REMAINING / 3600" | bc)h $(echo "($REMAINING % 3600) / 60" | bc)m."
      echo "   Use --force to distribute anyway."
      if [ "$1" != "--force" ]; then
        return 0
      fi
    fi
  fi

  DAILY_RATE=$(echo "scale=10; $STAKE_YIELD_APR / 365" | bc)
  YIELD=$(echo "scale=4; $TS * $DAILY_RATE" | bc)
  [ "$(echo "$YIELD < 0.0001" | bc)" -eq 1 ] && YIELD="0.0000"
  NEW_TY=$(echo "$TY + $YIELD" | bc)
  NEW_TX=$((TX + 1))

  write_val total_yield "$NEW_TY"
  write_val tx_count "$NEW_TX"
  write_val last_yield_time "$NOW"

  echo "✅ Yield distributed: $YIELD AFRI"
  echo "   Total yield paid: $NEW_TY AFRI"
  echo "   Timestamp: $(date -d @$NOW 2>/dev/null || echo "$NOW")"
}

# ─── Enhanced Propose ─────────────────────────────────────────────────────────

cmd_propose() {
  TITLE="$1"
  DESCRIPTION="$2"

  if [ -z "$TITLE" ]; then
    echo "Usage: sh cross_track_bridge.sh propose <title> [description]"
    echo ""
    echo "Submits a DAO proposal from the bridge treasury."
    echo "Examples:"
    echo "  propose 'Increase mint cost to 2 AFRI' 'To increase treasury reserves'"
    echo "  propose 'Reduce staking APY to 3%' 'To slow yield inflation'"
    return 1
  fi

  echo "📋 Submitting DAO proposal from treasury..."
  echo "   Title: $TITLE"
  [ -n "$DESCRIPTION" ] && echo "   Description: $DESCRIPTION"
  echo ""

  # Map title to DAO engine params
  PROPOSAL_TYPE="mutation_rate"
  PROPOSAL_PARAMS="0.03"

  case "$TITLE" in
    *"mint cost"*|*"Mint cost"*)
      PROPOSAL_TYPE="treasury_allocation"
      PROPOSAL_PARAMS="$MINT_COST_AFRI"
      ;;
    *"APY"*|*"apy"*|*"yield"*)
      PROPOSAL_TYPE="mutation_rate"
      PROPOSAL_PARAMS="0.02"
      ;;
    *"selection"*|*"Selection"*)
      PROPOSAL_TYPE="selection_method"
      PROPOSAL_PARAMS="tournament"
      ;;
    *"learning"*|*"Learning"*)
      PROPOSAL_TYPE="learning_rate"
      PROPOSAL_PARAMS="0.01"
      ;;
    *"phoenix"*|*"Phoenix"*|*"reset"*)
      PROPOSAL_TYPE="phoenix_trigger"
      PROPOSAL_PARAMS="true"
      ;;
    *"kill"*|*"orphan"*|*"clean"*)
      PROPOSAL_TYPE="kill_orphan"
      PROPOSAL_PARAMS="true"
      ;;
    *"meta"*|*"Meta"*|*"governance"*|*"Governance"*)
      PROPOSAL_TYPE="meta_proposal"
      PROPOSAL_PARAMS="$TITLE"
      ;;
  esac

  cd "$BRIDGE_DIR" && sh dao_engine.sh --proposal submit "$PROPOSAL_TYPE" "$PROPOSAL_PARAMS" 2>&1

  # Increment tx count
  TX=$(read_val tx_count)
  write_val tx_count $((TX + 1))
}

# ─── Enhanced Vote ────────────────────────────────────────────────────────────

cmd_vote() {
  PROPOSAL_ID="$1"
  VOTE_DIRECTION="$2"

  if [ -z "$PROPOSAL_ID" ]; then
    echo "Usage: sh cross_track_bridge.sh vote <proposal_id> <yes|no>"
    echo ""
    echo "Votes on a DAO proposal. Vote weight is phi-weighted."
    echo ""
    echo "Active proposals:"
    if [ -d "$BRIDGE_DIR/dao/proposals_v6" ]; then
      for f in "$BRIDGE_DIR/dao/proposals_v6"/*.json; do
        [ ! -f "$f" ] && continue
        STATUS=$(grep -o '"status":"[^"]*"' "$f" 2>/dev/null | cut -d'"' -f4)
        [ "$STATUS" != "active" ] && continue
        PID=$(basename "$f" .json)
        PTYPE=$(grep -o '"type":"[^"]*"' "$f" 2>/dev/null | cut -d'"' -f4)
        echo "  ${CYAN}${PID}${NC} (${PTYPE})"
      done
    fi
    return 1
  fi

  # Resolve partial ID
  FULL_ID=""
  if [ -d "$BRIDGE_DIR/dao/proposals_v6" ]; then
    for f in "$BRIDGE_DIR/dao/proposals_v6"/*.json; do
      [ ! -f "$f" ] && continue
      PID=$(basename "$f" .json)
      case "$PID" in
        ${PROPOSAL_ID}*) FULL_ID="$PID"; break ;;
      esac
    done
  fi

  if [ -z "$FULL_ID" ]; then
    echo "❌ Proposal not found matching: $PROPOSAL_ID"
    return 1
  fi

  # Map yes/no to for/against
  VOTE_ARG="for"
  case "$VOTE_DIRECTION" in
    yes|Yes|YES|for|For|y) VOTE_ARG="for" ;;
    no|No|NO|against|Against|n) VOTE_ARG="against" ;;
    *)
      echo "❌ Invalid vote direction: $VOTE_DIRECTION (use yes or no)"
      return 1
      ;;
  esac

  echo "🗳️  Bridge treasury votes on proposal ${FULL_ID:0:16}..."
  echo "   Direction: $VOTE_ARG"
  echo "   Weight: phi-weighted (based on treasury stake)"
  echo ""

  cd "$BRIDGE_DIR" && sh dao_engine.sh --vote "$FULL_ID" "$VOTE_ARG" 2>&1

  # Increment tx count
  TX=$(read_val tx_count)
  write_val tx_count $((TX + 1))
}

# ─── Help ─────────────────────────────────────────────────────────────────────

cmd_help() {
  echo "Cross-Track Bridge v2.0: AFRI ↔ Universe DAO"
  echo ""
  echo "Usage: sh cross_track_bridge.sh <command> [args]"
  echo ""
  echo "Commands:"
  echo "  status                    Show bridge status (AFRI, universes, APY, proposals)"
  echo "  deposit <amount>         Deposit AFRI into treasury"
  echo "  mint                      Mint a universe (costs 1 AFRI)"
  echo "  stake <amount>           Stake AFRI in governance"
  echo "  yield [--force]          Distribute yield (auto-checks 24h interval)"
  echo "  propose <title> [desc]   Submit DAO proposal from treasury"
  echo "  vote <id> <yes|no>       Vote on a DAO proposal"
  echo ""
  echo "Examples:"
  echo "  sh cross_track_bridge.sh status"
  echo "  sh cross_track_bridge.sh propose 'Increase mint cost' 'For treasury'"
  echo "  sh cross_track_bridge.sh vote 8660 yes"
  echo "  sh cross_track_bridge.sh yield"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

init_state

case "${1:-help}" in
  status) cmd_status ;;
  deposit) cmd_deposit "$2" ;;
  mint) cmd_mint ;;
  stake) cmd_stake "$2" ;;
  yield) cmd_yield "$2" ;;
  propose) cmd_propose "$2" "$3" ;;
  vote) cmd_vote "$2" "$3" ;;
  *) cmd_help ;;
esac
